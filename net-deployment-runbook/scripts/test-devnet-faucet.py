#!/usr/bin/env python3
"""Black-box contract test for the bounded DevNet faucet HTTP service."""

import http.client
import importlib.util
import json
import os
import pathlib
import socket
import sqlite3
import subprocess
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parent.parent
FAUCET = ROOT / "04-ops" / "faucet" / "faucet.py"
ADDRESS_A = "gonka1" + "a" * 38
ADDRESS_B = "gonka1" + "b" * 38


def reserve_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request(port, address, forwarded_for="198.51.100.7"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(
        "POST",
        "/v1/claim",
        body=json.dumps({"address": address}),
        headers={"Content-Type": "application/json", "X-Forwarded-For": forwarded_for},
    )
    response = connection.getresponse()
    payload = json.loads(response.read())
    connection.close()
    return response.status, payload


def health(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request("GET", "/health")
    response = connection.getresponse()
    payload = json.loads(response.read())
    connection.close()
    return response.status, payload


def wait_ready(port):
    deadline = time.monotonic() + 5
    while True:
        try:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.2)
            connection.connect()
            connection.close()
            return
        except OSError:
            if time.monotonic() >= deadline:
                raise RuntimeError("faucet did not start")
            time.sleep(0.05)


with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    bin_dir = temp / "bin"
    bin_dir.mkdir()
    fake_inferenced = bin_dir / "inferenced"
    fake_inferenced.write_text(
        "#!/usr/bin/env bash\nprintf '%s\\n' '{\"txhash\":\""
        + "A" * 64
        + "\"}'\n"
    )
    fake_inferenced.chmod(0o755)
    port = reserve_port()
    environment = os.environ | {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "FAUCET_CHAIN_ID": "gonka-devnet-community",
        "FAUCET_GENESIS_SHA256": "a" * 64,
        "FAUCET_RPC_URL": "http://127.0.0.1:26657",
        "FAUCET_KEYRING_PASSWORD": "test-password",
        "FAUCET_AMOUNT_NGONKA": "100",
        "FAUCET_STATE_DB": str(temp / "faucet.sqlite3"),
        "FAUCET_LISTEN_HOST": "127.0.0.1",
        "FAUCET_LISTEN_PORT": str(port),
        "FAUCET_MAX_CLAIMS_PER_IP": "1",
    }
    process = subprocess.Popen(["python3", str(FAUCET)], env=environment)
    try:
        wait_ready(port)

        status, payload = health(port)
        assert status == 200 and payload == {"status": "ok", "signer_cli": "ready"}, (status, payload)
        status, payload = request(port, ADDRESS_A)
        assert status == 202 and payload["txhash"] == "A" * 64, (status, payload)
        status, _ = request(port, ADDRESS_A)
        assert status == 409, status
        status, _ = request(port, ADDRESS_B)
        assert status == 429, status
        status, _ = request(port, "not-a-gonka-address", "203.0.113.4")
        assert status == 400, status
    finally:
        process.terminate()
        process.wait(timeout=5)

    # Rate limits persist across ordinary service restarts within one lineage.
    port = reserve_port()
    environment["FAUCET_LISTEN_PORT"] = str(port)
    process = subprocess.Popen(["python3", str(FAUCET)], env=environment)
    try:
        wait_ready(port)
        status, _ = request(port, ADDRESS_B)
        assert status == 429, status
    finally:
        process.terminate()
        process.wait(timeout=5)

    # A pre-lineage database has no migration marker. Its claims must be
    # cleared once even if the current Genesis hash was already recorded by a
    # partially deployed older implementation.
    with sqlite3.connect(environment["FAUCET_STATE_DB"]) as db:
        db.execute("DELETE FROM metadata WHERE key = 'claims_lineage_version'")
    port = reserve_port()
    environment["FAUCET_LISTEN_PORT"] = str(port)
    process = subprocess.Popen(["python3", str(FAUCET)], env=environment)
    try:
        wait_ready(port)
        status, payload = request(port, ADDRESS_B)
        assert status == 202 and payload["txhash"] == "A" * 64, (status, payload)
    finally:
        process.terminate()
        process.wait(timeout=5)

    # A reproducible network reset changes Genesis and starts a fresh ledger.
    port = reserve_port()
    environment["FAUCET_LISTEN_PORT"] = str(port)
    environment["FAUCET_GENESIS_SHA256"] = "b" * 64
    process = subprocess.Popen(["python3", str(FAUCET)], env=environment)
    try:
        wait_ready(port)
        status, payload = request(port, ADDRESS_A)
        assert status == 202 and payload["txhash"] == "A" * 64, (status, payload)
    finally:
        process.terminate()
        process.wait(timeout=5)

required_import_environment = {
    "FAUCET_CHAIN_ID": "gonka-devnet-community",
    "FAUCET_GENESIS_SHA256": "a" * 64,
    "FAUCET_RPC_URL": "http://127.0.0.1:26657",
    "FAUCET_KEYRING_PASSWORD": "test-password",
    "FAUCET_AMOUNT_NGONKA": "100",
}
original_environment = {key: os.environ.get(key) for key in required_import_environment}
os.environ.update(required_import_environment)
try:
    specification = importlib.util.spec_from_file_location("gdc_faucet_contract", FAUCET)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    assert module.safe_transaction_error(RuntimeError("insufficient funds: hidden detail")) == (
        "gateway reserve funding account has insufficient funds"
    )
    assert module.safe_transaction_error(RuntimeError("account sequence mismatch, expected 4")) == (
        "gateway reserve signer sequence conflict"
    )
    assert module.safe_transaction_error(RuntimeError("private implementation detail")) == (
        "gateway reserve transaction was not accepted"
    )
finally:
    for key, value in original_environment.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

print("PASS DevNet faucet contract")
