#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("broker", root / "04-ops/bifrost-key-broker.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class Fake:
    def __init__(self): self.n = 0
    def create(self, user): self.n += 1; return {"id": f"vk-{self.n}", "value": f"sk-bf-native-{self.n}"}
    def rotate(self, key): self.n += 1; return {"id": key, "value": f"sk-bf-native-{self.n}"}

class ManagementHandler(BaseHTTPRequestHandler):
    requests = []
    def log_message(self, _format, *_args): pass
    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.__class__.requests.append((self.path, self.headers.get("Authorization"), json.loads(self.rfile.read(length))))
        value = "sk-bf-created" if self.path == "/api/governance/virtual-keys" else "sk-bf-rotated"
        body = json.dumps({"virtual_key": {"id": "vk-7", "value": value}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

server = ThreadingHTTPServer(("127.0.0.1", 0), ManagementHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
client = module.BifrostClient(f"http://127.0.0.1:{server.server_port}", "management-admin", "management-secret", "gonka", "gonka-model", "gonka-key-id")
assert client.create(77) == {"id": "vk-7", "value": "sk-bf-created"}
assert client.rotate("vk-7") == {"id": "vk-7", "value": "sk-bf-rotated"}
assert ManagementHandler.requests == [
    ("/api/governance/virtual-keys", "Basic bWFuYWdlbWVudC1hZG1pbjptYW5hZ2VtZW50LXNlY3JldA==", {"name": "telegram-a88a7902cb4ef697", "description": "Telegram user stable API key", "is_active": True, "disable_content_logging": True, "provider_configs": [{"provider": "gonka", "allowed_models": ["gonka-model"], "key_ids": ["gonka-key-id"]}]}),
    ("/api/governance/virtual-keys/vk-7/rotate", "Basic bWFuYWdlbWVudC1hZG1pbjptYW5hZ2VtZW50LXNlY3JldA==", {}),
]
try: module.BifrostClient("https://bifrost.example", "user", "password", "p", "m", "k")
except ValueError: pass
else: raise AssertionError("invalid management URL")
server.shutdown(); server.server_close()

with tempfile.TemporaryDirectory() as d:
    db_path = Path(d) / "keys.sqlite3"
    broker = module.Broker(str(db_path), Fake(), module.Fernet.generate_key())
    k1 = broker.issue(77)
    assert k1.startswith("sk-gdc-") and broker.resolve(k1) == "sk-bf-native-1"
    try: broker.issue(77); raise AssertionError("duplicate issue")
    except ValueError: pass
    k2 = broker.rotate(77)
    assert k2.startswith("sk-gdc-") and k2 != k1 and broker.resolve(k1) is None and broker.resolve(k2) == "sk-bf-native-2"
    assert broker.resolve("sk-gdc-not-issued") is None and broker.resolve("sk-bf-native-2") is None
    assert b"sk-bf-native-2" not in db_path.read_bytes()
    k3 = broker.issue_for_update(77, 9001)
    assert broker.issue_for_update(77, 9001) == k3 and broker.resolve(k3) == "sk-bf-native-3"
    try: broker.issue_for_update(78, 9001); raise AssertionError("cross-user duplicate update")
    except RuntimeError: pass
    assert b"sk-gdc-" not in db_path.read_bytes()
    server = module.serve(broker, "x" * 24, port=0, edge_token="e" * 24)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/v1/keys"
    def request(token, update):
        body = json.dumps({"telegram_id": 77, "update_id": update}).encode()
        return json.load(urlopen(Request(url, body, {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}), timeout=3))
    k4 = request("x" * 24, 9002)["key"]
    assert request("x" * 24, 9002)["key"] == k4
    try: request("wrong", 9003); raise AssertionError("unauthenticated broker request")
    except HTTPError as error: assert error.code == 401
    resolve_url = f"http://127.0.0.1:{server.server_port}/v1/resolve"
    def resolve(token, key):
        body = json.dumps({"key": key}).encode()
        return json.load(urlopen(Request(resolve_url, body, {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}), timeout=3))
    assert resolve("e" * 24, k4) == {"virtual_key": "sk-bf-native-4"}
    try: resolve("wrong", k4); raise AssertionError("unauthenticated edge resolver")
    except HTTPError as error: assert error.code == 401
    try: resolve("e" * 24, k1); raise AssertionError("revoked external key resolved")
    except HTTPError as error: assert error.code == 401
    server.shutdown(); server.server_close()

with tempfile.TemporaryDirectory() as d:
    db_path = Path(d) / "legacy.sqlite3"
    db = module.sqlite3.connect(db_path)
    db.execute("""CREATE TABLE keys (telegram_id INTEGER PRIMARY KEY, external_hash TEXT UNIQUE NOT NULL,
      bifrost_id TEXT UNIQUE NOT NULL, bifrost_value TEXT NOT NULL, created_at INTEGER NOT NULL, rotated_at INTEGER NOT NULL)""")
    db.execute("INSERT INTO keys VALUES (1, 'digest', 'vk-legacy', 'sk-bf-legacy', 1, 1)")
    db.commit(); db.close()
    key = module.Fernet.generate_key()
    module.Broker(str(db_path), Fake(), key)
    assert b"sk-bf-legacy" not in db_path.read_bytes()
print("PASS Bifrost external-key mapping issues, rotates, and revokes without storing external plaintext")
