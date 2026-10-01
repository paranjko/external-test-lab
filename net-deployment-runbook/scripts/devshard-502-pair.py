#!/usr/bin/env python3
"""Start a fresh, checksum-bound A/B fixture once; never remove or reset state."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time


SPEC = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("devshard-502-fixture.py"))
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)
require = fixture.require


def docker(*args):
    return subprocess.run(["docker", "--context", "default", *map(str, args)],
                          capture_output=True, text=True, timeout=120, check=True).stdout


def load(root, expected):
    require(root == root.resolve() and root.name.startswith("ds502-fixture-"), "exact fixture path required")
    require(fixture.digest(root / "prepared.json") == expected, "preparation receipt hash mismatch")
    receipt = json.loads((root / "prepared.json").read_text())
    require(receipt["schema"] == "gdc-ds502-fixture/2" and receipt["two_gateways"] is True and
            receipt["initial_version"] == "5.0.2" and receipt["source"] == fixture.SOURCE,
            "fresh official A/B preparation required")
    require(fixture.digest(root / "config.yaml") == receipt.get("config_sha256"), "prepared chain seed drift or missing binding")
    documents = {}
    for name in ("infra", "a", "b"):
        path = root / ("compose.json" if name == "infra" else "compose-" + name + ".json")
        expected_hash = receipt["compose_sha256"] if name == "infra" else receipt["gateway_compose_sha256"][name]
        require(fixture.digest(path) == expected_hash, "prepared composition drift")
        documents[name] = json.loads(path.read_text())
    project = receipt["project"]
    require(project == "ds502-fixture-" + fixture.hashlib.sha256(str(root).encode()).hexdigest()[:12],
            "fixture project/path mismatch")
    require(documents["infra"]["networks"]["fixture"]["internal"] is True, "internal network required")
    keys, stores = set(), set()
    for name, document in documents.items():
        owner = project if name == "infra" else project + "-" + name
        require(document["name"] == owner, "project ownership drift")
        expected_services = {"mock-chain", "mock-dapi", "mock-openai", "versiond-0"} if name == "infra" else {"gateway"}
        require(set(document["services"]) == expected_services, "unexpected fixture service")
        for service_name, service in document["services"].items():
            require(service["restart"] == "no" and service["labels"] == {
                "org.gonka.test-lab.scope": "ds502-fixture", "org.gonka.test-lab.owner": owner}, "unowned fixture service")
            require(service["image"] == (fixture.GATEWAY if service_name == "gateway" else fixture.VERSIOND),
                    "nonofficial runtime image")
            require(set(service["networks"]) == {"fixture"}, "extra network forbidden")
            for mount in service["volumes"]:
                require(mount["type"] == "bind" and Path(mount["source"]).resolve().is_relative_to(root), "mount escaped fixture")
            if service_name == "gateway":
                env = service["environment"]
                require(env["DEVSHARD_CHAIN_ID"] == fixture.CHAIN and env["DEVSHARDS_JSON"] == "[]" and
                        env["DEVSHARD_ESCROW_ROTATION_ENABLED"] == env["DEVSHARD_ESCROW_ROTATION_SETTLEMENT_ENABLED"] == "false",
                        "fresh isolated gateway settings required")
                for field in ("DEVSHARD_PRIVATE_KEY", "DEVSHARD_ADMIN_API_KEY", "DEVSHARD_API_KEYS"):
                    require(env[field] not in keys, "shared A/B credential")
                    keys.add(env[field])
                source = str(root / ("data/gateway-" + name))
                require(service["volumes"] == [fixture.bind(source, "/var/lib/devshardctl", False)] and source not in stores,
                        "shared or inherited gateway storage")
                stores.add(source)
    return receipt, documents


def fresh(root, receipt, containers, networks):
    owners = {receipt["project"] + suffix for suffix in ("", "-a", "-b")}
    require(receipt["project"] + "_fixture" not in networks, "fixture network already exists")
    for item in containers:
        labels = item["Config"].get("Labels") or {}
        require(labels.get("com.docker.compose.project") not in owners and
                labels.get("org.gonka.test-lab.owner") not in owners, "fixture container already exists")
        if item["State"]["Running"]:
            for mount in item["Mounts"]:
                if mount["Type"] == "bind" and mount.get("RW"):
                    source = Path(mount["Source"]).resolve()
                    require(not (source.is_relative_to(root) or root.is_relative_to(source)), "another container can write fixture state")
    for relative in ("data/host", "data/bin", "data/gateway-a", "data/gateway-b"):
        path = root / relative
        require(path.is_dir() and not path.is_symlink() and not any(path.iterdir()), "fresh empty writer directories required")


def record(path, value):
    fixture.write_json(path, value)
    for target in (path, path.parent):
        fd = os.open(target, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def start(root, expected):
    receipt, documents = load(root, expected)
    require(not (root / "start-intent.json").exists(), "start already attempted; inspect retained state, never retry blindly")
    ids = docker("ps", "-aq").split()
    containers = json.loads(docker("inspect", *ids)) if ids else []
    fresh(root, receipt, containers, docker("network", "ls", "--format", "{{.Name}}").splitlines())
    for name in fixture.HELPERS:
        require(fixture.digest(root / "helpers" / name) == receipt["helpers"][name], "helper byte drift")
    require(fixture.digest(root / "binaries/devshardd-5.0.2.zip") == fixture.ARTIFACTS["5.0.2"][0], "official archive drift")
    images = json.loads(docker("image", "inspect", fixture.GATEWAY, fixture.VERSIOND))
    require([image["Id"] for image in images] == [image["id"] for image in receipt["images"]], "runtime image drift")
    record(root / "start-intent.json", {"prepared_sha256": expected, "time": time.time(), "projects": [doc["name"] for doc in documents.values()]})
    for name in ("infra", "a", "b"):
        path = root / ("compose.json" if name == "infra" else "compose-" + name + ".json")
        with (root / ("start-" + name + ".log")).open("x") as stream:
            subprocess.run(["docker", "--context", "default", "compose", "-f", str(path), "up", "-d",
                            "--wait", "--wait-timeout", "90", "--pull", "never", "--no-build"],
                           check=True, timeout=120, stdout=stream, stderr=stream)
        network = json.loads(docker("network", "inspect", receipt["project"] + "_fixture"))[0]
        require(network["Internal"] is True and network["Labels"].get("org.gonka.test-lab.owner") == receipt["project"],
                "running fixture network ownership drift")
    record(root / "started.json", {"time": time.time(), "prepared_sha256": expected,
                                   "outcome": "STARTED", "runtime_acceptance": "NOT PROVEN"})
    print(json.dumps({"outcome": "STARTED", "project": receipt["project"], "runtime_acceptance": "NOT PROVEN"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--receipt-sha256", required=True)
    parser.add_argument("--start", action="store_true", help="start exactly this fresh local fixture once")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.start:
            start(args.root.absolute(), args.receipt_sha256)
        else:
            receipt, _ = load(args.root.absolute(), args.receipt_sha256)
            print(json.dumps({"project": receipt["project"], "outcome": "PREVIEW", "mutation": False}))
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(f"BLOCKED: {type(error).__name__}; retain fixture and all start receipts, no automatic retry", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
