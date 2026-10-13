#!/usr/bin/env python3
"""Durable private mapping from public sk-gdc credentials to Bifrost virtual keys."""
import hashlib
import hmac
import json
import secrets
import sqlite3
import threading
import time
from base64 import b64encode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from cryptography.fernet import Fernet, InvalidToken


def _digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class BifrostClient:
    """Small management-only client; user credentials never reach this boundary."""
    def __init__(self, base_url, username, password, provider, model, key_id, timeout=10):
        if not all(isinstance(value, str) and value for value in (base_url, username, password, provider, model, key_id)):
            raise ValueError("Bifrost management configuration must be non-empty")
        if not isinstance(timeout, int) or timeout <= 0:
            raise ValueError("Bifrost management timeout must be positive")
        self.base_url = base_url.rstrip("/")
        parsed = urlsplit(self.base_url)
        if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"127.0.0.1", "::1"}:
            raise ValueError("Bifrost management URL must be loopback HTTP(S)")
        self.authorization = "Basic " + b64encode(f"{username}:{password}".encode()).decode()
        self.provider, self.model, self.key_id, self.timeout = provider, model, key_id, timeout

    def _request(self, path, payload):
        request = Request(self.base_url + path, data=json.dumps(payload).encode(), headers={
            "Authorization": self.authorization, "Content-Type": "application/json",
        }, method="POST")
        try:
            with urlopen(request, timeout=self.timeout) as response:
                if response.status != 200:
                    raise RuntimeError("Bifrost management returned an unexpected status")
                result = json.load(response)
        except (HTTPError, URLError, OSError, ValueError, json.JSONDecodeError) as error:
            raise RuntimeError("Bifrost management request failed") from error
        virtual_key = result.get("virtual_key") if isinstance(result, dict) else None
        if not isinstance(virtual_key, dict) or not all(isinstance(virtual_key.get(x), str) and virtual_key[x] for x in ("id", "value")):
            raise RuntimeError("Bifrost management returned an invalid virtual key")
        return {"id": virtual_key["id"], "value": virtual_key["value"]}

    def create(self, telegram_id):
        if not isinstance(telegram_id, int) or telegram_id <= 0:
            raise ValueError("telegram_id must be positive")
        # Stable opaque label permits reconciliation without exporting a Telegram ID to Bifrost logs.
        label = hashlib.sha256(str(telegram_id).encode()).hexdigest()[:16]
        return self._request("/api/governance/virtual-keys", {
            "name": f"telegram-{label}", "description": "Telegram user stable API key",
            "is_active": True, "disable_content_logging": True,
            "provider_configs": [{"provider": self.provider, "allowed_models": [self.model], "key_ids": [self.key_id]}],
        })

    def rotate(self, bifrost_id):
        if not isinstance(bifrost_id, str) or not bifrost_id:
            raise ValueError("Bifrost virtual key ID must be non-empty")
        return self._request(f"/api/governance/virtual-keys/{bifrost_id}/rotate", {})


class Broker:
    def __init__(self, path, bifrost, encryption_key):
        if not isinstance(encryption_key, bytes):
            raise ValueError("encryption_key must be bytes")
        try:
            self.box = Fernet(encryption_key)
        except (TypeError, ValueError) as error:
            raise ValueError("invalid encryption key") from error
        self.db = sqlite3.connect(path, timeout=10, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(keys)")}
        if "bifrost_value" in columns:
            self._migrate_plaintext_keys()
        self.db.execute("""CREATE TABLE IF NOT EXISTS keys (
          telegram_id INTEGER PRIMARY KEY, external_hash TEXT UNIQUE NOT NULL,
          bifrost_id TEXT UNIQUE NOT NULL, bifrost_value_ciphertext BLOB NOT NULL,
          created_at INTEGER NOT NULL, rotated_at INTEGER NOT NULL)""")
        self.db.execute("""CREATE TABLE IF NOT EXISTS key_updates (
          update_id INTEGER PRIMARY KEY, telegram_id INTEGER NOT NULL,
          external_ciphertext BLOB NOT NULL, created_at INTEGER NOT NULL)""")
        self.db.commit()
        self.bifrost = bifrost
        self.lock = threading.Lock()

    def _migrate_plaintext_keys(self):
        # Keep schema replacement atomic, then rewrite freed SQLite pages containing the legacy value.
        with self.db:
            self.db.execute("""CREATE TABLE keys_encrypted (
              telegram_id INTEGER PRIMARY KEY, external_hash TEXT UNIQUE NOT NULL,
              bifrost_id TEXT UNIQUE NOT NULL, bifrost_value_ciphertext BLOB NOT NULL,
              created_at INTEGER NOT NULL, rotated_at INTEGER NOT NULL)""")
            for row in self.db.execute("SELECT telegram_id, external_hash, bifrost_id, bifrost_value, created_at, rotated_at FROM keys"):
                self.db.execute("INSERT INTO keys_encrypted VALUES (?, ?, ?, ?, ?, ?)",
                                (*row[:3], self.box.encrypt(row[3].encode()), *row[4:]))
            self.db.execute("DROP TABLE keys")
            self.db.execute("ALTER TABLE keys_encrypted RENAME TO keys")
        self.db.execute("VACUUM")
        self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    def _external(self):
        return "sk-gdc-" + secrets.token_urlsafe(36)

    def issue(self, telegram_id):
        if not isinstance(telegram_id, int) or telegram_id <= 0:
            raise ValueError("telegram_id must be positive")
        existing = self.db.execute("SELECT 1 FROM keys WHERE telegram_id=?", (telegram_id,)).fetchone()
        if existing:
            raise ValueError("key already issued; rotate it instead")
        external = self._external()
        native = self.bifrost.create(telegram_id)
        if not isinstance(native, dict) or not all(isinstance(native.get(x), str) and native[x] for x in ("id", "value")):
            raise RuntimeError("Bifrost returned an invalid virtual key")
        if not native["value"].startswith("sk-bf-"):
            raise RuntimeError("Bifrost returned an unexpected virtual key prefix")
        now = int(time.time())
        self.db.execute("INSERT INTO keys VALUES (?, ?, ?, ?, ?, ?)",
                        (telegram_id, _digest(external), native["id"], self.box.encrypt(native["value"].encode()), now, now))
        self.db.commit()
        return external

    def rotate(self, telegram_id):
        row = self.db.execute("SELECT bifrost_id FROM keys WHERE telegram_id=?", (telegram_id,)).fetchone()
        if not row:
            return self.issue(telegram_id)
        native = self.bifrost.rotate(row[0])
        if not isinstance(native, dict) or not isinstance(native.get("value"), str) or not native["value"].startswith("sk-bf-"):
            raise RuntimeError("Bifrost returned an invalid rotated virtual key")
        external = self._external()
        self.db.execute("UPDATE keys SET external_hash=?, bifrost_value_ciphertext=?, rotated_at=? WHERE telegram_id=?",
                        (_digest(external), self.box.encrypt(native["value"].encode()), int(time.time()), telegram_id))
        self.db.commit()
        return external

    def resolve(self, external):
        if not isinstance(external, str) or not external.startswith("sk-gdc-"):
            return None
        row = self.db.execute("SELECT bifrost_value_ciphertext FROM keys WHERE external_hash=?", (_digest(external),)).fetchone()
        if not row:
            return None
        try:
            return self.box.decrypt(row[0]).decode()
        except (InvalidToken, UnicodeDecodeError) as error:
            raise RuntimeError("stored Bifrost key cannot be decrypted") from error

    def issue_for_update(self, telegram_id, update_id):
        """Serialize a Telegram update so retries never trigger another rotation."""
        if not isinstance(update_id, int) or update_id < 0:
            raise ValueError("update_id must be non-negative")
        with self.lock:
            row = self.db.execute(
                "SELECT telegram_id, external_ciphertext FROM key_updates WHERE update_id=?", (update_id,)
            ).fetchone()
            if row:
                if row[0] != telegram_id:
                    raise RuntimeError("update_id belongs to another Telegram user")
                try:
                    return self.box.decrypt(row[1]).decode()
                except (InvalidToken, UnicodeDecodeError) as error:
                    raise RuntimeError("stored delivery key cannot be decrypted") from error
            existing = self.db.execute("SELECT 1 FROM keys WHERE telegram_id=?", (telegram_id,)).fetchone()
            external = self.rotate(telegram_id) if existing else self.issue(telegram_id)
            self.db.execute(
                "INSERT INTO key_updates VALUES (?, ?, ?, ?)",
                (update_id, telegram_id, self.box.encrypt(external.encode()), int(time.time())),
            )
            self.db.commit()
            return external


class BrokerHandler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def do_POST(self):
        authorization = self.headers.get("Authorization", "")
        if self.path == "/v1/resolve":
            if not self.server.edge_token or not hmac.compare_digest(authorization, f"Bearer {self.server.edge_token}"):
                self.send_error(401)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length < 2 or length > 1024:
                    raise ValueError("invalid request size")
                body = json.loads(self.rfile.read(length))
                value = self.server.broker.resolve(body.get("key"))
                if value is None:
                    self.send_error(401)
                    return
                encoded = json.dumps({"virtual_key": value}).encode()
                self.send_response(200); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
            except (ValueError, json.JSONDecodeError):
                self.send_error(400)
            except RuntimeError:
                self.send_error(409)
            return
        if self.path != "/v1/keys" or not hmac.compare_digest(authorization, f"Bearer {self.server.token}"):
            self.send_error(401)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 2 or length > 1024:
                raise ValueError("invalid request size")
            body = json.loads(self.rfile.read(length))
            key = self.server.broker.issue_for_update(body.get("telegram_id"), body.get("update_id"))
            encoded = json.dumps({"key": key}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
        except (ValueError, json.JSONDecodeError):
            self.send_error(400)
        except RuntimeError:
            self.send_error(409)


def serve(broker, token, host="127.0.0.1", port=9465, edge_token=None):
    if not isinstance(token, str) or len(token) < 24:
        raise ValueError("broker token must have at least 24 characters")
    server = ThreadingHTTPServer((host, port), BrokerHandler)
    if edge_token is not None and (not isinstance(edge_token, str) or len(edge_token) < 24):
        raise ValueError("edge token must have at least 24 characters")
    server.broker, server.token, server.edge_token = broker, token, edge_token
    return server
