#!/usr/bin/env python3
"""Prepare bounded, whole-params DevShard deltas; never sign or broadcast."""

import argparse
import copy
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


AUTHORITY = "gonka10d07y265gmmuvt4z0w9aw880jnsr700j2h5m33"
ARTIFACTS = {
    "activate": ("5.0.2", "fa9f30775abfc14c40ac8d8a9bae7159f6193cd820f3dfac06a60170cd8b48a1"),
    "recover": ("5.0.1", "e4dcde3990a3af62efcf6af5da8557b05ed3a98ede4a343aab020986a68a2012"),
}
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field")
        result[key] = value
    return result


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"),
                      object_pairs_hook=unique_object,
                      parse_constant=lambda _: require(False, "non-finite JSON number"))


def digest(value):
    # Match existing GDC snapshot verification, including jq's final newline.
    encoded = subprocess.run(["jq", "-cS", "."], input=json.dumps(value),
                             text=True, capture_output=True, check=True).stdout
    return hashlib.sha256(encoded.encode()).hexdigest()


def address(value):
    require(isinstance(value, str) and re.fullmatch(r"gonka1[" + CHARSET + r"]{38}", value),
            "creator must be a lowercase gonka account address")
    hrp, data = value.rsplit("1", 1)
    numbers = [CHARSET.index(char) for char in data]
    expanded = [ord(char) >> 5 for char in hrp] + [0] + [ord(char) & 31 for char in hrp]
    checksum = 1
    for number in expanded + numbers:
        top = checksum >> 25
        checksum = ((checksum & 0x1FFFFFF) << 5) ^ number
        for bit, generator in enumerate((0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)):
            if (top >> bit) & 1:
                checksum ^= generator
    require(checksum == 1, "creator checksum mismatch")
    return value


def params(document):
    require(isinstance(document, dict), "full params must be an object")
    value = document.get("params", document)
    require(isinstance(value, dict) and isinstance(value.get("devshard_escrow_params"), dict),
            "full inference params missing devshard_escrow_params")
    escrow = value["devshard_escrow_params"]
    versions = escrow.get("approved_versions")
    creators = escrow.get("allowed_creator_addresses")
    require(isinstance(versions, list) and versions, "approved_versions must be nonempty")
    names = []
    for item in versions:
        require(isinstance(item, dict), "version must be an object")
        name = item.get("name")
        require(isinstance(name, str) and re.fullmatch(r"v[1-9][0-9]*", name), "invalid version name")
        require(isinstance(item.get("binary"), str) and item["binary"].startswith("https://"),
                "invalid archive URL")
        require(isinstance(item.get("sha256"), str) and re.fullmatch("[0-9a-f]{64}", item["sha256"]),
                "invalid archive hash")
        names.append(name)
    require(len(names) == len(set(names)) and "v5" in names, "duplicate names or absent v5")
    require(isinstance(creators, list), "creator list missing")
    for creator in creators:
        address(creator)
    require(len(creators) == len(set(creators)), "duplicate creators")
    return value


def delta(before, after, path=""):
    if type(before) is type(after) and before == after:
        return []
    if isinstance(before, dict) and isinstance(after, dict):
        changes = []
        for key in sorted(before.keys() | after.keys()):
            child = path + "/" + key.replace("~", "~0").replace("/", "~1")
            if key not in before:
                changes.append({"op": "add", "path": child, "value": after[key]})
            elif key not in after:
                changes.append({"op": "remove", "path": child, "before": before[key]})
            else:
                changes.extend(delta(before[key], after[key], child))
        return changes
    return [{"op": "replace", "path": path, "before": before, "value": after}]


def preview(document, expected, action, creators=()):
    before = params(document)
    require(isinstance(expected, str) and re.fullmatch("[0-9a-f]{64}", expected), "expected preimage required")
    require(digest(before) == expected, "stale params preimage; fetch and review the complete document again")
    require(action in ("activate", "recover", "retire"), "unknown delta")
    desired = copy.deepcopy(before)
    escrow = desired["devshard_escrow_params"]
    if action == "activate":
        require(len(creators) == 2, "activation requires both creator bindings")
        bound = [address(creator) for creator in creators]
        require(bound[0] != bound[1], "A/B creators must be distinct")
        # An empty list means permissionless creation, not an empty allowlist.
        require(escrow["allowed_creator_addresses"], "permissionless creator policy requires a separate decision")
        for creator in bound:
            if creator not in escrow["allowed_creator_addresses"]:
                escrow["allowed_creator_addresses"].append(creator)
    else:
        require(not creators, "creator bindings are activation-only")
    if action in ARTIFACTS:
        version, sha = ARTIFACTS[action]
        target = next(item for item in escrow["approved_versions"] if item["name"] == "v5")
        target.update(binary=f"https://github.com/gonka-ai/gonka/releases/download/devshard/v{version}/devshardd.zip",
                      sha256=sha)
    else:
        escrow["approved_versions"] = [item for item in escrow["approved_versions"] if item["name"] not in ("v3", "v4")]
    message = {"@type": "/inference.inference.MsgUpdateParams", "authority": AUTHORITY, "params": desired}
    return {"schema": "gdc-devshard-preview/1", "action": action, "submission_enabled": False,
            "before_sha256": expected, "after_sha256": digest(desired),
            "messages_sha256": digest([message]), "delta": delta(before, desired),
            "messages": [message], "desired_params": desired,
            "required_before_submission": ["fresh complete params readback", "explicit live authority",
                                           "accepted artifact/state recovery" if action == "recover" else
                                           "terminal legacy escrow/consumer disposition and verified archive" if action == "retire" else
                                           "accepted fixture and coordinated maintenance"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("hash", "activate", "recover", "retire"))
    parser.add_argument("--params", required=True, type=Path)
    parser.add_argument("--expected-sha256")
    parser.add_argument("--creator", action="append", default=[])
    args = parser.parse_args()
    try:
        document = load(args.params)
        result = digest(params(document)) if args.action == "hash" else preview(
            document, args.expected_sha256, args.action, args.creator)
        print(result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
