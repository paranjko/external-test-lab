#!/usr/bin/env python3
"""Telegram conversation client for the Community DevNet inference gateway."""

import json
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


TELEGRAM_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
GATEWAY_API_KEY = os.environ["GATEWAY_API_KEY"]
INTERNAL_API_TOKEN = os.environ["INTERNAL_API_TOKEN"]
GATEWAY_API_BASE_URL = os.environ.get("GATEWAY_API_BASE_URL", "https://api.gonka-dev.net/v1").rstrip("/")
INTERNAL_API_BASE_URL = os.environ.get("INTERNAL_API_BASE_URL", "http://127.0.0.1:9464").rstrip("/")
MODEL = os.environ.get("MODEL", "Qwen/Qwen3-0.6B")
DB_FILE = Path(os.environ.get("STATE_DB", "/data/bot.sqlite3"))
METRICS_FILE = Path(os.environ.get("METRICS_FILE", "/metrics/telegram-bot.prom"))
HTTP_HOST = os.environ.get("HTTP_HOST", "0.0.0.0")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "9464"))
MAX_HISTORY_MESSAGES = int(os.environ.get("CONVERSATION_MAX_MESSAGES", "12"))
MAX_HISTORY_CHARS = int(os.environ.get("CONVERSATION_MAX_CHARS", "6000"))
MAX_USER_MESSAGE_CHARS = int(os.environ.get("USER_MESSAGE_MAX_CHARS", "2000"))
MAX_OUTPUT_TOKENS = int(os.environ.get("MAX_OUTPUT_TOKENS", "512"))
HEALTH_MAX_AGE_SECONDS = int(os.environ.get("HEALTH_MAX_AGE_SECONDS", "900"))
GATEWAY_TIMEOUT_SECONDS = int(os.environ.get("GATEWAY_TIMEOUT_SECONDS", "30"))
INTERNAL_API_TIMEOUT_SECONDS = int(os.environ.get("INTERNAL_API_TIMEOUT_SECONDS", "35"))
TELEGRAM_REQUEST_TIMEOUT_SECONDS = int(os.environ.get("TELEGRAM_REQUEST_TIMEOUT_SECONDS", "10"))
TELEGRAM_POLL_TIMEOUT_SECONDS = int(os.environ.get("TELEGRAM_POLL_TIMEOUT_SECONDS", "35"))
TYPING_REFRESH_SECONDS = int(os.environ.get("TYPING_REFRESH_SECONDS", "4"))
TG_API = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}"
THINK_BLOCK = re.compile(r"<think\b[^>]*>.*?</think\s*>", re.IGNORECASE | re.DOTALL)
UNCLOSED_THINK_BLOCK = re.compile(r"<think\b[^>]*>.*\Z", re.IGNORECASE | re.DOTALL)
THINK_TAG = re.compile(r"</?think\b[^>]*>", re.IGNORECASE)


def now() -> int:
    return int(time.time())


def visible_output_text(value: str) -> str:
    """Remove model reasoning blocks before persistence or user delivery."""
    text = THINK_BLOCK.sub("", value)
    text = UNCLOSED_THINK_BLOCK.sub("", text)
    text = THINK_TAG.sub("", text)
    text = re.sub(r"\n[ \t]*\n(?:[ \t]*\n)+", "\n\n", text)
    return text.strip()


def connection() -> sqlite3.Connection:
    DB_FILE.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB_FILE, timeout=10)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=10000")
    db.executescript(
        """
        DROP TABLE IF EXISTS keys;
        CREATE TABLE IF NOT EXISTS users (
          telegram_id INTEGER PRIMARY KEY,
          is_premium INTEGER NOT NULL CHECK (is_premium IN (0, 1)),
          first_seen INTEGER NOT NULL,
          last_seen INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS conversations (
          conversation_id TEXT PRIMARY KEY,
          telegram_id INTEGER UNIQUE,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          conversation_id TEXT NOT NULL,
          role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
          content TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS messages_conversation_id
          ON messages (conversation_id, id);
        CREATE TABLE IF NOT EXISTS interactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          telegram_id INTEGER NOT NULL,
          kind TEXT NOT NULL,
          outcome TEXT NOT NULL,
          is_premium INTEGER NOT NULL CHECK (is_premium IN (0, 1)),
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS inference_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          model TEXT NOT NULL,
          outcome TEXT NOT NULL,
          input_tokens INTEGER NOT NULL DEFAULT 0,
          output_tokens INTEGER NOT NULL DEFAULT 0,
          total_tokens INTEGER NOT NULL DEFAULT 0,
          usage_missing INTEGER NOT NULL DEFAULT 0 CHECK (usage_missing IN (0, 1)),
          created_at INTEGER NOT NULL
        );
        """
    )
    db.commit()
    return db


def telegram_request(method: str, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    request = Request(
        f"{TG_API}/{method}",
        data=body,
        headers={"Content-Type": "application/json"} if body else {},
    )
    timeout = TELEGRAM_POLL_TIMEOUT_SECONDS if method == "getUpdates" else TELEGRAM_REQUEST_TIMEOUT_SECONDS
    with urlopen(request, timeout=timeout) as response:
        result = json.load(response)
    if not result.get("ok"):
        raise RuntimeError(f"Telegram {method} failed")
    return result["result"]


def escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def render_metrics(db: sqlite3.Connection) -> str:
    lines = [
        "# HELP gdc_telegram_bot_up Whether the Telegram consumer process is running",
        "# TYPE gdc_telegram_bot_up gauge",
        "gdc_telegram_bot_up 1",
        "# HELP gdc_telegram_bot_unique_users Number of distinct Telegram users by current Premium state",
        "# TYPE gdc_telegram_bot_unique_users gauge",
    ]
    premium_counts = {int(row["is_premium"]): int(row["count"]) for row in db.execute(
        "SELECT is_premium, count(*) AS count FROM users GROUP BY is_premium"
    )}
    for premium in (0, 1):
        lines.append(
            f'gdc_telegram_bot_unique_users{{premium="{str(bool(premium)).lower()}"}} {premium_counts.get(premium, 0)}'
        )
    lines.extend([
        "# HELP gdc_telegram_bot_conversations Number of durable conversation records",
        "# TYPE gdc_telegram_bot_conversations gauge",
        f"gdc_telegram_bot_conversations {db.execute('SELECT count(*) FROM conversations').fetchone()[0]}",
        "# HELP gdc_telegram_bot_interactions_total Telegram user interactions by kind, outcome and Premium state",
        "# TYPE gdc_telegram_bot_interactions_total counter",
    ])
    for row in db.execute(
        "SELECT kind, outcome, is_premium, count(*) AS count FROM interactions GROUP BY kind, outcome, is_premium"
    ):
        lines.append(
            'gdc_telegram_bot_interactions_total'
            f'{{kind="{escape_label(row["kind"])}",outcome="{escape_label(row["outcome"])}",'
            f'premium="{str(bool(row["is_premium"])).lower()}"}} {row["count"]}'
        )
    lines.extend([
        "# HELP gdc_telegram_bot_inference_requests_total Inference requests made by the Telegram consumer",
        "# TYPE gdc_telegram_bot_inference_requests_total counter",
    ])
    for row in db.execute(
        "SELECT model, outcome, count(*) AS count FROM inference_events GROUP BY model, outcome"
    ):
        lines.append(
            'gdc_telegram_bot_inference_requests_total'
            f'{{model="{escape_label(row["model"])}",outcome="{escape_label(row["outcome"])}"}} {row["count"]}'
        )
    lines.extend([
        "# HELP gdc_telegram_bot_tokens_total Exact tokens reported by successful gateway responses",
        "# TYPE gdc_telegram_bot_tokens_total counter",
    ])
    for row in db.execute(
        "SELECT model, sum(input_tokens) AS input_tokens, sum(output_tokens) AS output_tokens "
        "FROM inference_events GROUP BY model"
    ):
        model = escape_label(row["model"])
        lines.append(f'gdc_telegram_bot_tokens_total{{direction="input",model="{model}"}} {row["input_tokens"] or 0}')
        lines.append(f'gdc_telegram_bot_tokens_total{{direction="output",model="{model}"}} {row["output_tokens"] or 0}')
    lines.extend([
        "# HELP gdc_telegram_bot_usage_missing_total Successful responses without exact token usage",
        "# TYPE gdc_telegram_bot_usage_missing_total counter",
    ])
    for row in db.execute(
        "SELECT model, sum(usage_missing) AS count FROM inference_events GROUP BY model"
    ):
        lines.append(
            f'gdc_telegram_bot_usage_missing_total{{model="{escape_label(row["model"])}"}} {row["count"] or 0}'
        )
    last_success = db.execute(
        "SELECT max(created_at) FROM inference_events WHERE outcome = 'success'"
    ).fetchone()[0] or 0
    lines.extend([
        "# HELP gdc_telegram_bot_last_success_timestamp_seconds Unix time of the last successful inference",
        "# TYPE gdc_telegram_bot_last_success_timestamp_seconds gauge",
        f"gdc_telegram_bot_last_success_timestamp_seconds {last_success}",
    ])
    return "\n".join(lines) + "\n"


def publish_metrics(db: sqlite3.Connection) -> None:
    METRICS_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = METRICS_FILE.with_suffix(".tmp")
    temporary.write_text(render_metrics(db))
    temporary.chmod(0o644)
    temporary.replace(METRICS_FILE)


def health_payload(db: sqlite3.Connection) -> dict:
    last_success = db.execute(
        "SELECT max(created_at) FROM inference_events WHERE outcome = 'success'"
    ).fetchone()[0] or 0
    age = max(0, now() - last_success) if last_success else None
    return {
        "status": "ok",
        "inference_ready": age is not None and age <= HEALTH_MAX_AGE_SECONDS,
        "last_success_timestamp": last_success or None,
        "last_success_age_seconds": age,
    }


def upsert_user(db: sqlite3.Connection, telegram_id: int, is_premium: bool) -> None:
    timestamp = now()
    db.execute(
        "INSERT INTO users (telegram_id, is_premium, first_seen, last_seen) VALUES (?, ?, ?, ?) "
        "ON CONFLICT(telegram_id) DO UPDATE SET is_premium = excluded.is_premium, last_seen = excluded.last_seen",
        (telegram_id, int(is_premium), timestamp, timestamp),
    )
    db.commit()


def record_interaction(db: sqlite3.Connection, telegram_id: int, kind: str, outcome: str, is_premium: bool) -> None:
    db.execute(
        "INSERT INTO interactions (telegram_id, kind, outcome, is_premium, created_at) VALUES (?, ?, ?, ?, ?)",
        (telegram_id, kind, outcome, int(is_premium), now()),
    )
    db.commit()
    publish_metrics(db)


def create_conversation(db: sqlite3.Connection, telegram_id=None) -> str:
    timestamp = now()
    conversation_id = f"conv_gdc_{secrets.token_hex(12)}"
    if telegram_id is not None:
        existing = db.execute(
            "SELECT conversation_id FROM conversations WHERE telegram_id = ?", (telegram_id,)
        ).fetchone()
        if existing:
            return existing["conversation_id"]
    db.execute(
        "INSERT INTO conversations (conversation_id, telegram_id, created_at, updated_at) VALUES (?, ?, ?, ?)",
        (conversation_id, telegram_id, timestamp, timestamp),
    )
    db.commit()
    publish_metrics(db)
    return conversation_id


def reset_user_conversation(db: sqlite3.Connection, telegram_id: int) -> str:
    existing = db.execute(
        "SELECT conversation_id FROM conversations WHERE telegram_id = ?", (telegram_id,)
    ).fetchone()
    if existing:
        db.execute("DELETE FROM messages WHERE conversation_id = ?", (existing["conversation_id"],))
        db.execute("DELETE FROM conversations WHERE conversation_id = ?", (existing["conversation_id"],))
        db.commit()
    return create_conversation(db, telegram_id)


def bounded_history(db: sqlite3.Connection, conversation_id: str):
    rows = list(db.execute(
        "SELECT role, content FROM messages WHERE conversation_id = ? ORDER BY id DESC LIMIT ?",
        (conversation_id, MAX_HISTORY_MESSAGES),
    ))
    rows.reverse()
    selected = []
    size = 0
    for row in reversed(rows):
        content = row["content"]
        if selected and size + len(content) > MAX_HISTORY_CHARS:
            break
        selected.append({"role": row["role"], "content": content})
        size += len(content)
    selected.reverse()
    return selected


def record_inference(db: sqlite3.Connection, outcome: str, usage=None) -> None:
    usage = usage if isinstance(usage, dict) else {}
    input_tokens = usage.get("prompt_tokens")
    output_tokens = usage.get("completion_tokens")
    total_tokens = usage.get("total_tokens")
    complete = all(isinstance(value, int) and value >= 0 for value in (input_tokens, output_tokens))
    db.execute(
        "INSERT INTO inference_events "
        "(model, outcome, input_tokens, output_tokens, total_tokens, usage_missing, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (
            MODEL,
            outcome,
            input_tokens if complete else 0,
            output_tokens if complete else 0,
            total_tokens if complete and isinstance(total_tokens, int) and total_tokens >= 0 else 0,
            0 if outcome != "success" or complete else 1,
            now(),
        ),
    )
    db.commit()
    publish_metrics(db)


def gateway_completion(db: sqlite3.Connection, conversation_id: str, input_text: str):
    conversation = db.execute(
        "SELECT conversation_id FROM conversations WHERE conversation_id = ?", (conversation_id,)
    ).fetchone()
    if not conversation:
        raise ValueError("conversation not found")
    messages = bounded_history(db, conversation_id)
    messages.append({"role": "user", "content": input_text})
    body = json.dumps({
        "model": MODEL,
        "messages": messages,
        "max_tokens": MAX_OUTPUT_TOKENS,
        "temperature": 0.2,
    }).encode()
    deadline_ms = str(int(time.time() * 1000) + GATEWAY_TIMEOUT_SECONDS * 1000)
    request = Request(
        f"{GATEWAY_API_BASE_URL}/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {GATEWAY_API_KEY}",
            "Content-Type": "application/json",
            "X-Request-Deadline-Ms": deadline_ms,
        },
        method="POST",
    )
    try:
        with urlopen(request, timeout=GATEWAY_TIMEOUT_SECONDS) as response:
            payload = json.load(response)
    except HTTPError as error:
        admission = error.headers.get("X-GDC-Admission", "") if error.headers else ""
        if admission == "pre_dispatch_rejected":
            record_inference(db, f"pre_dispatch_http_{error.code}")
            raise RuntimeError("gateway pre dispatch rejected") from error
        record_inference(db, f"http_{error.code}")
        raise RuntimeError(f"gateway returned HTTP {error.code}") from error
    except ValueError as error:
        record_inference(db, "invalid_response")
        raise RuntimeError("gateway returned invalid JSON") from error
    except (URLError, TimeoutError, OSError) as error:
        record_inference(db, "transport_error")
        raise RuntimeError("gateway request failed") from error
    try:
        output_text = payload["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as error:
        record_inference(db, "invalid_response")
        raise RuntimeError("gateway returned an invalid completion") from error
    if not isinstance(output_text, str):
        record_inference(db, "invalid_response")
        raise RuntimeError("gateway returned an invalid completion")
    output_text = visible_output_text(output_text)
    if not output_text:
        record_inference(db, "empty_response")
        raise RuntimeError("gateway returned no user-visible completion")
    timestamp = now()
    db.executemany(
        "INSERT INTO messages (conversation_id, role, content, created_at) VALUES (?, ?, ?, ?)",
        [
            (conversation_id, "user", input_text, timestamp),
            (conversation_id, "assistant", output_text, timestamp),
        ],
    )
    db.execute("UPDATE conversations SET updated_at = ? WHERE conversation_id = ?", (timestamp, conversation_id))
    db.commit()
    usage = payload.get("usage")
    record_inference(db, "success", usage)
    response_usage = {}
    if isinstance(usage, dict):
        response_usage = {
            "input_tokens": usage.get("prompt_tokens"),
            "output_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
        }
    return {
        "id": f"resp_gdc_{secrets.token_hex(12)}",
        "object": "response",
        "status": "completed",
        "conversation": {"id": conversation_id},
        "model": MODEL,
        "output": [{
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": output_text}],
        }],
        "output_text": output_text,
        "usage": response_usage,
    }


class ConversationAPIHandler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def send_json(self, status: int, payload) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authenticated(self) -> bool:
        return self.headers.get("Authorization") == f"Bearer {INTERNAL_API_TOKEN}"

    def do_GET(self):
        if self.path == "/health":
            with connection() as db:
                payload = health_payload(db)
            self.send_json(200, payload)
            return
        if self.path == "/metrics":
            with connection() as db:
                body = render_metrics(db).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if not self.authenticated():
            self.send_json(401, {"error": {"message": "unauthorized"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            with connection() as db:
                if self.path == "/v1/conversations":
                    telegram_id = payload.get("telegram_user_id")
                    if telegram_id is not None and not isinstance(telegram_id, int):
                        raise ValueError("telegram_user_id must be an integer")
                    conversation_id = create_conversation(db, telegram_id)
                    self.send_json(200, {
                        "id": conversation_id,
                        "object": "conversation",
                        "created_at": now(),
                        "metadata": {},
                    })
                    return
                if self.path == "/v1/responses":
                    conversation_id = payload.get("conversation")
                    input_text = payload.get("input")
                    if not isinstance(conversation_id, str) or not isinstance(input_text, str):
                        raise ValueError("conversation and input are required")
                    self.send_json(200, gateway_completion(db, conversation_id, input_text))
                    return
            self.send_json(404, {"error": {"message": "not found"}})
        except ValueError as error:
            self.send_json(400, {"error": {"message": str(error)}})
        except RuntimeError as error:
            self.send_json(502, {"error": {"message": str(error)}})
        except (json.JSONDecodeError, OSError):
            self.send_json(400, {"error": {"message": "invalid request"}})


def internal_api_request(path: str, payload):
    request = Request(
        f"{INTERNAL_API_BASE_URL}{path}",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {INTERNAL_API_TOKEN}", "Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request, timeout=INTERNAL_API_TIMEOUT_SECONDS) as response:
        return json.load(response)


def conversation_for_user(db: sqlite3.Connection, telegram_id: int) -> str:
    existing = db.execute(
        "SELECT conversation_id FROM conversations WHERE telegram_id = ?", (telegram_id,)
    ).fetchone()
    if existing:
        return existing["conversation_id"]
    return internal_api_request("/v1/conversations", {"telegram_user_id": telegram_id})["id"]


def split_telegram_text(text: str):
    for start in range(0, len(text), 4000):
        yield text[start:start + 4000]


def send_message(chat_id: int, text: str) -> None:
    for part in split_telegram_text(text):
        telegram_request("sendMessage", {"chat_id": chat_id, "text": part})


def send_typing(chat_id: int) -> None:
    telegram_request("sendChatAction", {"chat_id": chat_id, "action": "typing"})


@contextmanager
def typing_indicator(chat_id: int):
    """Keep Telegram's transient typing signal visible while inference runs."""
    stopped = threading.Event()

    def refresh() -> None:
        while not stopped.wait(TYPING_REFRESH_SECONDS):
            try:
                send_typing(chat_id)
            except Exception as error:
                print(f"typing indicator failed: {type(error).__name__}", flush=True)

    try:
        try:
            send_typing(chat_id)
        except Exception as error:
            print(f"typing indicator failed: {type(error).__name__}", flush=True)
        worker = threading.Thread(target=refresh, daemon=True)
        worker.start()
        yield
    finally:
        stopped.set()


def handle(db: sqlite3.Connection, update) -> None:
    message = update.get("message") or {}
    chat = message.get("chat") or {}
    user = message.get("from") or {}
    raw_text = message.get("text")
    chat_id, user_id = chat.get("id"), user.get("id")
    if not chat_id or not user_id or chat.get("type") != "private":
        return
    is_premium = user.get("is_premium") is True
    upsert_user(db, user_id, is_premium)
    if not isinstance(raw_text, str):
        send_message(chat_id, "Please send a text message to run inference.")
        record_interaction(db, user_id, "message", "rejected", is_premium)
        return
    text = raw_text.strip()
    command = text.split(maxsplit=1)[0].lower() if text.startswith("/") else ""
    if command in ("/start", "/help"):
        send_message(chat_id, "Send a message to run chain-accounted inference. Use /new to start a new conversation.")
        record_interaction(db, user_id, "command", "success", is_premium)
        return
    if command == "/new":
        reset_user_conversation(db, user_id)
        send_message(chat_id, "Started a new conversation.")
        record_interaction(db, user_id, "command", "success", is_premium)
        return
    if command:
        send_message(chat_id, "Unknown command. Use /new to start a new conversation or send a message.")
        record_interaction(db, user_id, "command", "rejected", is_premium)
        return
    if not text or len(text) > MAX_USER_MESSAGE_CHARS:
        send_message(chat_id, f"Message must contain between 1 and {MAX_USER_MESSAGE_CHARS} characters.")
        record_interaction(db, user_id, "message", "rejected", is_premium)
        return
    try:
        with typing_indicator(chat_id):
            conversation_id = conversation_for_user(db, user_id)
            result = internal_api_request("/v1/responses", {"conversation": conversation_id, "input": text})
        reply = result["output_text"]
        outcome = "success"
    except Exception as error:
        print(f"inference request failed: {type(error).__name__}", flush=True)
        reply = "Inference is temporarily unavailable, please try again later."
        outcome = "error"
    try:
        send_message(chat_id, reply)
    except Exception as error:
        # Telegram itself can be unavailable; retain a concise diagnostic while
        # keeping the polling loop alive for the next user message.
        print(f"Telegram reply delivery failed: {type(error).__name__}", flush=True)
        outcome = "delivery_error"
    record_interaction(db, user_id, "message", outcome, is_premium)


def run_probe() -> dict:
    # Exercise the same bounded gateway completion used by a Telegram message.
    # Calling the in-process HTTP API here would obscure the gateway error as a
    # generic 502 and make deployment diagnosis unnecessarily indirect.
    with connection() as db:
        conversation_id = create_conversation(db)
        response = gateway_completion(db, conversation_id, "Reply exactly GDC_OK")
    return {
        "status": response.get("status"),
        "conversation_id_present": bool(response.get("conversation", {}).get("id")),
        "output_present": bool(response.get("output_text")),
        "usage_present": all(isinstance(response.get("usage", {}).get(key), int) for key in ("input_tokens", "output_tokens", "total_tokens")),
    }


def main() -> None:
    with connection() as db:
        publish_metrics(db)
    server = ThreadingHTTPServer((HTTP_HOST, HTTP_PORT), ConversationAPIHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    offset = None
    with connection() as db:
        while True:
            try:
                updates = telegram_request("getUpdates", {"offset": offset, "timeout": 30, "allowed_updates": ["message"]})
                for update in updates:
                    offset = update["update_id"] + 1
                    handle(db, update)
            except Exception as error:
                print(f"retrying after bot error: {type(error).__name__}", flush=True)
                time.sleep(3)


if __name__ == "__main__":
    if sys.argv[1:] == ["--probe"]:
        try:
            print(json.dumps(run_probe(), sort_keys=True))
        except RuntimeError as error:
            reason = str(error).replace(" ", "_")[:120]
            print(json.dumps({"status": "failed", "reason": reason}, sort_keys=True))
            sys.exit(1)
        except (HTTPError, URLError, TimeoutError, ValueError, OSError) as error:
            print(json.dumps({"status": "failed", "reason": type(error).__name__.lower()}, sort_keys=True))
            sys.exit(1)
    else:
        main()
