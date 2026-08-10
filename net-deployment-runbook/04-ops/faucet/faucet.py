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


def submit(address):
    env = os.environ.copy()
    env["HOME"] = "/home/faucet"
    result = subprocess.run(
        ["inferenced", "tx", "bank", "send", KEY_NAME, address, f"{AMOUNT}ngonka", "--from", KEY_NAME,
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


if __name__ == "__main__":
    ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), FaucetHandler).serve_forever()
