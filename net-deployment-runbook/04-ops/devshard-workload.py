#!/usr/bin/env python3
"""Bounded two-gateway workload engine; CLI previews only, adapters supply I/O."""

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import stat
import time


SPEC = importlib.util.spec_from_file_location("settings", Path(__file__).with_name("devshard-settings.py"))
settings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(settings)
require = settings.require
ASSETS = Path(__file__).resolve().parents[1] / "data/devshard-workload"
MODEL = "Qwen/Qwen3-0.6B"
CORPUS_HASH = "82756c78d9f1c8725be6a616eb5d67f23252953c4a2543167359dde51e116851"
ARTIFACT = "4cdffe680b700924e5f1c67a0e8a5113c8edb5896186214cf0d1d96089dfb832"
CONTRACT = "gdc-devshard-workload/3"
REQUESTS, RUNS, LIFETIME, ESCROWS = 20, 2, 60, 16
WALL_SECONDS = 14400
REQUEST_SECONDS, DRAIN_SECONDS, FRESH_SECONDS = 60, 90, 5


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def decode(value):
    return json.loads(value, object_pairs_hook=settings.instances.preview.unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite JSON number")))


def number(value, minimum=0):
    return type(value) in (int, float) and math.isfinite(value) and value >= minimum


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


def payloads(directory=ASSETS):
    body = (directory / "corpus.json").read_bytes()
    require(hashlib.sha256(body).hexdigest() == CORPUS_HASH, "frozen corpus changed")
    corpus = decode(body)
    manifest = decode((directory / "manifest.json").read_bytes())
    require(manifest["corpus_sha256"] == CORPUS_HASH and manifest["model"] == MODEL, "corpus manifest mismatch")
    require([case["id"] for case in corpus["cases"]] == [f"DOC-{i:02d}" for i in range(1, 21)], "case order changed")
    require([sample["id"] for sample in manifest["samples"]] == [case["id"] for case in corpus["cases"]],
            "sizing sample order changed")
    result = {}
    for case, sample in zip(corpus["cases"], manifest["samples"]):
        require(all(integer(n, 1) and n <= 1024 for n in sample["input_tokens_thinking_off_on"]), "input cap exceeded")
        for streaming in (False, True):
            body = canonical({"model": MODEL, "messages": [
                {"role": "system", "content": corpus["system"]},
                {"role": "user", "content": corpus["user_format"].format(passage=case["passage"], question=case["question"])}],
                "max_tokens": 128, "temperature": 0, "top_p": 1, "stream": streaming})
            require(hashlib.sha256(body).hexdigest() == sample["payload_sha256_by_stream"][str(streaming).lower()],
                    "frozen wire payload changed")
            # Preserve the historical wire binding before the versioned SSE
            # opt-in required for the gateway's final token-usage event.
            if streaming:
                body = canonical({**decode(body), "stream_options": {"include_usage": True}})
            result[(case["id"], streaming)] = body
    return result


def schedule(run):
    require(type(run) is int and 1 <= run <= RUNS, "run must be 1 or 2")
    return [{"request_id": f"run-{run}-{gateway}-{j:03d}", "run": run, "gateway": gateway,
             "index": j, "case": f"DOC-{j + 1:02d}", "stream": (j + run - 1) % 2 == 1}
            for j in range(REQUESTS) for gateway in (("A", "B") if j % 2 == 0 else ("B", "A"))]


def execution_manifest():
    wires = payloads()
    return {"schema": CONTRACT, "corpus_sha256": CORPUS_HASH, "model": MODEL,
            "limits": {"attempts_per_gateway": LIFETIME, "escrows_per_gateway": ESCROWS,
                       "inflight_per_gateway": 1, "output_tokens": 128,
                       "request_seconds": REQUEST_SECONDS, "drain_seconds": DRAIN_SECONDS,
                       "wall_seconds_per_run": WALL_SECONDS},
            "schedule": [{**item, "payload_sha256": hashlib.sha256(wires[(item["case"], item["stream"])]).hexdigest()}
                         for run in range(1, RUNS + 1) for item in schedule(run)]}


def response(body, streaming):
    """Shape acceptance only. Factual checklists always require separate review."""
    require(isinstance(body, str), "response body must be text")
    documents = []
    if streaming:
        blocks = body.replace("\r\n", "\n").split("\n\n")
        done = False
        for block in blocks:
            if not block.strip():
                continue
            lines = block.splitlines()
            require(all(line.startswith(("data:", ":", "event:", "id:", "retry:")) for line in lines), "invalid SSE framing")
            data = "\n".join(line[5:].lstrip(" ") for line in lines if line.startswith("data:"))
            if not data:
                continue
            require(not done, "data after SSE termination")
            if data == "[DONE]":
                done = True
            else:
                documents.append(decode(data))
        require(done and body.replace("\r\n", "\n").endswith("\n\n"), "incomplete SSE termination")
    else:
        documents = [decode(body)]
    require(documents and all(isinstance(doc, dict) for doc in documents), "missing response object")
    identifier = documents[0].get("id")
    require(isinstance(identifier, str) and re.fullmatch(r"devshard-[0-9]+-[0-9]+", identifier), "uncorrelated response ID")
    content, usage, finished = [], None, False
    for doc in documents:
        require(doc.get("id") == identifier and doc.get("model") == MODEL and "error" not in doc, "response identity/error mismatch")
        choices = doc.get("choices")
        require(isinstance(choices, list) and len(choices) <= 1, "invalid choices")
        for choice in choices:
            require(type(choice.get("index")) is int and choice["index"] == 0, "invalid choice index")
            message = choice.get("delta" if streaming else "message")
            require(isinstance(message, dict), "invalid message")
            require(message.get("role", "assistant") == "assistant", "invalid response role")
            text = message.get("content", "")
            require(isinstance(text, str), "invalid response content")
            finish = choice.get("finish_reason")
            require(finish in (None, "stop"), "unexpected truncation or finish reason")
            if finished:
                # The official gateway adds one empty stop choice with final
                # accounting after forwarding the model's stop chunk.
                require(streaming and message == {} and finish == "stop" and usage is None and
                        isinstance(doc.get("usage"), dict), "duplicate or late choice")
            else:
                content.append(text)
            finished = finish == "stop"
        if doc.get("usage") is not None:
            require(usage is None or usage == doc["usage"], "conflicting usage")
            usage = doc["usage"]
    require(finished and "".join(content).strip(), "unfinished or empty answer")
    require(isinstance(usage, dict) and all(integer(usage.get(key), 1) for key in
            ("prompt_tokens", "completion_tokens", "total_tokens")), "missing or invalid usage")
    require(usage["prompt_tokens"] <= 1024 and usage["completion_tokens"] <= 128 and
            usage["total_tokens"] == usage["prompt_tokens"] + usage["completion_tokens"], "token limits/accounting mismatch")
    _, escrow, nonce = identifier.split("-")
    return {"id": identifier, "escrow_id": escrow, "nonce": int(nonce), "usage": usage,
            "content": "".join(content), "factual_review": "PENDING"}


class Stop(Exception):
    def __init__(self, outcome, reason):
        super().__init__(reason)
        self.outcome = outcome


class Campaign:
    """One persistent ledger spans both runs and any separately admitted smoke."""

    def __init__(self, directory, bindings, lock_paths):
        self.directory, self.bindings = Path(directory), decode(canonical(bindings))
        self.locks = sorted(map(Path, lock_paths))
        require(len(self.locks) == 2 and len(set(self.locks)) == 2, "two instance locks required")
        require(bindings["chain_id"] in ("gonka-devnet-community", "gonka-test-ds502-isolated"), "unsupported chain")
        require(set(bindings["creators"]) == {"A", "B"} and len(set(bindings["creators"].values())) == 2,
                "distinct A/B creators required")
        require(set(bindings["spend_caps"]) == {"A", "B"} and all(integer(n, 1) for n in bindings["spend_caps"].values()),
                "positive per-gateway spend caps required")
        self.events, self.descriptor = [], None

    def __enter__(self):
        self.stack = contextlib.ExitStack()
        try:
            require(self.directory.absolute() == self.directory.resolve(), "nonsymlink campaign path required")
            lock_binding = {"campaign": str(self.directory.absolute()), "bindings_sha256": hashlib.sha256(canonical(self.bindings)).hexdigest()}
            unbound_locks = []
            for path in self.locks:
                require(path.parent.is_dir() and stat.S_IMODE(path.parent.stat().st_mode) == 0o700, "private lock parent required")
                fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                lock = self.stack.enter_context(os.fdopen(fd, "a+"))
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                require(stat.S_ISREG(os.fstat(fd).st_mode) and stat.S_IMODE(os.fstat(fd).st_mode) == 0o600 and
                        os.fstat(fd).st_uid == os.getuid(), "private owned instance lock required")
                lock.seek(0)
                existing = lock.read()
                if existing:
                    require(decode(existing) == lock_binding, "instance campaign binding drift; never reset lifetime accounting")
                else:
                    unbound_locks.append(lock)
            if not self.directory.exists():
                self.directory.mkdir(mode=0o700)
            require(self.directory.absolute() == self.directory.resolve() and
                    stat.S_IMODE(self.directory.stat().st_mode) == 0o700, "private nonsymlink campaign required")
            path = self.directory / "events.jsonl"
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW, 0o600)
            self.descriptor = self.stack.enter_context(os.fdopen(fd, "a+", encoding="utf-8"))
            require(stat.S_IMODE(os.fstat(fd).st_mode) == 0o600, "private journal required")
            self.descriptor.seek(0)
            previous = "0" * 64
            for line in self.descriptor:
                require(line.endswith("\n"), "interrupted journal append; retain for reconciliation")
                event = decode(line)
                digest = event.pop("sha256")
                require(event["previous"] == previous and hashlib.sha256(canonical(event)).hexdigest() == digest,
                        "journal integrity failure")
                event["sha256"] = digest
                self.events.append(event)
                previous = digest
            if not self.events:
                self.append("campaign", bindings=self.bindings, corpus_sha256=CORPUS_HASH,
                            execution_manifest=execution_manifest())
            require(self.events[0]["kind"] == "campaign" and self.events[0]["bindings"] == self.bindings and
                    self.events[0]["corpus_sha256"] == CORPUS_HASH, "campaign binding drift")
            require(self.events[0].get("execution_manifest") == execution_manifest(),
                    "execution contract changed; preserve the previous campaign")
            admitted = {e["request_id"] for e in self.events if e["kind"] == "admitted"}
            terminal = {e["request_id"] for e in self.events if e["kind"] == "terminal"}
            require(admitted == terminal, "uncertain admitted request; reconciliation required, never redispatch")
            for lock in unbound_locks:
                lock.write(canonical(lock_binding).decode() + "\n")
                lock.flush()
                os.fsync(lock.fileno())
            for directory in {self.directory, self.directory.parent, *(path.parent for path in self.locks)}:
                fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            return self
        except BaseException:
            self.stack.close()
            raise

    def __exit__(self, *args):
        self.descriptor = None
        return self.stack.__exit__(*args)

    def append(self, kind, **fields):
        require(self.descriptor is not None, "campaign lock not held")
        require(not {"kind", "previous", "sha256"} & fields.keys(), "reserved journal fields")
        event = {"kind": kind, "previous": self.events[-1]["sha256"] if self.events else "0" * 64, **fields}
        event["sha256"] = hashlib.sha256(canonical(event)).hexdigest()
        self.descriptor.write(canonical(event).decode() + "\n")
        self.descriptor.flush()
        os.fsync(self.descriptor.fileno())
        self.events.append(decode(canonical(event)))

    def admit(self, item, state, wire, now):
        require(not any(e.get("request_id") == item["request_id"] for e in self.events), "request already recorded")
        admitted = [e for e in self.events if e["kind"] == "admitted"]
        own = [e for e in admitted if e["gateway"] == item["gateway"]]
        if len(own) >= LIFETIME:
            raise Stop("BLOCKED", "lifetime request cap")
        escrows = {e["before"]["escrow_id"] for e in own} | {state["escrow_id"]}
        if len(escrows) > ESCROWS:
            raise Stop("BLOCKED", "lifetime escrow cap")
        require(not any(e["gateway"] != item["gateway"] and e["before"]["escrow_id"] == state["escrow_id"] for e in admitted),
                "escrow shared by independent gateways")
        terminal = {e["request_id"]: e for e in self.events if e["kind"] == "terminal"}
        spent = sum(terminal.get(e["request_id"], {}).get("charged", e["before"]["request_reserve"]) for e in own)
        if spent + state["request_reserve"] > self.bindings["spend_caps"][item["gateway"]]:
            raise Stop("BLOCKED", "campaign spend cap")
        self.append("admitted", **item, before=state, time=now, payload=wire.decode(),
                    payload_sha256=hashlib.sha256(wire).hexdigest())


def eligibility(observation, now, bindings):
    require(observation["chain_id"] == bindings["chain_id"], "chain drift")
    require(number(observation["observed_at"]) and 0 <= now - observation["observed_at"] <= FRESH_SECONDS,
            "stale or future phase observation")
    require(integer(observation["height"], 1) and integer(observation["epoch"], 1), "invalid chain position")
    require(observation["phase"] in ("Inference", "PoC", "Voting") and type(observation["cpoc"]) is bool,
            "unknown phase")
    intervals = observation["block_intervals"]
    require(len(intervals) == 20 and all(number(n, 0.001) for n in intervals), "twenty positive block intervals required")
    require(integer(observation["blocks_to_poc"]), "invalid PoC margin")
    require(set(observation["gateways"]) == {"A", "B"}, "both gateway observations required")
    ready = observation["phase"] == "Inference" and not observation["cpoc"] and (
        observation["blocks_to_poc"] * min(intervals) - (now - observation["observed_at"]) > DRAIN_SECONDS)
    ids = set()
    for name, state in observation["gateways"].items():
        require(state["creator"] == bindings["creators"][name] and state["model"] == MODEL and
                state["protocol"] == "v5" and state["artifact_sha256"] == ARTIFACT, "gateway/runtime identity drift")
        require(isinstance(state["escrow_id"], str) and re.fullmatch(r"[1-9][0-9]*", state["escrow_id"]), "invalid escrow ID")
        require(state["escrow_id"] not in ids, "A/B share escrow")
        ids.add(state["escrow_id"])
        require(all(integer(state[key]) for key in ("nonce", "balance", "active_requests", "pending_cleanup")), "invalid runtime counters")
        require(integer(state["max_nonce"], 1) and state["max_nonce"] <= 20000 and integer(state["nonce_reserve"], 1) and
                integer(state["request_reserve"], 1), "unbounded nonce/spend reservation")
        require(state["rotation"] is False and state["settlement"] is False, "automatic escrow lifecycle enabled")
        require(integer(state["context_tokens"], 1152), "unverified model context capacity")
        require(type(state["routable"]) is bool and integer(state["escrow_epoch"], 1), "invalid capacity observation")
        if state["nonce"] + state["nonce_reserve"] > state["max_nonce"] or state["balance"] < state["request_reserve"]:
            raise Stop("BLOCKED", "escrow nonce or balance cap")
        ready = ready and state["routable"] and state["escrow_epoch"] == observation["epoch"] and (
            state["active_requests"] == 0 and state["pending_cleanup"] == 0)
    return ready


class Runner:
    def __init__(self, campaign, observe, send, clock=time):
        self.campaign, self.observe, self.send, self.clock = campaign, observe, send, clock
        self.wires = payloads()

    def attempt(self, item, observation, wall_deadline):
        require(eligibility(observation, self.clock.time(), self.campaign.bindings), "request not eligible")
        if self.clock.monotonic() >= wall_deadline:
            raise Stop("BLOCKED", "run deadline before dispatch")
        name = item["gateway"]
        before = observation["gateways"][name]
        wire = self.wires[(item["case"], item["stream"])]
        self.campaign.admit(item, before, wire, self.clock.time())
        started = self.clock.monotonic()
        terminal = {"request_id": item["request_id"], "gateway": name, "outcome": "INCONCLUSIVE",
                    "reason": "dispatch outcome uncertain", "charged": before["request_reserve"]}
        parsed = None
        try:
            result = self.send(name, wire, min(wall_deadline, started + REQUEST_SECONDS), item["request_id"])
            self.campaign.append("response", request_id=item["request_id"], result=result)
            if result.get("body_complete") is not True or result.get("transport_error") is not None:
                raise OSError("incomplete transport result; outcome uncertain")
            require(number(result["elapsed_seconds"]) and result["elapsed_seconds"] <= REQUEST_SECONDS and
                    self.clock.monotonic() - started <= REQUEST_SECONDS, "request deadline exceeded")
            require(result["http_status"] == 200, "unexpected HTTP status")
            if item["stream"]:
                require(number(result["ttft_seconds"]) and result["ttft_seconds"] <= result["elapsed_seconds"], "missing/invalid TTFT")
            parsed = response(result["body"], item["stream"])
            terminal.update(outcome="PASS", reason="response shape accepted; factual review pending", response=parsed,
                            elapsed_seconds=result["elapsed_seconds"], ttft_seconds=result.get("ttft_seconds"))
        except (Exception, KeyboardInterrupt) as error:
            terminal.update(outcome="FAIL" if isinstance(error, ValueError) else "INCONCLUSIVE",
                            reason=f"dispatch/response failed ({type(error).__name__}); no retry")
        drain_deadline = min(wall_deadline, self.clock.monotonic() + DRAIN_SECONDS)
        try:
            while self.clock.monotonic() < drain_deadline:
                after_observation = self.observe(drain_deadline)
                after = after_observation["gateways"][name]
                require(after_observation["chain_id"] == self.campaign.bindings["chain_id"] and
                        0 <= self.clock.time() - after_observation["observed_at"] <= FRESH_SECONDS, "stale drain observation")
                self.campaign.append("drain", request_id=item["request_id"], observation=after_observation)
                require(all(after[key] == before[key] for key in ("creator", "escrow_id", "model", "protocol", "artifact_sha256")),
                        "post-dispatch identity drift")
                require(all(integer(after[key]) for key in ("nonce", "balance", "active_requests", "pending_cleanup")), "invalid drain counters")
                if after["active_requests"] == 0 and after["pending_cleanup"] == 0:
                    charge = before["balance"] - after["balance"]
                    require(charge >= 0 and after["nonce"] >= before["nonce"], "runtime accounting went backwards")
                    terminal.update(charged=charge, observed_charge=charge, after=after)
                    require(charge <= before["request_reserve"], "request exceeded reserved spend")
                    if parsed:
                        require(parsed["escrow_id"] == before["escrow_id"] and
                                before["nonce"] < parsed["nonce"] == after["nonce"] <= before["nonce"] + before["nonce_reserve"],
                                "response/escrow/nonce correlation failed")
                    break
                self.clock.sleep(min(1, max(0, drain_deadline - self.clock.monotonic())))
            else:
                raise TimeoutError("drain deadline")
        except (Exception, KeyboardInterrupt) as error:
            terminal.update(outcome="INCONCLUSIVE", reason=f"post-dispatch accounting unresolved ({type(error).__name__})")
        if terminal["outcome"] != "PASS":
            terminal["charged"] = max(terminal["charged"], before["request_reserve"])
        self.campaign.append("terminal", **terminal)
        if terminal["outcome"] != "PASS":
            raise Stop(terminal["outcome"], terminal["reason"])
        return terminal

    def run(self, run):
        items = schedule(run)
        starts = [e for e in self.campaign.events if e["kind"] == "run-start"]
        finishes = [e for e in self.campaign.events if e["kind"] == "run-terminal"]
        require(len(starts) == len(finishes) == run - 1 and all(e["automated_outcome"] == "PASS" for e in finishes),
                "previous run missing, incomplete or failed; no rerun")
        require(all(e["outcome"] == "PASS" for e in self.campaign.events if e["kind"] == "terminal"),
                "campaign contains failed or uncertain attempts")
        self.campaign.append("run-start", run=run, time=self.clock.time())
        started = previous = self.clock.monotonic()
        deadline, eligible, was_ready, index = started + WALL_SECONDS, 0.0, False, 0
        results = []
        outcome, reason = "PASS", "automated schedule complete; factual review pending"
        try:
            while index < len(items):
                if self.clock.monotonic() >= deadline:
                    raise Stop("BLOCKED", "four-hour run deadline")
                observation = self.observe(deadline)
                now = self.clock.monotonic()
                if now >= deadline:
                    raise Stop("BLOCKED", "four-hour run deadline")
                ready = eligibility(observation, self.clock.time(), self.campaign.bindings)
                # Credit only short, independently observed eligible segments.
                if ready and was_ready and 0 <= now - previous <= FRESH_SECONDS:
                    eligible += now - previous
                previous, was_ready = now, ready
                self.campaign.append("observation", run=run, eligible_seconds=eligible, ready=ready, observation=observation)
                if ready:
                    item = items[index]
                    results.append(self.attempt(item, observation, deadline))
                    index += 1
                else:
                    self.campaign.append("quiet", run=run, reason="phase/capacity")
                    self.clock.sleep(min(1, max(0, deadline - self.clock.monotonic())))
        except Stop as error:
            outcome, reason = error.outcome, str(error)
        except (Exception, KeyboardInterrupt) as error:
            outcome, reason = "BLOCKED", f"observation or execution stopped ({type(error).__name__})"
        summary = {"run": run, "automated_outcome": outcome, "reason": reason,
                   "eligible_seconds": eligible, "wall_seconds": self.clock.monotonic() - started,
                   "completed": {name: sum(row["gateway"] == name for row in results) for name in ("A", "B")},
                   "factual_review": "PENDING", "release_acceptance": "NOT PROVEN"}
        for name in ("A", "B"):
            own = [r for r in results if r["gateway"] == name]
            latencies = sorted(row["elapsed_seconds"] for row in own)
            ttft = sorted(row["ttft_seconds"] for row in own if row["ttft_seconds"] is not None)
            summary[name] = {"latency_p50": percentile(latencies, .5), "latency_p95": percentile(latencies, .95),
                             "ttft_p50": percentile(ttft, .5), "ttft_p95": percentile(ttft, .95),
                             "tokens": sum(row["response"]["usage"]["total_tokens"] for row in own),
                             "requests_per_eligible_second": len(own) / eligible if eligible else None}
        self.campaign.append("run-terminal", **summary)
        return summary


def percentile(values, fraction):
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview-run", required=True, type=int, choices=(1, 2))
    args = parser.parse_args()
    manifest = execution_manifest()
    print(json.dumps({**manifest, "preview_run": args.preview_run,
                      "schedule": [item for item in manifest["schedule"] if item["run"] == args.preview_run]}, indent=2))


if __name__ == "__main__":
    main()
