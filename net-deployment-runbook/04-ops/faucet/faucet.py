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
from datetime import datetime
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
os.umask(0o077)
CLAIMS_LINEAGE_VERSION = "2"
TELEGRAM_WINDOW_SECONDS = 86400
DEFAULT_TELEGRAM_LIMIT_NGONKA = 100 * 10**9
MAX_SQL_INTEGER = 2**63 - 1
BECH32_ALPHABET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_GENERATOR = (0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)


def database():
    db = sqlite3.connect(STATE_DB, timeout=60)
    db.execute("PRAGMA journal_mode=WAL")
    # Serialize schema adoption, bootstrap and lineage changes across workers.
    db.execute("BEGIN IMMEDIATE")
    db.execute("CREATE TABLE IF NOT EXISTS claims (address TEXT PRIMARY KEY, ip TEXT NOT NULL, created_at INTEGER NOT NULL, txhash TEXT, state TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS telegram_claims (idempotency_key TEXT PRIMARY KEY, address TEXT NOT NULL, telegram_id INTEGER NOT NULL, created_at INTEGER NOT NULL, txhash TEXT, state TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS faucet_admins (telegram_id INTEGER PRIMARY KEY)")
    db.execute("CREATE TABLE IF NOT EXISTS faucet_policy_events (id INTEGER PRIMARY KEY, actor INTEGER NOT NULL, created_at INTEGER NOT NULL, before_json TEXT NOT NULL, after_json TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS faucet_policy (id INTEGER PRIMARY KEY CHECK(id=1), open INTEGER NOT NULL CHECK(open IN (0,1)))")
    if "amount_ngonka" not in {row[1] for row in db.execute("PRAGMA table_info(telegram_claims)")}:
        # Old amounts cannot be inferred from today's environment, leave them
        # unknown and reserve quota until evidenced resolution, unresolved
        # transfers do not expire merely because a rolling window has elapsed.
        db.execute("ALTER TABLE telegram_claims ADD COLUMN amount_ngonka INTEGER")
    if "confirmed_at" not in {row[1] for row in db.execute("PRAGMA table_info(telegram_claims)")}:
        db.execute("ALTER TABLE telegram_claims ADD COLUMN confirmed_at INTEGER")
    if "last_reconcile_order" not in {row[1] for row in db.execute("PRAGMA table_info(telegram_claims)")}:
        db.execute("ALTER TABLE telegram_claims ADD COLUMN last_reconcile_order INTEGER NOT NULL DEFAULT 0")
    if "limit_ngonka" not in {row[1] for row in db.execute("PRAGMA table_info(faucet_policy)")}:
        db.execute(f"ALTER TABLE faucet_policy ADD COLUMN limit_ngonka INTEGER NOT NULL DEFAULT {DEFAULT_TELEGRAM_LIMIT_NGONKA}")
    if db.execute("SELECT count(*) FROM faucet_policy").fetchone()[0] == 0:
        # A fresh store is deliberately closed; bootstrap IDs are private GDC input.
        db.execute("INSERT INTO faucet_policy(id, open) VALUES (1, 0)")
        if not isinstance(INITIAL_ADMINS, list) or any(not valid_telegram_id(admin) for admin in INITIAL_ADMINS):
            raise ValueError("invalid private faucet administrator bootstrap")
        for admin in INITIAL_ADMINS:
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


def valid_telegram_id(value):
    return type(value) is int and 0 < value <= MAX_SQL_INTEGER


class PolicyError(ValueError):
    def __init__(self, status, reason, **details):
        super().__init__(reason)
        self.status = status
        self.body = {"error": reason, **details}


class DefinitelyRejected(RuntimeError):
    """The node explicitly rejected CheckTx, not an uncertain transport outcome."""


def telegram_usage(db, telegram_id, timestamp):
    rows = db.execute(
        "SELECT amount_ngonka, state, created_at, confirmed_at FROM telegram_claims WHERE telegram_id = ? "
        "AND (created_at > ? OR state NOT IN ('confirmed', 'failed', 'cancelled') OR confirmed_at > ? "
        "OR (state = 'confirmed' AND confirmed_at IS NULL))",
        (telegram_id, timestamp - TELEGRAM_WINDOW_SECONDS, timestamp - TELEGRAM_WINDOW_SECONDS),
    ).fetchall()
    charged = [row for row in rows if row[1] not in {"failed", "cancelled"}
               and (row[1] != "confirmed" or row[3] is None or row[3] > timestamp - TELEGRAM_WINDOW_SECONDS)]
    unknown = any(type(row[0]) is not int or row[0] <= 0 for row in charged)
    used = sum(row[0] for row in charged) if not unknown else None
    next_at = min((row[3] + TELEGRAM_WINDOW_SECONDS for row in charged
                   if row[1] == "confirmed" and row[3] is not None), default=None) if not unknown else None
    return rows, used, next_at


def reserve_telegram_claim(db, key, address, telegram_id, timestamp):
    """Atomically reserve integer amount, never rebroadcast a durable intent."""
    db.execute("BEGIN IMMEDIATE")
    existing = db.execute(
        "SELECT address, telegram_id, txhash, state, amount_ngonka, confirmed_at FROM telegram_claims WHERE idempotency_key = ?", (key,)
    ).fetchone()
    if existing:
        if existing[0] != address or existing[1] != telegram_id:
            raise PolicyError(409, "Telegram faucet request identity conflicts with existing intent")
        db.commit()
        return existing, False
    opened, limit = db.execute("SELECT open, limit_ngonka FROM faucet_policy WHERE id = 1").fetchone()
    if opened != 1:
        raise PolicyError(403, "telegram faucet is closed")
    rows, used, next_at = telegram_usage(db, telegram_id, timestamp)
    if used is None:
        raise PolicyError(503, "telegram faucet legacy amount requires reconciliation or window expiry", next_eligible_at=next_at)
    amount = max(limit - used, 0)
    if amount == 0:
        raise PolicyError(429, "telegram faucet rolling amount limit reached",
                          limit_ngonka=str(limit), used_ngonka=str(used), remaining_ngonka="0",
                          next_eligible_at=next_at, window_seconds=TELEGRAM_WINDOW_SECONDS)
    recent = [row for row in rows if row[2] > timestamp - TELEGRAM_WINDOW_SECONDS]
    if len(recent) >= TELEGRAM_MAX_CLAIMS_PER_USER:
        raise PolicyError(429, "telegram faucet anti-spam limit reached",
                          next_eligible_at=min(row[2] + TELEGRAM_WINDOW_SECONDS for row in recent))
    db.execute(
        "INSERT INTO telegram_claims(idempotency_key, address, telegram_id, created_at, state, amount_ngonka) VALUES (?, ?, ?, ?, 'pending', ?)",
        (key, address, telegram_id, timestamp, amount),
    )
    db.commit()  # Commit BEFORE any signer call, including a broadcast timeout.
    return (address, telegram_id, None, "pending", amount, None), True


def dispatch_telegram_claim(db, key):
    """Serialize final policy check and signer through the close acknowledgement."""
    db.execute("BEGIN IMMEDIATE")
    address, state, amount = db.execute(
        "SELECT address, state, amount_ngonka FROM telegram_claims WHERE idempotency_key = ?", (key,)
    ).fetchone()
    if state != "pending":
        raise PolicyError(409, "Telegram faucet intent is no longer dispatchable")
    if db.execute("SELECT open FROM faucet_policy WHERE id = 1").fetchone()[0] != 1:
        db.execute("UPDATE telegram_claims SET state = 'cancelled' WHERE idempotency_key = ?", (key,))
        db.commit()
        return None, "cancelled"
    try:
        txhash = submit(address, str(amount), memo=f"gdc-tg:{key[:16]}")
    except DefinitelyRejected:
        db.execute("UPDATE telegram_claims SET state = 'failed' WHERE idempotency_key = ?", (key,))
        db.commit()
        return None, "failed"
    except (OSError, subprocess.TimeoutExpired, RuntimeError):
        db.execute("UPDATE telegram_claims SET state = 'uncertain' WHERE idempotency_key = ?", (key,))
        db.commit()
        return None, "uncertain"
    db.execute("UPDATE telegram_claims SET txhash = ?, state = 'submitted' WHERE idempotency_key = ?", (txhash, key))
    db.commit()
    return txhash, "submitted"


def policy_snapshot(db):
    opened, limit = db.execute("SELECT open, limit_ngonka FROM faucet_policy WHERE id = 1").fetchone()
    return {"open": opened, "limit_ngonka": limit,
            "administrator_ids": [row[0] for row in db.execute("SELECT telegram_id FROM faucet_admins ORDER BY telegram_id")]}


def reconcile_telegram_hash(db, key, txhash):
    """Only a matching observed chain result can resolve a submitted intent."""
    observed, settled_at = transaction_observation(txhash)
    if observed in {"confirmed", "failed"}:
        db.execute("UPDATE telegram_claims SET state = ?, confirmed_at = ? WHERE idempotency_key = ? "
                   "AND (state = 'submitted' OR (state = 'confirmed' AND confirmed_at IS NULL))",
                   (observed, settled_at, key))
        db.commit()
    return observed


def reconcile_telegram_user(db, actor):
    # One bounded query per request, no unbounded historical network scan.
    # Persist a fair order BEFORE I/O, an unavailable oldest hash must not
    # starve younger completed transfers, even on restart or a frozen clock.
    db.execute("BEGIN IMMEDIATE")
    existing = db.execute("SELECT idempotency_key, txhash FROM telegram_claims WHERE telegram_id = ? "
                          "AND (state = 'submitted' OR (state = 'confirmed' AND confirmed_at IS NULL)) "
                          "AND txhash IS NOT NULL ORDER BY last_reconcile_order, created_at, idempotency_key LIMIT 1", (actor,)).fetchone()
    if existing:
        recorded = db.execute("SELECT value FROM metadata WHERE key='faucet_reconcile_cursor'").fetchone()
        try:
            cursor = int(recorded[0]) if recorded else 0
        except ValueError as error:
            db.rollback()
            raise PolicyError(503, "telegram faucet reconciliation cursor is invalid") from error
        if not 0 <= cursor < MAX_SQL_INTEGER:
            db.rollback()
            raise PolicyError(503, "telegram faucet reconciliation cursor is invalid")
        cursor += 1
        db.execute("INSERT INTO metadata(key,value) VALUES ('faucet_reconcile_cursor',?) "
                   "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (str(cursor),))
        db.execute("UPDATE telegram_claims SET last_reconcile_order=? WHERE idempotency_key=?", (cursor, existing[0]))
        db.commit()
        reconcile_telegram_hash(db, existing[0], existing[1])
    else:
        db.commit()


def administer_telegram(db, actor, action, value=None):
    """Authorize and apply persisted administration in one SQLite transaction."""
    db.execute("BEGIN IMMEDIATE")
    is_admin = bool(db.execute("SELECT 1 FROM faucet_admins WHERE telegram_id = ?", (actor,)).fetchone())
    if action != "status" and not is_admin:
        raise PolicyError(403, "telegram user is not a faucet administrator")
    before = policy_snapshot(db)
    if action in {"open", "close"}:
        db.execute("UPDATE faucet_policy SET open = ? WHERE id = 1", (int(action == "open"),))
    elif action in {"add", "remove"}:
        if not valid_telegram_id(value):
            raise PolicyError(400, "invalid faucet administrator ID")
        if action == "add":
            db.execute("INSERT OR IGNORE INTO faucet_admins(telegram_id) VALUES (?)", (value,))
        else:
            exists = db.execute("SELECT 1 FROM faucet_admins WHERE telegram_id = ?", (value,)).fetchone()
            if exists and db.execute("SELECT count(*) FROM faucet_admins").fetchone()[0] <= 1:
                raise PolicyError(409, "cannot remove the last faucet administrator")
            db.execute("DELETE FROM faucet_admins WHERE telegram_id = ?", (value,))
    elif action == "limit":
        if type(value) is not int or not 0 < value <= MAX_SQL_INTEGER:
            raise PolicyError(400, "limit_ngonka must be a positive bounded integer")
        db.execute("UPDATE faucet_policy SET limit_ngonka = ? WHERE id = 1", (value,))
    elif action not in {"status", "list"}:
        raise PolicyError(400, "invalid faucet administrator action")
    opened, limit = db.execute("SELECT open, limit_ngonka FROM faucet_policy WHERE id = 1").fetchone()
    after = policy_snapshot(db)
    if before != after:
        db.execute("INSERT INTO faucet_policy_events(actor, created_at, before_json, after_json) VALUES (?, ?, ?, ?)",
                   (actor, int(time.time()), json.dumps(before, sort_keys=True), json.dumps(after, sort_keys=True)))
    result = {"state": "open" if opened else "closed", "admin": is_admin}
    if action == "status":
        rows, used, next_at = telegram_usage(db, actor, int(time.time()))
        remaining = max(limit - used, 0) if used is not None else 0
        recent = [row for row in rows if row[2] > int(time.time()) - TELEGRAM_WINDOW_SECONDS]
        attempts = max(TELEGRAM_MAX_CLAIMS_PER_USER - len(recent), 0)
        if attempts == 0 and recent:
            next_at = min(row[2] + TELEGRAM_WINDOW_SECONDS for row in recent) if remaining > 0 else next_at
        result.update(limit_ngonka=str(limit), used_ngonka=str(used) if used is not None else None,
                      remaining_ngonka=str(remaining), next_eligible_at=next_at if remaining == 0 or attempts == 0 else None,
                      anti_spam_remaining=attempts,
                      window_seconds=TELEGRAM_WINDOW_SECONDS, accounting="known" if used is not None else "unknown",
                      chain_service_state="unverified")
    if action not in {"open", "close", "status"}:
        result.update(limit_ngonka=str(limit), window_seconds=TELEGRAM_WINDOW_SECONDS,
                      administrator_ids=[row[0] for row in db.execute("SELECT telegram_id FROM faucet_admins ORDER BY telegram_id")])
    db.commit()
    return result


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
        if not isinstance(payload, dict):
            raise RuntimeError("inferenced returned malformed transaction output")
        tx_response = payload.get("tx_response", {})
        if not isinstance(tx_response, dict):
            raise RuntimeError("inferenced returned malformed transaction output")
        code = payload.get("code", tx_response.get("code"))
        if code is not None:
            if type(code) is not int or code < 0:
                raise RuntimeError("inferenced returned malformed transaction code")
            if code != 0:
                raise DefinitelyRejected("faucet transaction was rejected by the node")
        txhash = payload.get("txhash") or tx_response.get("txhash")
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


def transaction_observation(txhash):
    """Return only an observed chain state; unavailable is never confirmation."""
    if not CHAIN_REST_URL or not re.fullmatch(r"[0-9A-Fa-f]{64}", txhash):
        return "unavailable", None
    try:
        with urllib.request.urlopen(f"{CHAIN_REST_URL}/cosmos/tx/v1beta1/txs/{txhash}", timeout=5) as response:
            payload = json.load(response)
        if not isinstance(payload, dict):
            return "pending", None
        tx_response = payload.get("tx_response", {})
        if not isinstance(tx_response, dict) or type(tx_response.get("code")) is not int:
            return "pending", None
        if str(tx_response.get("txhash", "")).upper() != txhash.upper():
            return "pending", None
        if tx_response["code"] != 0:
            return "failed", None
        # SDK GetTx returns its verified transaction block's RFC3339 time,
        # never substitute the request or observation clock for settlement.
        timestamp = tx_response.get("timestamp")
        if not isinstance(timestamp, str):
            return "pending", None
        settled = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if settled.tzinfo is None or not 0 < settled.timestamp() <= time.time():
            return "pending", None
        return "confirmed", int(settled.timestamp())
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, ValueError, json.JSONDecodeError):
        return "pending", None


def transaction_confirmation(txhash):
    return transaction_observation(txhash)[0]


def telegram_payload(address, amount, txhash, state):
    body = {"address": address, "amount_ngonka": amount, "state": state}
    if txhash:
        body["txhash"] = txhash
        observed, settled_at = transaction_observation(txhash)
        body["confirmation"] = observed
        if settled_at is not None:
            body["confirmed_at"] = settled_at
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
            if not isinstance(payload, dict):
                raise ValueError
            address = payload.get("address")
            telegram_id = payload.get("telegram_user_id")
            if not valid_address(address) or not valid_telegram_id(telegram_id):
                raise ValueError
        except (ValueError, TypeError, json.JSONDecodeError):
            self.reply(400, {"error": "invalid Telegram faucet request"})
            return
        timestamp = int(time.time())
        with LOCK, database() as db:
            try:
                reconcile_telegram_user(db, telegram_id)
                existing, fresh = reserve_telegram_claim(db, key, address, telegram_id, timestamp)
            except PolicyError as error:
                db.rollback()
                self.reply(error.status, error.body)
                return
            amount = str(existing[4]) if existing[4] is not None else None
            if not fresh:
                state = existing[3]
                body = telegram_payload(existing[0], amount, existing[2], "submitted" if state == "confirmed" else state)
                if state in {"confirmed", "failed"}:
                    body["confirmation"] = "pending" if state == "confirmed" and existing[5] is None else state
                    if state == "confirmed" and existing[5] is not None:
                        body["confirmed_at"] = existing[5]
                if existing[2] and state == "submitted" and body.get("confirmation") == "failed":
                    db.execute("UPDATE telegram_claims SET state = 'failed' WHERE idempotency_key = ?", (key,))
                    db.commit()
                    state = body["state"] = "failed"
                if existing[2] and state == "submitted" and body.get("confirmation") == "confirmed":
                    db.execute("UPDATE telegram_claims SET state = 'confirmed', confirmed_at = ? WHERE idempotency_key = ?", (body["confirmed_at"], key))
                    db.commit()
                status = 202 if state in {"submitted", "confirmed"} else 503 if state in {"pending", "uncertain"} else 200
                self.reply(status, body)
                return
            txhash, state = dispatch_telegram_claim(db, key)
            body = telegram_payload(address, amount, txhash, state)
            if state == "submitted" and body.get("confirmation") in {"confirmed", "failed"}:
                observed = body["confirmation"]
                db.execute("UPDATE telegram_claims SET state = ?, confirmed_at = ? WHERE idempotency_key = ?",
                           (observed, body.get("confirmed_at"), key))
                db.commit()
                if observed == "failed":
                    state = body["state"] = "failed"
        self.reply(202 if state == "submitted" else 503 if state == "uncertain" else 200,
                   body)

    def telegram_admin(self):
        supplied = self.headers.get("Authorization", "")
        if not TELEGRAM_TOKEN or supplied != f"Bearer {TELEGRAM_TOKEN}":
            self.reply(403, {"error": "telegram faucet is unavailable"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 2 <= length <= 4096:
                raise ValueError
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError
            actor, action = payload["telegram_user_id"], payload["action"]
            if not valid_telegram_id(actor) or not isinstance(action, str) or action not in {"status", "open", "close", "list", "add", "remove", "limit"}:
                raise ValueError
            field = "administrator_id" if action in {"add", "remove"} else "limit_ngonka" if action == "limit" else None
            expected = {"telegram_user_id", "action"} | ({field} if field else set())
            if set(payload) != expected:
                raise ValueError
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            self.reply(400, {"error": "invalid Telegram faucet administration request"})
            return
        with LOCK, database() as db:
            try:
                if action == "status":
                    reconcile_telegram_user(db, actor)
                result = administer_telegram(db, actor, action, payload.get(field) if field else None)
            except PolicyError as error:
                db.rollback()
                self.reply(error.status, error.body)
                return
        self.reply(200, result)

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
