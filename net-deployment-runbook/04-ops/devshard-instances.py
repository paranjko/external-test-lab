#!/usr/bin/env python3
"""Render independent gateway Compose scopes without copying secrets or state."""

import argparse
import copy
import importlib.util
import ipaddress
import json
import os
import re
import stat
import sys
from pathlib import Path
from urllib.parse import urlsplit


SPEC = importlib.util.spec_from_file_location("preview", Path(__file__).resolve().parents[1] / "scripts/devshard-preview.py")
preview = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preview)
require = preview.require
IMAGE = "ghcr.io/gonka-ai/devshard-gateway@sha256:735240e2f8dfa77c27caf72d4442019c31b33546e047c92ff34bd8286857e4e2"
SECRET_NAMES = {"DEVSHARD_PRIVATE_KEY", "DEVSHARD_ADMIN_API_KEY", "DEVSHARD_API_KEYS"}
# The controlled DevNet stand must not self-throttle its official A/B
# gateways.  This is intentionally finite for the upstream integer contract,
# but exceeds every planned laboratory campaign by orders of magnitude.
TEST_STAND_PARTICIPANT_BUDGET = 1_000_000_000
# This pinned official gateway restores its default cache for nonpositive caps
# Every cached response costs at least 256 bytes, so cap1 evicts it immediately
# Stand requests must exercise inference and escrow counters, not cached replies
TEST_STAND_CACHE_MAX_BYTES = "1"
CHAT_CACHE_KEY = "DEVSHARD_CHAT_CACHE_MAX_BYTES"
ENV = {
    "DEVSHARD_PORT": "8080", "DEVSHARDS_JSON": "[]",
    "DEVSHARD_CHAIN_ID": "gonka-devnet-community", "DEVSHARD_CHAIN_RPC": "http://node:26657/",
    "DEVSHARD_CHAIN_GRPC": "none", "DEVSHARD_PUBLIC_API": "http://api:9000",
    "DEVSHARD_MODEL": "Qwen/Qwen3-0.6B", "DEVSHARD_ROUTE_PREFIX": "/devshard/v5",
    "DEVSHARD_STORAGE_DIR": "/root/.devshardctl", "DEVSHARD_TX_GAS_LIMIT": "700000",
    "DEVSHARD_CAPACITY_AWARE_LIMITS": "on", "DEVSHARD_POC_REQUEST_MODE": "relaxed",
    "DEVSHARD_ALLOW_PRIVATE_ADDRESSES": "true", "DEVSHARD_STATS_ENABLED": "true",
    "DEVSHARD_STATS_PORT": "9091", "DEVSHARD_ESCROW_ROTATION_ENABLED": "false",
    "DEVSHARD_ESCROW_ROTATION_SETTLEMENT_ENABLED": "false",
}


def private_file(path):
    path = Path(path).absolute()
    require(not path.is_symlink() and path.is_file(), "secret file must be a regular non-symlink file")
    require(stat.S_IMODE(path.stat().st_mode) == 0o600, "secret file requires mode 0600")
    require(stat.S_IMODE(path.parent.stat().st_mode) == 0o700, "secret directory requires mode 0700")
    require(path.stat().st_uid == os.getuid(), "secret file must belong to the current operator")
    require(not any(char in str(path) for char in "$\n\r"), "unsafe secret path")
    return path


def secrets(path):
    values = {}
    for line in private_file(path).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        require(separator and key in SECRET_NAMES and key not in values, "unexpected or duplicate secret binding")
        require(re.fullmatch(r"[A-Za-z0-9_,.:-]+", value), "secret value must be an unquoted literal token")
        values[key] = value
    require(values.keys() == SECRET_NAMES, "all three secret bindings are required")
    require(re.fullmatch("[0-9a-fA-F]{64}", values["DEVSHARD_PRIVATE_KEY"]), "creator key must be 32-byte hex")
    scalar = int(values["DEVSHARD_PRIVATE_KEY"], 16)
    require(0 < scalar < 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141,
            "invalid creator scalar")
    clients = values["DEVSHARD_API_KEYS"].split(",")
    require(all(len(key) >= 24 for key in clients) and len(set(clients)) == len(clients),
            "client keys must be distinct tokens of at least 24 characters")
    require(len(values["DEVSHARD_ADMIN_API_KEY"]) >= 24, "admin key must have at least 24 characters")
    all_values = [values["DEVSHARD_PRIVATE_KEY"].lower(), values["DEVSHARD_ADMIN_API_KEY"]] + clients
    require(len(set(all_values)) == len(all_values), "creator, admin and client keys must differ")
    return all_values


def port(binding, container_port):
    require(isinstance(binding, str), "port binding missing")
    match = re.fullmatch(r"127\.0\.0\.1:([1-9][0-9]{0,4}):" + str(container_port), binding)
    require(match and 1024 <= int(match[1]) <= 65535, "listeners must use nonprivileged loopback ports")
    return int(match[1])


def name(value):
    require(isinstance(value, str) and re.fullmatch(r"[a-z0-9][a-z0-9_-]{2,62}", value),
            "invalid instance resource name")
    return value


def upstream(value):
    require(isinstance(value, str), "private upstream missing")
    parsed = urlsplit(value)
    require(parsed.scheme == "http" and parsed.hostname and not parsed.username and
            not parsed.password and not parsed.query and not parsed.fragment and parsed.path in ("", "/"),
            "invalid private upstream")
    host = parsed.hostname
    try:
        private = ipaddress.ip_address(host).is_private
    except ValueError:
        private = bool(re.fullmatch(r"[a-z][a-z0-9-]*", host))
    require(private and host not in ("localhost",), "upstreams must use a private bridge address")


def render(design, secret_paths):
    require(design.get("gateway_image") == IMAGE and design.get("platform") == "linux/amd64",
            "gateway must use the pinned official linux/amd64 digest")
    common = design.get("gateway_common_env")
    require(isinstance(common, dict) and set(common) in (set(ENV), set(ENV) | {CHAT_CACHE_KEY}),
            "environment shape differs from qualified contract")
    require(common.get(CHAT_CACHE_KEY, TEST_STAND_CACHE_MAX_BYTES) == TEST_STAND_CACHE_MAX_BYTES,
            "stand cache policy must retain fresh inference")
    for key, value in ENV.items():
        if key in ("DEVSHARD_CHAIN_RPC", "DEVSHARD_PUBLIC_API"):
            upstream(common[key])
        else:
            require(common[key] == value, f"unsupported environment setting: {key}")
    gateways = design.get("gateways")
    require(isinstance(gateways, list) and len(gateways) == 2 and
            {item.get("id") for item in gateways} == {"A", "B"}, "exactly A and B are required")
    require(set(secret_paths) == {"A", "B"}, "both private secret files required")
    seen = {key: set() for key in ("project", "volume", "directory", "creator", "port", "secret", "key")}
    result = {}
    for item in gateways:
        identity = item["id"]
        project, volume = name(item.get("project")), name(item.get("volume"))
        require(item.get("service") == "gateway", "only the gateway service is in scope")
        network = name(item.get("external_network"))
        directory = item.get("directory")
        require(isinstance(directory, str) and re.fullmatch(r"/srv/dai/broker-tests/[a-z0-9-]+", directory),
                "instance directory must be a dedicated broker-tests path")
        require(not any(key in item for key in ("database", "data_path", "existing_volume", "source_storage")),
                "inherited database or storage binding is forbidden")
        creator = preview.address(item.get("creator_address"))
        secret_path = private_file(secret_paths[identity])
        values = secrets(secret_path)
        bindings = {"project": [project], "volume": [volume], "directory": [directory],
                    "creator": [creator], "port": [port(item.get("api_bind"), 8080), port(item.get("accounting_bind"), 9091)],
                    "secret": [str(secret_path.resolve())], "key": values}
        for kind, members in bindings.items():
            for member in members:
                require(member not in seen[kind], f"duplicate A/B {kind}")
                seen[kind].add(member)
        # Compose reads literal secrets at start, never through interpolation or this output.
        environment = copy.deepcopy(common)
        environment[CHAT_CACHE_KEY] = TEST_STAND_CACHE_MAX_BYTES
        service = {"image": IMAGE, "platform": "linux/amd64", "restart": "unless-stopped",
                   "environment": environment,
                   "env_file": [{"path": str(secret_path), "format": "raw"}],
                   "volumes": ["state:/root/.devshardctl"],
                   "ports": [item["api_bind"], item["accounting_bind"]], "networks": ["host-private"],
                   "labels": {"org.gonka.test-lab.scope": "two-gateways", "org.gonka.test-lab.instance": identity}}
        result[identity] = {"name": project, "services": {"gateway": service},
                            "volumes": {"state": {"name": volume}},
                            "networks": {"host-private": {"external": True, "name": network}}}
    return result


def settings(document, model, catalog):
    require(model in catalog, "selected model is absent from the fresh model catalog")
    require(isinstance(document, dict) and isinstance(document.get("escrow_rotation"), dict),
            "complete settings response is required")
    limits = document.get("model_limits", [])
    require(isinstance(limits, list) and all(isinstance(row, dict) for row in limits), "model limits missing")
    names = [row.get("model_id") for row in limits]
    require(all(isinstance(value, str) for value in names) and len(set(names)) == len(names),
            "invalid or duplicate model limits")
    desired = copy.deepcopy(document)
    desired["default_model"] = model
    if model not in names:
        # Fresh official gateways omit model_limits. Materialize the model's
        # current global limits; a zero-filled row would change admission.
        row = {"model_id": model}
        for key in ("max_concurrent_requests", "max_input_tokens_in_flight"):
            require(type(document.get(key)) is int and document[key] >= 0, "global model defaults missing")
            row[key] = document[key]
        desired.setdefault("model_limits", []).append(row)
    next(row for row in desired["model_limits"] if row["model_id"] == model)["access_mode"] = "api_key"
    # A/B's active escrow renewal is independent operational state.  A
    # throttle/access update must never silently stop rotation or settlement.
    require(isinstance(desired.get("escrow_rotation"), dict), "escrow rotation settings missing")
    throttle = desired.get("participant_throttle")
    require(isinstance(throttle, dict), "participant throttle settings missing")
    for key in ("request_burst", "recovery_per_minute"):
        require(type(throttle.get(key)) is int and throttle[key] > 0,
                "participant throttle settings invalid")
        throttle[key] = TEST_STAND_PARTICIPANT_BUDGET
    return desired


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--design", type=Path, required=True)
    parser.add_argument("--secret-a", type=Path, required=True)
    parser.add_argument("--secret-b", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = render(preview.load(args.design), {"A": args.secret_a, "B": args.secret_b})
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, TypeError, KeyError) as error:
        # Inputs include secrets; do not include parser or OS exception payloads.
        print(f"BLOCKED: invalid instance input ({type(error).__name__}); check private inputs locally", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
