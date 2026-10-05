"""One request in flight, one send per window slot, budget ledger and run lock."""

import datetime
import fcntl
import json
import os
import time

from .chain import ChainError, epoch_offset, send_window
from .preflight import status_blocker
from .target import gateway_url


class NoSlot(Exception):
    pass


class BudgetSpent(Exception):
    pass


class LockBusy(Exception):
    pass


class RunLock:
    """One live run per machine: the proxy admits one dispatch per block for everyone."""

    def __init__(self, path):
        self.path = path
        self.handle = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        self.handle = open(self.path, "a", encoding="utf-8")
        try:
            fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.handle.close()
            raise LockBusy("another live run holds %s" % self.path)
        return self

    def __exit__(self, *_exc):
        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()


class Ledger:
    """Sends per target and epoch, kept outside run directories and written before sending."""

    def __init__(self, path):
        self.path = path

    def spent(self, target, epoch):
        count = 0
        try:
            with open(self.path, encoding="utf-8") as handle:
                for line in handle:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if entry.get("target") == target and entry.get("epoch") == epoch:
                        count += 1
        except FileNotFoundError:
            pass
        return count

    def reserve(self, entry):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())


class Scheduler:
    def __init__(self, client, chain, preset, facts, ledger, run_id, log):
        self.client = client
        self.chain = chain
        self.preset = preset
        self.params = {"epoch_length": facts["epoch_length"], "safe_start": facts["safe_start"]}
        self.window = send_window(self.params, preset)
        self.ledger = ledger
        self.run_id = run_id
        self.log = log
        self.sent = 0
        self.last_height = None

    def next_slot(self, wait_s):
        low, high = self.window
        length = self.params["epoch_length"]
        gap = int(self.preset["min_blocks_between_sends"])
        deadline = time.monotonic() + wait_s
        reason = "no send window within %ds" % wait_s
        logged_at = None
        while time.monotonic() < deadline:
            try:
                height, _ = self.chain.height()
                offset = epoch_offset(self.chain, height)
            except ChainError as error:
                reason = error.reason
                continue
            if not low <= offset <= high:
                reason = "epoch offset %d outside %d..%d" % (offset, low, high)
                if logged_at is None or time.monotonic() - logged_at >= 60:
                    logged_at = time.monotonic()
                    self.log("waiting for send window %d..%d: epoch offset %d, %d blocks to go"
                             % (low, high, offset, (low - offset) % length))
                continue
            if self.last_height is not None and height - self.last_height < gap:
                continue
            reply = self.client.get(gateway_url(self.preset) + "/v1/status")
            blocker = status_blocker(reply.json) if reply.ok else "status HTTP %s" % reply.status
            if blocker is not None:
                reason = "gateway %s" % blocker
                self.log("waiting: %s" % reason)
                continue
            try:
                epoch, _ = self.chain.epoch_index()
            except ChainError as error:
                reason = error.reason
                continue
            return {"height": height, "epoch": epoch, "offset": offset, "start": height - offset}
        raise NoSlot(reason)

    def reserve(self, check, slot):
        budget = self.preset["budget"]
        target = gateway_url(self.preset)
        if self.sent >= int(budget["per_run"]):
            raise BudgetSpent("run budget of %s POST spent" % budget["per_run"])
        spent = self.ledger.spent(target, slot["epoch"])
        if spent >= int(budget["per_epoch"]):
            raise BudgetSpent("epoch %d budget of %s POST spent" % (slot["epoch"], budget["per_epoch"]))
        self.ledger.reserve({
            "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "target": target, "epoch": slot["epoch"], "height": slot["height"],
            "run": self.run_id, "check": check,
        })
        self.sent += 1
        self.last_height = slot["height"]
