#!/usr/bin/env python3
"""Read-only, exact-preimage preview for existing official A/B Compose scopes."""

import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys


SPEC = importlib.util.spec_from_file_location("instances", Path(__file__).with_name("devshard-instances.py"))
instances = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(instances)
require = instances.require


def preview(raw, identity, expected):
    require(identity in ("A", "B"), "known native instance required")
    before = hashlib.sha256(raw).hexdigest()
    require(re.fullmatch(r"[0-9a-f]{64}", expected or "") and before == expected,
            "stale native Compose preimage")
    document = json.loads(raw, object_pairs_hook=instances.preview.unique_object)
    require(isinstance(document, dict) and isinstance(document.get("services"), dict)
            and set(document["services"]) == {"gateway"}, "dedicated gateway layout required")
    service = document["services"]["gateway"]
    require(isinstance(service, dict) and service.get("image") == instances.IMAGE
            and service.get("platform") == "linux/amd64", "qualified native image required")
    require(not service.get("command") and not service.get("entrypoint")
            and not service.get("network_mode"), "native process contract differs")
    labels = service.get("labels", {})
    require(labels.get("org.gonka.test-lab.scope") == "two-gateways"
            and labels.get("org.gonka.test-lab.instance") == identity, "native instance binding differs")
    volume = "gdc-ds502-" + identity.lower() + "-data"
    require(document.get("volumes", {}).get("state", {}).get("name") == volume
            and service.get("volumes") == ["state:/root/.devshardctl"], "retained state binding differs")
    environment = service.get("environment")
    require(isinstance(environment, dict) and not set(environment) & instances.SECRET_NAMES,
            "inline secrets are not accepted")
    require(environment.get("DEVSHARD_CHAIN_ID") == "gonka-devnet-community"
            and environment.get("DEVSHARD_ROUTE_PREFIX") == "/devshard/v5",
            "qualified chain and protocol required")
    old = environment.get(instances.CHAT_CACHE_KEY)
    require(old is None or isinstance(old, str) and re.fullmatch(r"[0-9]+", old),
            "invalid existing cache policy")
    desired = copy.deepcopy(document)
    desired["services"]["gateway"]["environment"][instances.CHAT_CACHE_KEY] = instances.TEST_STAND_CACHE_MAX_BYTES
    changed = old != instances.TEST_STAND_CACHE_MAX_BYTES
    # Desired bytes are a private apply input, never part of the public receipt
    output = (json.dumps(desired, ensure_ascii=False, indent=2) + "\n").encode() if changed else raw
    receipt = {"schema": "gdc-devshard-cache-policy/1", "id": identity,
               "before_sha256": before, "desired_sha256": hashlib.sha256(output).hexdigest(),
               "image": instances.IMAGE, "state_volume": volume, "applied": False,
               "requires_drain_restart": changed,
               "delta": [{"field": instances.CHAT_CACHE_KEY, "before": old,
                          "after": instances.TEST_STAND_CACHE_MAX_BYTES}] if changed else []}
    return receipt, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compose", type=Path, required=True)
    parser.add_argument("--id", choices=("A", "B"), required=True)
    parser.add_argument("--expected-sha256", required=True)
    args = parser.parse_args()
    try:
        target = Path("/srv/dai/broker-tests/ds502-" + args.id.lower() + "/compose.json")
        require(args.compose == target and target.resolve(strict=True) == target
                and target.is_file(), "exact nonsymlink native Compose target required")
        receipt, _ = preview(target.read_bytes(), args.id, args.expected_sha256)
        print(json.dumps(receipt, sort_keys=True))
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        print("Native cache-policy preview refused, no files or services changed", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
