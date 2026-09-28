"""GET-only watch: sample readiness every few seconds and summarise it per epoch."""

import collections
import json
import os
import re
import time

from .chain import BLOCKING_CONFIRMATION_PHASES, ChainError, send_window
from .preflight import health_blocker, status_blocker
from .record import utc_now


# An epoch counts as complete only when no two consecutive samples are further apart than this.
MAX_GAP_BLOCKS = 6
STALE_AGE = re.compile(r" \((-?[0-9]+)s old\)$")


def _counter_dict(counter):
    return dict(counter.most_common())


class Epoch:
    def __init__(self, epoch, after_previous):
        self.epoch = epoch
        self.after_previous = after_previous
        self.closed = False
        self.samples = 0
        self.window = 0
        self.window_ready = 0
        self.offsets = []
        self.cpoc = {}
        self.health = collections.Counter()
        self.status = collections.Counter()
        self.errors = collections.Counter()

    def add(self, sample):
        self.samples += 1
        if "error" in sample:
            self.errors[sample["error"]] += 1
            return
        self.offsets.append(sample["offset"])
        if sample["in_window"]:
            self.window += 1
            self.window_ready += sample["ready"]
        if sample.get("cpoc"):
            low, high = self.cpoc.get(sample["cpoc"], (sample["offset"], sample["offset"]))
            self.cpoc[sample["cpoc"]] = (min(low, sample["offset"]), max(high, sample["offset"]))
        self.health[sample["health"] or "READY"] += 1
        self.status[sample["status"] or "routable"] += 1

    def max_gap(self, length):
        if not self.offsets:
            return length
        points = sorted(set(self.offsets))
        gaps = [points[0], length - 1 - points[-1]]
        gaps += [b - a for a, b in zip(points, points[1:])]
        return max(gaps)

    def complete(self, length):
        # Seen before its first block and after its last one, without a long hole in between.
        return self.after_previous and self.closed and self.max_gap(length) <= MAX_GAP_BLOCKS

    def to_dict(self, length):
        return {
            "epoch": self.epoch, "complete": self.complete(length), "samples": self.samples,
            "max_gap_blocks": self.max_gap(length),
            "window_samples": self.window, "window_ready": self.window_ready,
            "confirmation_poc": {phase: list(span) for phase, span in sorted(self.cpoc.items())},
            "health": _counter_dict(self.health), "status": _counter_dict(self.status),
            "errors": _counter_dict(self.errors),
        }

    def line(self, length):
        cpoc = ", ".join("%s %d..%d" % (phase.replace("CONFIRMATION_POC_", ""), a, b)
                         for phase, (a, b) in sorted(self.cpoc.items(), key=lambda item: item[1])) or "none"
        health = ", ".join("%s x%d" % item for item in self.health.most_common(2))
        errors = " errors %d;" % sum(self.errors.values()) if self.errors else ""
        return ("epoch %d%s: window ready %d/%d;%s confirmation PoC %s; health %s"
                % (self.epoch, "" if self.complete(length) else " (partial)", self.window_ready, self.window,
                   errors, cpoc, health or "-"))


class Watch:
    def __init__(self, client, chain, preset, run_dir, log, out):
        self.client = client
        self.chain = chain
        self.preset = preset
        self.samples_path = os.path.join(run_dir, "samples.jsonl")
        self.log = log
        self.out = out
        self.params = None
        self.params_epoch = None
        self.epochs = collections.OrderedDict()
        self.signature = None
        self.samples = 0
        self.errors = collections.Counter()
        self.completed = 0

    def sample(self):
        found = {"at": utc_now()}
        try:
            height, _ = self.chain.height()
            # The proxy fences by height % epoch_length; the chain's epoch group only
            # switches after the PoC of the next epoch, so it is not used for grouping.
            if self.params is None or height // self.params["epoch_length"] != self.params_epoch:
                self.params = self.chain.epoch_params()
                self.params_epoch = height // self.params["epoch_length"]
        except ChainError as error:
            found["error"] = error.reason
            return found
        length = self.params["epoch_length"]
        low, high = send_window(self.params, self.preset)
        offset = height % length
        found.update(height=height, epoch=height // length, offset=offset, in_window=low <= offset <= high)
        try:
            event = self.chain.confirmation_event()
            found["cpoc"] = event["phase"] if event["active"] else None
            blocking = event["active"] and event["phase"] in BLOCKING_CONFIRMATION_PHASES
        except ChainError as error:
            found["cpoc"] = None
            found["cpoc_error"] = error.reason
            blocking = True
        reply = self.client.get(self.preset["base_url"].rstrip("/") + "/v1/status")
        found["status"] = status_blocker(reply.json) if reply.ok else "status HTTP %s" % (
            reply.status or reply.transport_error)
        doc = reply.json if isinstance(reply.json, dict) else {}
        if isinstance(doc.get("error"), dict) and doc["error"].get("message"):
            found["status_error"] = str(doc["error"]["message"])[:120]
        seed = doc.get("height_seed")
        if isinstance(seed, dict):
            slots = seed.get("slot_outcomes") if isinstance(seed.get("slot_outcomes"), list) else []
            found["height_seed"] = seed.get("state")
            found["seed_declined"] = sorted({str(slot.get("reason", "")).strip()[:120] for slot in slots
                                             if isinstance(slot, dict) and slot.get("verdict") != "anchored"})
        reply = self.client.get(self.preset["health_url"])
        blocker = health_blocker(reply.json, self.preset["health_max_age_s"]) if reply.ok \
            else "HTTP %s" % (reply.status or reply.transport_error)
        if blocker and blocker.startswith("health "):
            blocker = blocker[len("health "):]
        stale = STALE_AGE.search(blocker or "")
        if stale:
            found["health_age_s"] = int(stale.group(1))
            blocker = blocker[:stale.start()]
        found["health"] = blocker
        found["ready"] = not blocking and found["status"] is None and found["health"] is None
        return found

    def _report_change(self, sample):
        if "error" in sample:
            signature = ("error", sample["error"])
        else:
            signature = (sample["in_window"], sample["ready"], sample["cpoc"], sample["status"], sample["health"])
        if signature != self.signature:
            self.signature = signature
            if "error" in sample:
                self.log("sample failed: %s" % sample["error"])
            else:
                self.log("epoch %d offset %d%s ready=%s cpoc=%s status=%s health=%s" % (
                    sample["epoch"], sample["offset"], " window" if sample["in_window"] else "",
                    "yes" if sample["ready"] else "no", sample["cpoc"] or "-", sample["status"] or "routable",
                    sample["health"] or "READY"))

    def _record(self, sample):
        self.samples += 1
        if "error" in sample:
            self.errors[sample["error"]] += 1
        epoch = sample.get("epoch")
        if epoch is None:
            if self.epochs:
                next(reversed(self.epochs.values())).add(sample)
            return
        if epoch not in self.epochs:
            length = self.params["epoch_length"]
            if self.epochs:
                last = next(reversed(self.epochs.values()))
                last.closed = True
                self.out(last.line(length))
                self.completed += last.complete(length)
            self.epochs[epoch] = Epoch(epoch, after_previous=bool(self.epochs))
        self.epochs[epoch].add(sample)

    def run(self, interval_s, duration_s, epochs_wanted):
        deadline = None if duration_s is None else time.monotonic() + duration_s
        interrupted = False
        try:
            with open(self.samples_path, "a", encoding="utf-8") as handle:
                while (deadline is None or time.monotonic() < deadline) and (
                        not epochs_wanted or self.completed < epochs_wanted):
                    started = time.monotonic()
                    try:
                        sample = self.sample()
                    except Exception as error:
                        sample = {"at": utc_now(), "error": "sample_failed: %s" % type(error).__name__}
                    handle.write(json.dumps(sample, sort_keys=True) + "\n")
                    handle.flush()
                    self._report_change(sample)
                    self._record(sample)
                    pause = interval_s - (time.monotonic() - started)
                    if deadline is not None:
                        pause = min(pause, deadline - time.monotonic())
                    if pause > 0:
                        time.sleep(pause)
        except KeyboardInterrupt:
            interrupted = True
        return interrupted

    def summary(self, epochs_wanted):
        length = self.params["epoch_length"] if self.params else 0
        epochs = [epoch.to_dict(length) for epoch in self.epochs.values()]
        complete = [item for item in epochs if item["complete"]]
        window = sum(item["window_samples"] for item in epochs)
        ready = sum(item["window_ready"] for item in epochs)
        health, status = collections.Counter(), collections.Counter()
        for epoch in self.epochs.values():
            health.update(epoch.health)
            status.update(epoch.status)
        return {
            "epochs": epochs,
            "totals": {
                "samples": self.samples, "errors": _counter_dict(self.errors),
                "epochs_seen": len(epochs), "epochs_complete": len(complete),
                "epochs_wanted": epochs_wanted or None,
                "goal_reached": (len(complete) >= epochs_wanted) if epochs_wanted else None,
                "window_samples": window, "window_ready": ready,
                "window_ready_share": round(ready / window, 3) if window else None,
                "complete_epochs_with_confirmation_poc": sum(bool(item["confirmation_poc"]) for item in complete),
                "health": _counter_dict(health), "status": _counter_dict(status),
            },
        }
