"""Append-only run records and the run manifest."""

import datetime
import json
import os
import threading


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class Recorder:
    def __init__(self, run_dir):
        os.makedirs(run_dir, mode=0o700, exist_ok=False)
        self.run_dir = run_dir
        self.path = os.path.join(run_dir, "records.jsonl")
        self.seq = 0
        self.lock = threading.Lock()

    def write(self, kind, **fields):
        with self.lock:
            self.seq += 1
            entry = {"seq": self.seq, "at": utc_now(), "kind": kind}
            entry.update(fields)
            with open(self.path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry, sort_keys=True) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            return entry["seq"]

    def write_json(self, name, payload):
        path = os.path.join(self.run_dir, name)
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        return path
