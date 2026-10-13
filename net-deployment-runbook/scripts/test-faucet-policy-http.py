#!/usr/bin/env python3
"""Real localhost policy/admin restart contract with an isolated synthetic signer."""

import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


SOURCE = Path(__file__).resolve().parents[1] / "04-ops/faucet/faucet.py"
ADDRESS_A = "gonka1mrm3xar9w858cd0dk697v9fdzuleey9a3lx2kl"
ALPHABET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def address_b():
    data = list(range(32))
    values = [ord(char) >> 5 for char in "gonka"] + [0] + [ord(char) & 31 for char in "gonka"]
    remainder = 1
    for value in values + data + [0] * 6:
        top = remainder >> 25
        remainder = (remainder & 0x1ffffff) << 5 ^ value
        for index, generator in enumerate((0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)):
            if top >> index & 1:
                remainder ^= generator
    remainder ^= 1
    checksum = [(remainder >> (5 * (5 - index))) & 31 for index in range(6)]
    return "gonka1" + "".join(ALPHABET[value] for value in data + checksum)


def request(port, route, payload, key=None, token="fixture-token"):
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {token}"}
    if key:
        headers["Idempotency-Key"] = key
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request("POST", "/v1/telegram-" + route, json.dumps(payload), headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()


def admin(port, action, actor=77, **values):
    return request(port, "admin", {"action": action, "telegram_user_id": actor, **values})


def claim(port, key, actor=44, address=ADDRESS_A):
    return request(port, "claim", {"address": address, "telegram_user_id": actor}, key * 64)


def start(environment):
    with socket.socket() as socket_probe:
        socket_probe.bind(("127.0.0.1", 0))
        port = socket_probe.getsockname()[1]
    process = subprocess.Popen(["python3", str(SOURCE)], env=environment | {"FAUCET_LISTEN_PORT": str(port)}, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("isolated faucet startup failed")
        try:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.2)
            connection.request("GET", "/health")
            response = connection.getresponse()
            ready = response.status == 200
            response.read()
            connection.close()
            if ready:
                return process, port
        except OSError:
            pass
        time.sleep(0.05)
    process.terminate()
    process.wait(5)
    raise RuntimeError("isolated faucet readiness timed out")


def stop(process):
    process.terminate()
    process.wait(5)
    process.stderr.close()


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        signer = root / "inferenced"
        signer.write_text("#!/usr/bin/env python3\nimport json, os, sys\nfrom pathlib import Path\n"
                          "if sys.argv[1:2] == ['version']:\n print('fixture'); sys.exit(0)\n"
                          "with open(os.environ['FIXTURE_CALLS'], 'a') as calls: calls.write('send\\n')\n"
                          "if Path(os.environ['FIXTURE_FAIL']).exists():\n print('private signer detail', file=sys.stderr); sys.exit(1)\n"
                          "print(json.dumps({'txhash':'A'*64}))\n")
        signer.chmod(0o755)
        calls, fail = root / "calls", root / "fail"
        environment = os.environ | {
            "PATH": f"{root}:{os.environ['PATH']}", "FAUCET_CHAIN_ID": "policy-http-fixture",
            "FAUCET_GENESIS_SHA256": "a" * 64, "FAUCET_RPC_URL": "http://127.0.0.1:1",
            "FAUCET_CHAIN_REST_URL": "", "FAUCET_KEYRING_PASSWORD": "fixture",
            "FAUCET_STATE_DB": str(root / "state.sqlite3"), "FAUCET_LISTEN_HOST": "127.0.0.1",
            "FAUCET_INITIAL_ADMINS_JSON": "[77]", "FAUCET_TELEGRAM_TOKEN": "fixture-token",
            "FAUCET_TELEGRAM_MAX_CLAIMS_PER_USER": "100", "FAUCET_AMOUNT_NGONKA": "60000000000",
            "FIXTURE_CALLS": str(calls), "FIXTURE_FAIL": str(fail),
        }
        process, port = start(environment)
        try:
            status, policy = admin(port, "list")
            assert status == 200 and policy["limit_ngonka"] == "100000000000" and policy["state"] == "closed"
            assert claim(port, "a")[0] == 403
            assert admin(port, "open", actor=999)[0] == 403
            assert admin(port, "limit", limit_ngonka=60000000000)[0] == 200
            assert admin(port, "open")[0] == 200
            status, original = claim(port, "a")
            assert status == 202 and original["amount_ngonka"] == "60000000000"
            assert claim(port, "b", address=address_b())[0] == 429
            assert claim(port, "a", actor=45)[0] == 409
            assert admin(port, "add", administrator_id=88)[1]["administrator_ids"] == [77, 88]
            assert admin(port, "remove", actor=88, administrator_id=77)[0] == 200
            assert admin(port, "remove", actor=88, administrator_id=88)[0] == 409
            assert admin(port, "close", actor=88)[0] == 200
            assert claim(port, "a") == (202, original)
            assert calls.read_text().splitlines() == ["send"]
        finally:
            stop(process)
        environment["FAUCET_AMOUNT_NGONKA"] = "40000000000"
        process, port = start(environment)
        try:
            assert admin(port, "list")[0] == 403  # bootstrap must not resurrect removed ID
            status, policy = admin(port, "list", actor=88)
            assert status == 200 and policy["state"] == "closed" and policy["administrator_ids"] == [88]
            assert admin(port, "open", actor=88)[0] == 200
            assert claim(port, "a") == (202, original)  # original amount, not new environment
            assert admin(port, "limit", actor=88, limit_ngonka=100000000000)[0] == 200
            assert claim(port, "b", address=address_b())[0] == 202
            assert claim(port, "c")[0] == 429
            assert claim(port, "d", actor=45)[0] == 202  # independent user allowance
            assert admin(port, "limit", actor=88, limit_ngonka=200000000000)[0] == 200
            fail.touch()
            status, uncertain = claim(port, "e")
            assert status == 503 and uncertain["state"] == "uncertain" and "private" not in json.dumps(uncertain)
            assert claim(port, "e") == (status, uncertain)
            assert len(calls.read_text().splitlines()) == 4
            assert admin(port, "close", actor=88)[0] == 200
        finally:
            stop(process)
        process, port = start(environment)
        try:
            status, policy = admin(port, "list", actor=88)
            assert status == 200 and policy["state"] == "closed" and policy["limit_ngonka"] == "200000000000"
            assert claim(port, "e")[1]["state"] == "uncertain"
            assert len(calls.read_text().splitlines()) == 4
        finally:
            stop(process)
    print("PASS isolated faucet HTTP admin, integer quota, durable intent and two restarts")


if __name__ == "__main__":
    main()
