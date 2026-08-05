#!/usr/bin/env python3
"""Minimal long-polling Telegram API-key issuer; uses only the Python stdlib."""
import json, os, sqlite3, time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
API_BASE_URL = os.environ.get("API_BASE_URL", "https://api.gonka-dev.net/v1")
POOL_FILE = Path(os.environ["KEY_POOL_FILE"])
DB_FILE = Path(os.environ.get("STATE_DB", "/data/bot.sqlite3"))
MAX_KEY_VALIDATION_ATTEMPTS = 3
TG_API = f"https://api.telegram.org/bot{TOKEN}"

def request(method, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    req = Request(f"{TG_API}/{method}", data=body, headers={"Content-Type": "application/json"} if body else {})
    with urlopen(req, timeout=35) as response:
        result = json.load(response)
    if not result.get("ok"):
        raise RuntimeError(f"Telegram {method} failed")
    return result["result"]

def connection():
    DB_FILE.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB_FILE)
    db.execute("CREATE TABLE IF NOT EXISTS keys (telegram_id INTEGER PRIMARY KEY, api_key TEXT NOT NULL UNIQUE, issued_at INTEGER NOT NULL)")
    return db

def load_pool():
    pool = json.loads(POOL_FILE.read_text())
    keys = pool.get("keys")
    if not isinstance(keys, list) or not keys or not all(isinstance(key, str) and key.startswith("sk-gdc-") for key in keys):
        raise RuntimeError("invalid key pool")
    return keys

def key_works(key):
    """Accept only a key that passes the actual authenticated chat contract."""
    body = json.dumps({
        "model": "Qwen/Qwen3-0.6B",
        "messages": [{"role": "user", "content": "Reply with OK"}],
        "max_tokens": 1,
        "temperature": 0,
    }).encode()
    request = Request(
        f"{API_BASE_URL.rstrip('/')}/chat/completions",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=15) as response:
            if response.status != 200:
                return False
            payload = json.load(response)
    except HTTPError:
        return False
    except (URLError, TimeoutError, ValueError, OSError):
        return False
    return isinstance(payload.get("choices"), list) and bool(payload["choices"])

def issue(db, telegram_id, renew=False):
    row = db.execute("SELECT api_key FROM keys WHERE telegram_id = ?", (telegram_id,)).fetchone()
    if row and not renew and key_works(row[0]):
        return row[0], False
    used = {row[0] for row in db.execute("SELECT api_key FROM keys")}
    candidates = (item for item in load_pool() if item not in used)
    key = next((item for _, item in zip(range(MAX_KEY_VALIDATION_ATTEMPTS), candidates) if key_works(item)), None)
    if not key:
        return None, False
    if row:
        # Replace an invalid key, or rotate it after an explicit /renew.
        db.execute("UPDATE keys SET api_key = ?, issued_at = ? WHERE telegram_id = ?", (key, int(time.time()), telegram_id))
    else:
        db.execute("INSERT INTO keys (telegram_id, api_key, issued_at) VALUES (?, ?, ?)", (telegram_id, key, int(time.time())))
    db.commit()
    return key, True

def handle(db, update):
    message = update.get("message") or {}
    chat = message.get("chat") or {}
    user = message.get("from") or {}
    text = (message.get("text") or "").strip().split(maxsplit=1)[0].lower()
    chat_id, user_id = chat.get("id"), user.get("id")
    if not chat_id or not user_id or chat.get("type") != "private":
        return
    if text in ("/start", "/help"):
        reply = "Use /key to receive your personal Gonka DevNet API key. Use /renew to replace it. One active key is assigned per Telegram account."
    elif text == "/key":
        key, created = issue(db, user_id)
        if not key:
            reply = "The test key pool is exhausted. Please try again later."
        else:
            state = "Issued" if created else "Your existing"
            reply = f"{state} API key:\n\n`{key}`\n\nUse it with {API_BASE_URL}/chat/completions as a Bearer token. Keep it private."
    elif text == "/renew":
        key, created = issue(db, user_id, renew=True)
        if not key:
            reply = "no verified replacement key is available, please try again later"
        else:
            reply = f"Renewed API key:\n\n`{key}`\n\nUse it with {API_BASE_URL}/chat/completions as a Bearer token. Keep it private."
    else:
        reply = "Use /key to receive an API key, /renew to replace it, or /help for details."
    request("sendMessage", {"chat_id": chat_id, "text": reply, "parse_mode": "Markdown"})

def main():
    offset = None
    db = connection()
    while True:
        try:
            updates = request("getUpdates", {"offset": offset, "timeout": 30, "allowed_updates": ["message"]})
            for update in updates:
                offset = update["update_id"] + 1
                handle(db, update)
        except Exception as error:
            print(f"retrying after bot error: {error}", flush=True)
            time.sleep(3)

if __name__ == "__main__":
    main()
