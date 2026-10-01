#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys

count = Path(sys.argv[1]); port = int(sys.argv[2])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        count.write_text(str(int(count.read_text() or "0") + 1))
        body = json.dumps({"virtual_key": {"id": "vk", "value": "sk-bf-test"}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
HTTPServer(("127.0.0.1", port), Handler).serve_forever()
