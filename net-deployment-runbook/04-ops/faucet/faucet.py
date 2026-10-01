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
import urllib.error
import urllib.request
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
TELEGRAM_TOKEN = os.environ.get("FAUCET_TELEGRAM_TOKEN", "")
TELEGRAM_MAX_CLAIMS_PER_USER = int(os.environ.get("FAUCET_TELEGRAM_MAX_CLAIMS_PER_USER", "1"))
INITIAL_ADMINS = json.loads(os.environ.get("FAUCET_INITIAL_ADMINS_JSON", "[]"))
CHAIN_REST_URL = os.environ.get("FAUCET_CHAIN_REST_URL", "").rstrip("/")
LOCK = threading.Lock()
CLAIMS_LINEAGE_VERSION = "2"
BECH32_ALPHABET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_GENERATOR = (0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)


def database():
    db = sqlite3.connect(STATE_DB)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE IF NOT EXISTS claims (address TEXT PRIMARY KEY, ip TEXT NOT NULL, created_at INTEGER NOT NULL, txhash TEXT, state TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS telegram_claims (idempotency_key TEXT PRIMARY KEY, address TEXT NOT NULL, telegram_id INTEGER NOT NULL, created_at INTEGER NOT NULL, txhash TEXT, state TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS faucet_admins (telegram_id INTEGER PRIMARY KEY)")
    db.execute("CREATE TABLE IF NOT EXISTS faucet_policy (id INTEGER PRIMARY KEY CHECK(id=1), open INTEGER NOT NULL CHECK(open IN (0,1)))")
    if db.execute("SELECT count(*) FROM faucet_policy").fetchone()[0] == 0:
        # A fresh store is deliberately closed; bootstrap IDs are private GDC input.
        db.execute("INSERT INTO faucet_policy(id, open) VALUES (1, 0)")
        for admin in INITIAL_ADMINS:
            if isinstance(admin, int) and admin > 0:
                db.execute("INSERT OR IGNORE INTO faucet_admins(telegram_id) VALUES (?)", (admin,))
    recorded = db.execute("SELECT value FROM metadata WHERE key = 'genesis_sha256'").fetchone()
    lineage_version = db.execute("SELECT value FROM metadata WHERE key = 'claims_lineage_version'").fetchone()
    if lineage_version is None or lineage_version[0] != CLAIMS_LINEAGE_VERSION:
        # Databases created before claims were scoped to a Genesis lineage may
        # contain valid-looking limits that belong to an already reset chain.
        # Clear that legacy state exactly once when adopting this schema.
        db.execute("DELETE FROM claims")
        db.execute("DELETE FROM telegram_claims")
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
        db.execute("DELETE FROM telegram_claims")
        db.execute("UPDATE metadata SET value = ? WHERE key = 'genesis_sha256'", (GENESIS_SHA256,))
    db.commit()
    return db


def bech32_polymod(values):
    checksum = 1
    for value in values:
        top = checksum >> 25
        checksum = (checksum & 0x1FFFFFF) << 5 ^ value
        for index, generator in enumerate(BECH32_GENERATOR):
            if (top >> index) & 1:
                checksum ^= generator
    return checksum


def valid_address(address):
    """Accept only canonical Gonka Bech32 account addresses, not a prefix regex."""
    if not isinstance(address, str) or not ADDRESS.fullmatch(address) or address.lower() != address:
        return False
    separator = address.rfind("1")
    if separator != len("gonka") or len(address) - separator - 1 < 6:
        return False
    try:
        values = [BECH32_ALPHABET.index(character) for character in address[separator + 1:]]
    except ValueError:
        return False
    expanded = [ord(character) >> 5 for character in "gonka"] + [0]
    expanded += [ord(character) & 31 for character in "gonka"]
    return bech32_polymod(expanded + values) == 1


def request_ip(handler):
    candidate = handler.headers.get("X-Forwarded-For", "").split(",", 1)[0].strip() or handler.client_address[0]
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        return "invalid"


def submit(address, amount=AMOUNT, memo=None):
    env = os.environ.copy()
    env["HOME"] = "/home/faucet"
    result = subprocess.run(
        ["inferenced", "tx", "bank", "send", KEY_NAME, address, f"{amount}ngonka", "--from", KEY_NAME,
         "--keyring-backend", "file", "--chain-id", CHAIN_ID, "--node", RPC_URL, "--gas", "auto",
         "--gas-adjustment", "1.5", "--gas-prices", "0ngonka", "--broadcast-mode", "sync", "--output", "json"]
        + (["--memo", memo] if memo else []) + ["--yes"],
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


def safe_transaction_error(error):
    """Classify signer failures without returning CLI output or private state."""
    message = str(error).lower()
    if "insufficient funds" in message:
        return "gateway reserve funding account has insufficient funds"
    if "account sequence mismatch" in message or "incorrect account sequence" in message:
        return "gateway reserve signer sequence conflict"
    if "timed out" in message or "timeout" in message:
        return "gateway reserve transaction timed out"
    return "gateway reserve transaction was not accepted"


def transaction_confirmation(txhash):
    """Return only an observed chain state; unavailable is never confirmation."""
    if not CHAIN_REST_URL or not re.fullmatch(r"[0-9A-Fa-f]{64}", txhash):
        return "unavailable"
    try:
        with urllib.request.urlopen(f"{CHAIN_REST_URL}/cosmos/tx/v1beta1/txs/{txhash}", timeout=5) as response:
            payload = json.load(response)
        tx_response = payload.get("tx_response", {})
        return "confirmed" if isinstance(tx_response, dict) and tx_response.get("code") == 0 else "failed"
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, ValueError, json.JSONDecodeError):
        return "pending"


def telegram_payload(address, amount, txhash, state):
    body = {"address": address, "amount_ngonka": amount, "state": state}
    if txhash:
        body["txhash"] = txhash
        body["confirmation"] = transaction_confirmation(txhash)
    return body


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
        if self.path == "/v1/telegram-claim":
            self.telegram_claim()
            return
        if self.path == "/v1/telegram-admin":
            self.telegram_admin()
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
        if not valid_address(address):
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
                # A broadcast timeout is ambiguous. Retain the pending intent
                # so a delivery retry cannot create a second transaction.
                db.execute("UPDATE claims SET state = 'uncertain' WHERE address = ?", (address,))
                db.commit()
                self.reply(503, {"error": "faucet transaction is uncertain; retry will reconcile the existing request"})
                return
            db.execute("UPDATE claims SET txhash = ?, state = 'submitted' WHERE address = ?", (txhash, address))
            db.commit()
        self.reply(202, {"address": address, "amount_ngonka": AMOUNT, "txhash": txhash, "state": "submitted"})

    def telegram_claim(self):
        """Authenticated repeatable faucet path for the existing Telegram bot."""
        supplied = self.headers.get("Authorization", "")
        key = self.headers.get("Idempotency-Key", "")
        if not TELEGRAM_TOKEN or supplied != f"Bearer {TELEGRAM_TOKEN}" or not re.fullmatch(r"[0-9a-f]{64}", key):
            self.reply(403, {"error": "telegram faucet is unavailable"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length)) if 2 <= length <= 4096 else None
            address = payload.get("address")
            telegram_id = payload.get("telegram_user_id")
            if not valid_address(address) or not isinstance(telegram_id, int) or telegram_id <= 0:
                raise ValueError
        except (ValueError, TypeError, json.JSONDecodeError):
            self.reply(400, {"error": "invalid Telegram faucet request"})
            return
        timestamp = int(time.time())
        with LOCK, database() as db:
            if db.execute("SELECT open FROM faucet_policy WHERE id = 1").fetchone()[0] != 1:
                self.reply(403, {"error": "telegram faucet is closed"})
                return
            existing = db.execute(
                "SELECT address, txhash, state FROM telegram_claims WHERE idempotency_key = ?", (key,)
            ).fetchone()
            if existing:
                status = 202 if existing[2] == "submitted" else 503 if existing[2] == "uncertain" else 200
                self.reply(status, telegram_payload(existing[0], AMOUNT, existing[1], existing[2]))
                return
            recent = db.execute(
                "SELECT count(*) FROM telegram_claims WHERE telegram_id = ? AND created_at > ?",
                (telegram_id, timestamp - WINDOW_SECONDS),
            ).fetchone()[0]
            if recent >= TELEGRAM_MAX_CLAIMS_PER_USER:
                self.reply(429, {"error": "telegram faucet anti-spam limit reached"})
                return
            db.execute(
                "INSERT INTO telegram_claims(idempotency_key, address, telegram_id, created_at, state) VALUES (?, ?, ?, ?, 'pending')",
                (key, address, telegram_id, timestamp),
            )
            db.commit()
            try:
                txhash = submit(address, memo=f"gdc-tg:{key[:16]}")
            except (OSError, subprocess.TimeoutExpired, RuntimeError):
                db.execute("UPDATE telegram_claims SET state = 'uncertain' WHERE idempotency_key = ?", (key,))
                db.commit()
                self.reply(503, telegram_payload(address, AMOUNT, None, "uncertain"))
                return
            db.execute("UPDATE telegram_claims SET txhash = ?, state = 'submitted' WHERE idempotency_key = ?", (txhash, key))
            db.commit()
        self.reply(202, telegram_payload(address, AMOUNT, txhash, "submitted"))

    def telegram_admin(self):
        supplied = self.headers.get("Authorization", "")
        if not TELEGRAM_TOKEN or supplied != f"Bearer {TELEGRAM_TOKEN}":
            self.reply(403, {"error": "telegram faucet is unavailable"})
            return
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            actor, action = payload["telegram_user_id"], payload["action"]
            if not isinstance(actor, int) or actor <= 0 or action not in {"status", "open", "close"}:
                raise ValueError
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            self.reply(400, {"error": "invalid Telegram faucet administration request"})
            return
        with LOCK, database() as db:
            admin = db.execute("SELECT 1 FROM faucet_admins WHERE telegram_id = ?", (actor,)).fetchone()
            if not admin:
                self.reply(403, {"error": "telegram user is not a faucet administrator"})
                return
            if action in {"open", "close"}:
                db.execute("UPDATE faucet_policy SET open = ? WHERE id = 1", (1 if action == "open" else 0,))
                db.commit()
            opened = bool(db.execute("SELECT open FROM faucet_policy WHERE id = 1").fetchone()[0])
        self.reply(200, {"state": "open" if opened else "closed", "admin": True})

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
            except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
                self.reply(503, {"error": safe_transaction_error(error)})
                return
            db.execute("INSERT INTO gateway_refills VALUES (?, ?, ?, ?)", (key, txhash, str(amount), int(time.time())))
            db.commit()
        self.reply(202, {"txhash": txhash, "amount_ngonka": str(amount), "state": "submitted"})


if __name__ == "__main__":
    ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), FaucetHandler).serve_forever()
