#!/usr/bin/env python3
"""Reconcile only the independent B read-only readiness service."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen

SCOPE = Path("srv/dai/broker-tests/ds502-b/public-status")
UNIT = Path("etc/systemd/system/gdc-ds502-b-admission.service")
NAME = UNIT.name


def digest(value):
    return hashlib.sha256(value).hexdigest()


def read_env(path):
    if path.is_symlink():
        raise ValueError("readiness credential file must not be a symlink")
    result = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values = shlex.split(value)
        if len(values) != 1 or key in result:
            raise ValueError("readiness credential file contains invalid fields")
        result[key] = values[0]
    return result


def desired_files(root, source, port, native_port, model, binary, sha256):
    if port in {18083, 18084, 18100, native_port} or not 1024 <= port <= 65535:
        raise ValueError("B readiness port conflicts with a retained service")
    if not 1024 <= native_port <= 65535 or not model or "\n" in model:
        raise ValueError("B native model/port is invalid")
    if not re.fullmatch(r"https://[^\s]+", binary) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise ValueError("B release contract is invalid")
    secrets = read_env(root / "srv/dai/broker-tests/ds502-b/gateway.env")
    admin = secrets["DEVSHARD_ADMIN_API_KEY"]
    raw_keys = secrets["DEVSHARD_API_KEYS"]
    keys = json.loads(raw_keys) if raw_keys.startswith("[") else raw_keys.split(",")
    if not isinstance(keys, list) or not keys or not all(
            isinstance(key, str) and re.fullmatch(r"devnet_[A-Za-z0-9._:-]+", key) for key in keys):
        raise ValueError("B readiness requires the native B client keys")
    if not re.fullmatch(r"[A-Za-z0-9._:-]+", admin) or admin in keys:
        raise ValueError("B readiness admin credential is invalid")
    values = {
        "GDC_GATEWAY_ADMISSION_HOST": "127.0.0.1",
        "GDC_GATEWAY_ADMISSION_PORT": str(port),
        "GDC_GATEWAY_ADMISSION_UPSTREAM": "http://127.0.0.1:%s" % native_port,
        "GDC_GATEWAY_ADMISSION_STATUS_URL": "http://127.0.0.1:%s/v1/admin/devshards" % native_port,
        "GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN": admin,
        "GDC_GATEWAY_ADMISSION_SELECTED_VERSION": "v5",
        "GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON": json.dumps({"v5": {"binary": binary, "sha256": sha256}}, separators=(",", ":")),
        "GDC_GATEWAY_ADMISSION_EPOCH_URL": "http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data",
        "GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL": "http://127.0.0.1:26657/status",
        "GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL": "http://127.0.0.1:1317/productscience/inference/inference/params",
        "GDC_GATEWAY_READINESS_ONLY": "true",
        "GDC_GATEWAY_READINESS_ID": "B",
        "GDC_GATEWAY_READINESS_MODEL": model,
        "GDC_GATEWAY_READINESS_TOKENS_JSON": json.dumps(keys, separators=(",", ":")),
    }
    environment = "".join('%s=%s\n' % (key, json.dumps(value)) for key, value in sorted(values.items())).encode()
    unit = ("[Unit]\nDescription=GDC independent B read-only readiness\nAfter=network-online.target\n"
            "[Service]\nType=simple\nEnvironmentFile=/%s/admission.env\n"
            "ExecStart=/usr/bin/python3 /%s/gateway-admission-proxy.py\n"
            "Restart=always\nRestartSec=2\nNoNewPrivileges=true\nPrivateTmp=true\n"
            "ProtectHome=true\nProtectSystem=strict\n[Install]\nWantedBy=multi-user.target\n" % (SCOPE, SCOPE)).encode()
    return {SCOPE / "admission.env": (environment, 0o600),
            SCOPE / "gateway-admission-proxy.py": (source.read_bytes(), 0o644),
            UNIT: (unit, 0o644)}


def current_state(root, files):
    result = {}
    for relative in files:
        path = root / relative
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
            raise ValueError("managed B readiness target must not be a symlink")
        result[str(relative)] = {"sha256": digest(path.read_bytes()), "mode": path.stat().st_mode & 0o777} if path.exists() else None
    return result


def listener_owned(pid, port, proc=Path("/proc")):
    """Match Linux listener inodes to the managed unit PID without extra tools."""
    inodes = set()
    for name in ("tcp", "tcp6"):
        for line in (proc / "net" / name).read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == "0A" and int(fields[1].rsplit(":", 1)[1], 16) == port:
                inodes.add(fields[9])
    owned = set()
    for descriptor in (proc / pid / "fd").iterdir():
        target = str(descriptor.readlink())
        if target.startswith("socket:["):
            owned.add(target[8:-1])
    return bool(inodes) and inodes <= owned


def reconcile(root, files, apply=False, expected=None, systemctl="systemctl"):
    current = current_state(root, files)
    desired = {str(path): {"sha256": digest(content), "mode": mode} for path, (content, mode) in files.items()}
    before = digest(json.dumps(current, sort_keys=True).encode())
    delta = [path for path in desired if current[path] != desired[path]]
    receipt = {"schema": "gdc-gateway-readiness/1", "gateway": "B", "before_sha256": before,
               "desired_sha256": digest(json.dumps(desired, sort_keys=True).encode()), "delta": delta, "applied": False}
    if not apply:
        return receipt
    if expected != before:
        raise ValueError("B readiness state changed after preview")
    if not delta:
        receipt["outcome"] = "no-change"
        return receipt
    backup = root / SCOPE / ("retained-" + before)
    if backup.is_symlink():
        raise ValueError("managed B readiness backup must not be a symlink")
    backup.mkdir(parents=True, mode=0o700, exist_ok=True)
    for relative, (content, mode) in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            retained = backup / path.name
            if retained.is_symlink():
                raise ValueError("managed B readiness preimage must not be a symlink")
            if not retained.exists():
                retained.write_bytes(path.read_bytes())
                retained.chmod(0o600)
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
            output.write(content)
            temporary = Path(output.name)
        temporary.chmod(mode)
        temporary.replace(path)
    subprocess.run([systemctl, "daemon-reload"], check=True)
    subprocess.run([systemctl, "enable", "--now", NAME], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([systemctl, "restart", NAME], check=True)
    subprocess.run([systemctl, "is-active", "--quiet", NAME], check=True)
    if current_state(root, files) != desired:
        raise ValueError("B readiness installed file readback differs")
    receipt.update(applied=True, outcome="PASS")
    return receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--native-port", type=int, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()
    # Only this already-inventoried B service may own the planned listener.
    with socket.socket() as probe:
        occupied = probe.connect_ex(("127.0.0.1", args.port)) == 0
    if occupied:
        pid = subprocess.check_output(["systemctl", "show", NAME, "-p", "MainPID", "--value"], text=True).strip()
        if not pid.isdigit() or pid == "0" or not listener_owned(pid, args.port):
            raise ValueError("B readiness listener belongs to another service")
    files = desired_files(Path("/"), args.source, args.port, args.native_port, args.model, args.binary, args.sha256)
    receipt = reconcile(Path("/"), files, args.apply, args.expected_sha256)
    if args.apply:
        environment = read_env(Path("/") / SCOPE / "admission.env")
        token = json.loads(environment["GDC_GATEWAY_READINESS_TOKENS_JSON"])[0]
        request = Request("http://127.0.0.1:%s/v1/admission-status" % args.port,
                          headers={"Authorization": "Bearer " + token})
        deadline = time.monotonic() + 30
        while True:
            try:
                with urlopen(request, timeout=6) as response:
                    payload = json.load(response)
                if payload.get("gateway") != "B" or payload.get("model") != args.model or payload.get("protocol") != "v5":
                    raise ValueError("B readiness runtime readback differs")
                receipt["runtime_state"] = payload["state"]
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise ValueError("B readiness runtime readback unavailable")
                time.sleep(0.25)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        raise SystemExit("B readiness reconciliation failed; inspect private configuration and service ownership")
