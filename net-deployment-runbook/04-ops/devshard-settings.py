#!/usr/bin/env python3
"""Preview or explicitly apply complete, preimage-bound gateway settings."""

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


SPEC = importlib.util.spec_from_file_location("instances", Path(__file__).with_name("devshard-instances.py"))
instances = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(instances)
require = instances.require


class Journal:
    """Each operation has an exclusive new private directory and immutable entries."""

    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(mode=0o700, parents=False, exist_ok=False)
        self.sequence = 0

    def record(self, kind, value):
        self.sequence += 1
        path = self.directory / f"{self.sequence:03d}-{kind}.json"
        body = json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode() + b"\n"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        return hashlib.sha256(body).hexdigest()


class Gateway:
    def __init__(self, port, secret_file):
        require(type(port) is int and 1024 <= port <= 65535, "invalid local gateway port")
        self.port = port
        self.secret_file = instances.private_file(secret_file)
        instances.secrets(self.secret_file)

    def request(self, method, path, payload=None):
        require(method in ("GET", "POST") and path in ("/v1/admin/settings", "/v1/models"),
                "unsupported gateway settings operation")
        values = dict(line.split("=", 1) for line in self.secret_file.read_text().splitlines()
                      if line and not line.startswith("#"))
        key = values["DEVSHARD_ADMIN_API_KEY"]
        # curl receives auth over stdin, never process arguments or an evidence file.
        config = f'header = "Authorization: Bearer {key}"\n'
        arguments = ["curl", "--silent", "--show-error", "--fail", "--connect-timeout", "5",
                     "--max-time", "30", "--noproxy", "*", "--proto", "=http", "--config", "-",
                     "--request", method, f"http://127.0.0.1:{self.port}{path}"]
        with tempfile.TemporaryDirectory(prefix="gdc-settings-") as directory:
            if payload is not None:
                file = Path(directory) / "settings.json"
                with file.open("x", encoding="utf-8") as stream:
                    os.chmod(file, 0o600)
                    json.dump(payload, stream, ensure_ascii=False)
                arguments += ["--header", "Content-Type: application/json", "--data-binary", f"@{file}"]
            try:
                result = subprocess.run(arguments, input=config, text=True, capture_output=True, timeout=35)
            except subprocess.TimeoutExpired:
                raise ValueError("gateway request deadline exceeded; outcome may be uncertain") from None
        require(result.returncode == 0, "gateway request failed; no automatic retry")
        try:
            return json.loads(result.stdout, object_pairs_hook=instances.preview.unique_object)
        except ValueError:
            raise ValueError("gateway returned invalid JSON") from None


def configure(gateway, journal, model, expected=None, apply=False):
    before = gateway.request("GET", "/v1/admin/settings")
    catalog = gateway.request("GET", "/v1/models")
    require(isinstance(catalog, dict) and isinstance(catalog.get("data"), list), "invalid model catalog")
    models = [row.get("id") for row in catalog["data"] if isinstance(row, dict)]
    desired = instances.settings(before, model, models)
    preimage = instances.preview.digest(before)
    receipt = {"schema": "gdc-devshard-settings/1", "before_sha256": preimage,
               "desired_sha256": instances.preview.digest(desired),
               "delta": instances.preview.delta(before, desired), "applied": False}
    journal.record("before", before)
    journal.record("desired", desired)
    journal.record("preview", receipt)
    if not apply:
        return receipt
    require(expected == preimage, "settings preimage changed; review a fresh preview")
    # A stale read must not overwrite another operator's policy update.
    require(gateway.request("GET", "/v1/admin/settings") == before, "settings drift before POST")
    journal.record("dispatch", {"method": "POST", "path": "/v1/admin/settings", "time_unix": time.time()})
    try:
        gateway.request("POST", "/v1/admin/settings", desired)
        actual = gateway.request("GET", "/v1/admin/settings")
        journal.record("readback", actual)
        require(actual == desired, "full settings readback mismatch; stop before traffic")
    except (ValueError, OSError):
        journal.record("terminal", {"outcome": "INCONCLUSIVE", "reason": "POST or readback failed; no retry or restore"})
        raise
    receipt.update(applied=True, outcome="PASS", after_sha256=instances.preview.digest(actual))
    journal.record("terminal", receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--secret-file", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()
    try:
        gateway = Gateway(args.port, args.secret_file)
        # All callers targeting this instance share the lock; evidence paths do not.
        lock_path = gateway.secret_file.parent / ".settings.lock"
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            receipt = configure(gateway, Journal(args.evidence), args.model,
                                args.expected_sha256, args.apply)
        print(json.dumps(receipt, sort_keys=True))
    except (ValueError, OSError, TypeError, KeyError) as error:
        print(f"BLOCKED: settings operation failed ({type(error).__name__}); retained evidence requires inspection", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
