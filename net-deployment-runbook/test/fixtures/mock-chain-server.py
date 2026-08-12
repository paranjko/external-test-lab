#!/usr/bin/env python3
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/status":
            self.send_error(404)
            return
        payload = json.dumps({"result": {"sync_info": {"catching_up": False}}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        return


class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


ReusableHTTPServer(("127.0.0.1", 26657), Handler).serve_forever()
