#!/usr/bin/env python3
"""Bounded DevNet funding endpoint for independently operated Hosts."""

import ipaddress
import json
import os
import re
import sqlite3
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADDRESS = re.compile(r"^gonka1[0-9a-z]{20,90}$")
CHAIN_ID = os.environ["FAUCET_CHAIN_ID"]
GENESIS_SHA256 = os.environ["FAUCET_GENESIS_SHA256"]
RPC_URL = os.environ["FAUCET_RPC_URL"]
KEY_NAME = os.environ.get("FAUCET_KEY_NAME", "gdc-faucet-cold")
PASSWORD = os.environ["FAUCET_KEYRING_PASSWORD"]
AMOUNT = os.environ["FAUCET_AMOUNT_NGONKA"]
STATE_DB = os.environ.get("FAUCET_STATE_DB", "/data/faucet.sqlite3")
WINDOW_SECONDS = int(os.environ.get("FAUCET_WINDOW_SECONDS", "86400"))
MAX_CLAIMS_PER_IP = int(os.environ.get("FAUCET_MAX_CLAIMS_PER_IP", "3"))
LISTEN_HOST = os.environ.get("FAUCET_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("FAUCET_LISTEN_PORT", "18081"))
LOCK = threading.Lock()
CLAIMS_LINEAGE_VERSION = "1"


def database():
    db = sqlite3.connect(STATE_DB)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS claims (address TEXT PRIMARY KEY, ip TEXT NOT NULL, created_at INTEGER NOT NULL, txhash TEXT, state TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    recorded = db.execute("SELECT value FROM metadata WHERE key = 'genesis_sha256'").fetchone()
    lineage_version = db.execute("SELECT value FROM metadata WHERE key = 'claims_lineage_version'").fetchone()
    if lineage_version is None or lineage_version[0] != CLAIMS_LINEAGE_VERSION:
        # Databases created before claims were scoped to a Genesis lineage may
        # contain valid-looking limits that belong to an already reset chain.
        # Clear that legacy state exactly once when adopting this schema.
        db.execute("DELETE FROM claims")
        db.execute(
            "INSERT INTO metadata(key, value) VALUES ('genesis_sha256', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (GENESIS_SHA256,),
        )
        db.execute(
            "INSERT INTO metadata(key, value) VALUES ('claims_lineage_version', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (CLAIMS_LINEAGE_VERSION,),
        )
    elif recorded is None:
        db.execute("INSERT INTO metadata(key, value) VALUES ('genesis_sha256', ?)", (GENESIS_SHA256,))
    elif recorded[0] != GENESIS_SHA256:
        # Faucet limits protect one network lineage. A reproducible chain reset
        # creates a new lineage, so claims from the previous Genesis must not
        # prevent the same cleanroom operator from exercising Host join again.
        db.execute("DELETE FROM claims")
        db.execute("UPDATE metadata SET value = ? WHERE key = 'genesis_sha256'", (GENESIS_SHA256,))
    db.commit()
    return db


def request_ip(handler):
    candidate = handler.headers.get("X-Forwarded-For", "").split(",", 1)[0].strip() or handler.client_address[0]
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        return "invalid"


def submit(address, amount=AMOUNT):
    env = os.environ.copy()
    env["HOME"] = "/home/faucet"
    result = subprocess.run(
        ["inferenced", "tx", "bank", "send", KEY_NAME, address, f"{amount}ngonka", "--from", KEY_NAME,
         "--keyring-backend", "file", "--chain-id", CHAIN_ID, "--node", RPC_URL, "--gas", "auto",
         "--gas-adjustment", "1.5", "--gas-prices", "0ngonka", "--broadcast-mode", "sync", "--output", "json", "--yes"],
        input=f"{PASSWORD}\n", text=True, capture_output=True, env=env, timeout=45, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "inferenced transaction failed")
    try:
        payload = json.loads(result.stdout)
        txhash = payload.get("txhash") or payload.get("tx_response", {}).get("txhash")
    except json.JSONDecodeError as error:
        raise RuntimeError("inferenced returned non-JSON transaction output") from error
    if not isinstance(txhash, str) or not re.fullmatch(r"[0-9A-Fa-f]{64}", txhash):
        raise RuntimeError("inferenced did not return a transaction hash")
    return txhash


def signer_cli_ready():
    try:
        result = subprocess.run(
            ["inferenced", "version"],
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


class FaucetHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def reply(self, status, body):
        encoded = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path == "/health":
            if signer_cli_ready():
                self.reply(200, {"status": "ok", "signer_cli": "ready"})
            else:
                self.reply(503, {"status": "unavailable", "signer_cli": "unavailable"})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/v1/gateway-reserve":
            self.gateway_reserve()
            return
        if self.path != "/v1/claim":
            self.reply(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 2 or length > 4096:
                raise ValueError
            address = json.loads(self.rfile.read(length)).get("address", "")
        except (ValueError, json.JSONDecodeError):
            self.reply(400, {"error": "body must be JSON with one Host address"})
            return
        if not isinstance(address, str) or not ADDRESS.fullmatch(address):
            self.reply(400, {"error": "invalid Gonka Host address"})
            return
        ip = request_ip(self)
        now = int(time.time())
        with LOCK, database() as db:
            existing = db.execute("SELECT txhash, state FROM claims WHERE address = ?", (address,)).fetchone()
            if existing:
                self.reply(409, {"error": "this address has already claimed faucet funds", "txhash": existing[0], "state": existing[1]})
                return
            recent = db.execute("SELECT count(*) FROM claims WHERE ip = ? AND created_at > ?", (ip, now - WINDOW_SECONDS)).fetchone()[0]
            if recent >= MAX_CLAIMS_PER_IP:
                self.reply(429, {"error": "faucet IP claim limit reached"})
                return
            db.execute("INSERT INTO claims(address, ip, created_at, state) VALUES (?, ?, ?, 'pending')", (address, ip, now))
            db.commit()
            try:
                txhash = submit(address)
            except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
                db.execute("DELETE FROM claims WHERE address = ?", (address,))
                db.commit()
                self.reply(503, {"error": "faucet transaction was not accepted", "detail": str(error)[:240]})
                return
            db.execute("UPDATE claims SET txhash = ?, state = 'submitted' WHERE address = ?", (txhash, address))
            db.commit()
        self.reply(202, {"address": address, "amount_ngonka": AMOUNT, "txhash": txhash, "state": "submitted"})

    def gateway_reserve(self):
        """Private loopback-only target reconciliation; no caller address/amount."""
        recipient = os.environ.get("FAUCET_GATEWAY_RESERVE_RECIPIENT", "")
        token = os.environ.get("FAUCET_GATEWAY_RESERVE_TOKEN", "")
        maximum = os.environ.get("FAUCET_GATEWAY_RESERVE_MAX_NGONKA", "")
        rest = os.environ.get("FAUCET_CHAIN_REST_URL", "")
        supplied = self.headers.get("Authorization", "")
        key = self.headers.get("Idempotency-Key", "")
        if LISTEN_HOST not in {"127.0.0.1", "::1"} or not ADDRESS.fullmatch(recipient) or not token or supplied != f"Bearer {token}" or not re.fullmatch(r"[0-9a-f]{64}", key):
            self.reply(403, {"error": "gateway reserve signing is unavailable"})
            return
        try:
            maximum_int = int(maximum)
            target = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0")))).get("target_balance")
            target_int = int(target)
            if maximum_int <= 0 or target_int <= 0 or not rest.startswith("http://127.0.0.1:"):
                raise ValueError
        except (ValueError, TypeError, json.JSONDecodeError):
            self.reply(400, {"error": "invalid gateway reserve target"})
            return
        with LOCK, database() as db:
            db.execute("CREATE TABLE IF NOT EXISTS gateway_refills (idempotency_key TEXT PRIMARY KEY, txhash TEXT NOT NULL, amount TEXT NOT NULL, created_at INTEGER NOT NULL)")
            existing = db.execute("SELECT txhash, amount FROM gateway_refills WHERE idempotency_key = ?", (key,)).fetchone()
            if existing:
                self.reply(200, {"txhash": existing[0], "amount_ngonka": existing[1], "state": "submitted"})
                return
            import urllib.request
            try:
                with urllib.request.urlopen(f"{rest}/cosmos/bank/v1beta1/spendable_balances/{recipient}", timeout=10) as response:
                    balances = json.load(response).get("balances", [])
                current = int(next((item["amount"] for item in balances if item.get("denom") == "ngonka"), "0"))
            except (OSError, ValueError, KeyError, json.JSONDecodeError):
                self.reply(503, {"error": "gateway reserve balance unavailable"})
                return
            amount = max(target_int - current, 0)
            if amount == 0:
                self.reply(200, {"state": "sufficient"})
                return
            if amount > maximum_int:
                self.reply(409, {"error": "gateway reserve target exceeds limit"})
                return
            try:
                txhash = submit(recipient, str(amount))
            except (OSError, subprocess.TimeoutExpired, RuntimeError):
                self.reply(503, {"error": "gateway reserve transaction was not accepted"})
                return
            db.execute("INSERT INTO gateway_refills VALUES (?, ?, ?, ?)", (key, txhash, str(amount), int(time.time())))
            db.commit()
        self.reply(202, {"txhash": txhash, "amount_ngonka": str(amount), "state": "submitted"})


if __name__ == "__main__":
    ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), FaucetHandler).serve_forever()
