#!/usr/bin/env python3
"""Render a private, frozen-v6 admission environment without deploying services."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("v6_artifacts", Path(__file__).with_name("devshard-artifacts.py"))
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


def endpoint(value):
    if not isinstance(value, str) or any(char.isspace() for char in value):
        raise ValueError("invalid endpoint")
    parsed = urlsplit(value)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or (parsed.scheme == "http" and parsed.hostname not in {"127.0.0.1", "::1"})):
        raise ValueError("endpoint requires HTTPS or loopback HTTP without credentials")
    return value.rstrip("/")


def render(config, token, definition=None):
    definition = artifacts.load_definition() if definition is None else artifacts.load_definition(definition)
    expected = {"upstream", "observer", "chain_api", "chain_rpc", "approved_versions", "port"}
    if set(config) != expected:
        raise ValueError("unexpected admission binding fields")
    port = config["port"]
    if type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError("invalid private admission port")
    if not re.fullmatch(r"[A-Za-z0-9._:-]{16,256}", token):
        raise ValueError("invalid observer credential")
    urls = {key: endpoint(config[key]) for key in expected - {"port"}}
    upstream = urlsplit(urls["upstream"])
    if upstream.hostname in {"127.0.0.1", "::1"} and (upstream.port or 80) == port:
        raise ValueError("admission upstream loops to itself")
    archive = definition["devshard_zip"]
    api = urls["chain_api"] + "/productscience/inference/inference/"
    values = {
        "GDC_GATEWAY_ADMISSION_HOST": "127.0.0.1",
        "GDC_GATEWAY_ADMISSION_PORT": str(port),
        "GDC_GATEWAY_ADMISSION_UPSTREAM": urls["upstream"],
        "GDC_GATEWAY_ADMISSION_STATUS_URL": urls["observer"],
        "GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN": token,
        "GDC_GATEWAY_ADMISSION_SELECTED_VERSION": "v6",
        "GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON": json.dumps(
            {"v6": {"binary": archive["url"], "sha256": archive["sha256"]}}, separators=(",", ":")),
        "GDC_GATEWAY_ADMISSION_EPOCH_URL": api + "current_epoch_group_data",
        "GDC_GATEWAY_ADMISSION_EPOCH_INFO_URL": api + "epoch_info",
        "GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL": api + "params",
        "GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL": urls["chain_rpc"] + "/status",
        "GDC_GATEWAY_ADMISSION_APPROVED_VERSIONS_URL": urls["approved_versions"],
    }
    return "".join(f"{key}={value}\n" for key, value in sorted(values.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binding", type=Path, required=True)
    parser.add_argument("--observer-token-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fd = os.open(args.observer_token_file, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 257:
            raise ValueError("observer credential must be a private regular file")
        token = source.read(257).strip()
    payload = render(json.loads(args.binding.read_text()), token).encode()
    # Never overwrite an existing secret or follow an output symlink.
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(payload)
    print(json.dumps({"schema": "gdc-v6-admission-render/1", "protocol": "v6",
                      "sha256": hashlib.sha256(payload).hexdigest(), "deployed": False}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, TypeError):
        raise SystemExit("v6 admission rendering refused; inspect private binding and credential permissions")
