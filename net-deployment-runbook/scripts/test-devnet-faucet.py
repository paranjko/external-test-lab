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
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = pathlib.Path(__file__).resolve().parent.parent
FAUCET = ROOT / "04-ops" / "faucet" / "faucet.py"
BECH32_ALPHABET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_GENERATOR = (0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)


def polymod(values):
    checksum = 1
    for value in values:
        top = checksum >> 25
        checksum = (checksum & 0x1FFFFFF) << 5 ^ value
        for index, generator in enumerate(BECH32_GENERATOR):
            if (top >> index) & 1:
                checksum ^= generator
    return checksum


def address(seed):
    human = "gonka"
    data = [(seed + index) % 32 for index in range(32)]
    expanded = [ord(char) >> 5 for char in human] + [0] + [ord(char) & 31 for char in human]
    remainder = polymod(expanded + data + [0] * 6) ^ 1
    checksum = [(remainder >> 5 * (5 - index)) & 31 for index in range(6)]
    return human + "1" + "".join(BECH32_ALPHABET[value] for value in data + checksum)


ADDRESS_A = address(1)
ADDRESS_B = address(2)
ADDRESS_C = address(3)


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


def telegram_request(port, address, key, telegram_id=77, token="test-telegram-token"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(
        "POST",
        "/v1/telegram-claim",
        body=json.dumps({"address": address, "telegram_user_id": telegram_id}),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}", "Idempotency-Key": key},
    )
    response = connection.getresponse()
    payload = json.loads(response.read())
    connection.close()
    return response.status, payload


def telegram_admin(port, action, telegram_id=77, token="test-telegram-token"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(
        "POST", "/v1/telegram-admin",
        body=json.dumps({"telegram_user_id": telegram_id, "action": action}),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
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


class ConfirmingRpcHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_GET(self):
        if self.path.startswith("/tx?hash=0x"):
            body = json.dumps({"result": {"tx_result": {"code": 0}}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


with tempfile.TemporaryDirectory() as temporary:
    temp = pathlib.Path(temporary)
    bin_dir = temp / "bin"
    bin_dir.mkdir()
    fake_inferenced = bin_dir / "inferenced"
    fake_inferenced.write_text(
        "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >>\"$FAUCET_TEST_COMMAND_LOG\"\nprintf '%s\\n' '{\"txhash\":\""
        + "A" * 64
        + "\"}'\n"
    )
    fake_inferenced.chmod(0o755)
    rpc_port = reserve_port()
    rpc = ThreadingHTTPServer(("127.0.0.1", rpc_port), ConfirmingRpcHandler)
    rpc_thread = threading.Thread(target=rpc.serve_forever, daemon=True)
    rpc_thread.start()
    port = reserve_port()
    environment = os.environ | {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "FAUCET_CHAIN_ID": "gonka-devnet-community",
        "FAUCET_GENESIS_SHA256": "a" * 64,
        "FAUCET_RPC_URL": f"http://127.0.0.1:{rpc_port}",
        "FAUCET_KEYRING_PASSWORD": "test-password",
        "FAUCET_AMOUNT_NGONKA": "100",
        "FAUCET_GAS_PRICES": "1ngonka",
        "FAUCET_STATE_DB": str(temp / "faucet.sqlite3"),
        "FAUCET_LISTEN_HOST": "127.0.0.1",
        "FAUCET_LISTEN_PORT": str(port),
        "FAUCET_MAX_CLAIMS_PER_IP": "1",
        "FAUCET_TELEGRAM_TOKEN": "test-telegram-token",
        "FAUCET_INITIAL_ADMINS_JSON": "[77]",
        "FAUCET_TELEGRAM_MAX_CLAIMS_PER_USER": "1",
        "FAUCET_TEST_COMMAND_LOG": str(temp / "inferenced-commands.log"),
    }
    process = subprocess.Popen(["python3", str(FAUCET)], env=environment)
    try:
        wait_ready(port)

        status, payload = health(port)
        assert status == 200 and payload == {"status": "ok", "signer_cli": "ready"}, (status, payload)
        status, payload = request(port, ADDRESS_A)
        assert status == 200 and payload == {"address": ADDRESS_A, "amount_ngonka": "100", "txhash": "A" * 64, "state": "confirmed"}, (status, payload)
        assert "--broadcast-mode sync" in (temp / "inferenced-commands.log").read_text()
        assert "--gas-prices 1ngonka" in (temp / "inferenced-commands.log").read_text()
        status, payload = request(port, ADDRESS_A)
        assert status == 200 and payload["state"] == "confirmed", (status, payload)
        with sqlite3.connect(environment["FAUCET_STATE_DB"]) as db:
            db.execute(
                "INSERT INTO claims(address, ip, created_at, txhash, state) VALUES (?, ?, ?, ?, ?)",
                (ADDRESS_C, "203.0.113.4", int(time.time()), "B" * 64, "submitted"),
            )
        status, payload = request(port, ADDRESS_C, "203.0.113.4")
        assert status == 409 and payload == {
            "error": "the earlier faucet claim needs operator recovery",
            "txhash": "B" * 64,
            "state": "submitted",
        }, (status, payload)
        status, _ = request(port, ADDRESS_B)
        assert status == 429, status
        status, _ = request(port, "not-a-gonka-address", "203.0.113.4")
        assert status == 400, status
        key_a = "a" * 64
        status, payload = telegram_request(port, ADDRESS_A, key_a)
        assert status == 403 and payload["error"] == "telegram faucet is closed", (status, payload)
        status, payload = telegram_admin(port, "open", telegram_id=78)
        assert status == 403 and payload["error"] == "telegram user is not a faucet administrator", (status, payload)
        status, payload = telegram_admin(port, "open")
        assert status == 200 and payload == {"state": "open", "admin": True}, (status, payload)
        status, payload = telegram_request(port, ADDRESS_A, key_a)
        assert status == 202 and payload["state"] == "submitted" and payload["confirmation"] == "unavailable", (status, payload)
        status, duplicate = telegram_request(port, ADDRESS_A, key_a)
        assert status == 202 and duplicate == payload, (status, duplicate, payload)
        status, _ = telegram_request(port, ADDRESS_A, "b" * 64)
        assert status == 429, status
        status, payload = telegram_admin(port, "close")
        assert status == 200 and payload == {"state": "closed", "admin": True}, (status, payload)
        status, payload = telegram_request(port, ADDRESS_B, "d" * 64)
        assert status == 403 and payload["error"] == "telegram faucet is closed", (status, payload)
        status, _ = telegram_request(port, ADDRESS_B, "c" * 64, token="wrong")
        assert status == 403, status
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

    # Missing or older schema markers do not authorize deleting claims from
    # the same Genesis lineage, including unresolved transaction intents.
    with sqlite3.connect(environment["FAUCET_STATE_DB"]) as db:
        db.execute("DELETE FROM metadata WHERE key = 'claims_lineage_version'")
    port = reserve_port()
    environment["FAUCET_LISTEN_PORT"] = str(port)
    process = subprocess.Popen(["python3", str(FAUCET)], env=environment)
    try:
        wait_ready(port)
        status, payload = request(port, ADDRESS_B)
        assert status == 429, (status, payload)
        with sqlite3.connect(environment["FAUCET_STATE_DB"]) as db:
            assert db.execute("SELECT state FROM claims WHERE address = ?", (ADDRESS_C,)).fetchone() == ("submitted",)
            assert db.execute("SELECT count(*) FROM telegram_claims").fetchone()[0] == 1
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
        assert status == 200 and payload["state"] == "confirmed", (status, payload)
    finally:
        process.terminate()
        process.wait(timeout=5)

    rpc.shutdown()
    rpc_thread.join(timeout=5)

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
    assert module.safe_transaction_error(RuntimeError("insufficient fee: hidden detail")) == (
        "faucet fee configuration is below the chain minimum"
    )
    assert module.safe_transaction_error(RuntimeError("account sequence mismatch, expected 4")) == (
        "gateway reserve signer sequence conflict"
    )
    assert module.safe_transaction_error(RuntimeError("too many failed passphrase attempts")) == (
        "faucet signer credential is unavailable"
    )
    assert module.safe_transaction_error(RuntimeError("unknown flag: --broadcast-mode")) == (
        "faucet signer CLI is incompatible with the network"
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
