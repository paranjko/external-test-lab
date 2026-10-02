#!/usr/bin/env python3
"""Loopback-only OpenAI-shaped upstream for pinned Bifrost adapter tests."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        # This fixture deliberately accepts the adapter's provider request and
        # returns one OpenAI completion; caller assertions prove each returned
        # public protocol is transformed back to its native response shape.
        if not isinstance(body, dict):
            self.send_error(400, "Bifrost provider request must be JSON")
            return
        response = json.dumps({
            "id": "fixture", "object": "chat.completion", "created": 1, "model": "test-model",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "fixture-ok"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response))); self.end_headers(); self.wfile.write(response)


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
