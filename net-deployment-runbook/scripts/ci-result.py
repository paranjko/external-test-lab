#!/usr/bin/env python3
"""Fail closed unless routing and every selected CI job succeeded."""
import json
import os


def verify(needs, required):
    if needs.get("route", {}).get("result") != "success":
        raise ValueError("CI routing did not succeed")
    if not isinstance(required, list) or not all(isinstance(v, str) for v in required):
        raise ValueError("Invalid required-job manifest")
    failed = [name for name in required if needs.get(name, {}).get("result") != "success"]
    if failed:
        raise ValueError("Required jobs did not pass: " + ", ".join(failed))


if __name__ == "__main__":
    verify(json.loads(os.environ["CI_NEEDS"]), json.loads(os.environ["CI_REQUIRED"]))
    print("All selected runbook checks passed")
