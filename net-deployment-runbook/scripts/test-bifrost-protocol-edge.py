#!/usr/bin/env python3
"""Exercise stable key translation with independent loopback fixtures."""
import importlib.util
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("edge", root / "04-ops/bifrost-protocol-edge.py")
edge = importlib.util.module_from_spec(spec); spec.loader.exec_module(edge)

class BrokerHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args): pass
    def do_POST(self):
        assert self.path == "/v1/resolve"
        assert self.headers.get("Authorization") == "Bearer " + "e" * 24
        key = json.loads(self.rfile.read(int(self.headers["Content-Length"]))).get("key")
        if key != "sk-gdc-valid": self.send_error(401); return
        body = json.dumps({"virtual_key": "sk-bf-private"}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

class UpstreamHandler(BaseHTTPRequestHandler):
    requests = []
    def log_message(self, *_args): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.__class__.requests.append((self.path, dict(self.headers), body))
        reply = b'{"ok":true}'
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(reply))); self.end_headers(); self.wfile.write(reply)

broker = ThreadingHTTPServer(("127.0.0.1", 0), BrokerHandler)
upstream = ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
for service in (broker, upstream): threading.Thread(target=service.serve_forever, daemon=True).start()
server = edge.serve("127.0.0.1", 0, f"http://127.0.0.1:{broker.server_port}", "e" * 24, f"http://127.0.0.1:{upstream.server_port}")
threading.Thread(target=server.serve_forever, daemon=True).start()

def request(path, headers):
    return urlopen(Request(f"http://127.0.0.1:{server.server_port}{path}", b'{"model":"gonka"}', headers), timeout=3).read()

for path, headers in (
    ("/v1/chat/completions", {"Authorization": "Bearer sk-gdc-valid", "Content-Type": "application/json"}),
    ("/anthropic/v1/messages", {"x-api-key": "sk-gdc-valid", "Content-Type": "application/json"}),
    ("/genai/v1beta/models", {"x-goog-api-key": "sk-gdc-valid", "Content-Type": "application/json"}),
): assert json.loads(request(path, headers)) == {"ok": True}

assert len(UpstreamHandler.requests) == 3
for path, headers, body in UpstreamHandler.requests:
    assert path.startswith(("/v1/", "/anthropic/", "/genai/")) and body == b'{"model":"gonka"}'
    assert headers.get("x-bf-vk") == "sk-bf-private"
    assert not any(headers.get(name) for name in ("Authorization", "x-api-key", "x-goog-api-key", "api-key"))

def denied(path, headers, expected):
    try: request(path, headers); raise AssertionError("edge accepted invalid credentials")
    except HTTPError as error: assert error.code == expected

denied("/v1/chat/completions", {"Authorization": "Bearer sk-gdc-missing", "Content-Type": "application/json"}, 401)
denied("/v1/chat/completions", {"Authorization": "Bearer sk-bf-private", "Content-Type": "application/json"}, 403)
denied("/v1/chat/completions", {"Authorization": "Bearer sk-gdc-valid", "x-api-key": "sk-gdc-valid", "Content-Type": "application/json"}, 400)
denied("/genai/v1beta/models", {"x-goog-api-key": "sk-gdc-valid", "x-bf-vk": "sk-bf-private", "Content-Type": "application/json"}, 400)
assert len(UpstreamHandler.requests) == 3
for service in (server, broker, upstream): service.shutdown(); service.server_close()
print("PASS stable protocol edge maps only sk-gdc credentials and strips native-key bypass headers")
