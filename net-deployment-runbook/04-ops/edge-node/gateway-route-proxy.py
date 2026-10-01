#!/usr/bin/env python3
"""Bounded A/B edge proxy with route-only counters and JSON error MIME repair."""
import http.client
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit("%s is required" % name)
    return value


HOST = os.environ.get("GDC_GATEWAY_ROUTE_PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("GDC_GATEWAY_ROUTE_PROXY_PORT", "18085"))
ROUTE = required("GDC_GATEWAY_ROUTE_ID")
UPSTREAM = urlsplit(required("GDC_GATEWAY_ROUTE_UPSTREAM"))
MAX_ERROR_BODY = int(os.environ.get("GDC_GATEWAY_ROUTE_PROXY_MAX_ERROR_BODY_BYTES", "1048576"))
if not (ROUTE in {"A", "B"} and UPSTREAM.scheme == "http" and UPSTREAM.hostname
        and UPSTREAM.port and 0 < PORT <= 65535 and MAX_ERROR_BODY > 0):
    raise SystemExit("gateway route proxy configuration is invalid")

COUNTERS = {}
COUNTERS_LOCK = threading.Lock()
ALLOWED_PATHS = {"/v1/chat/completions", "/v1/models", "/v1/status", "/v1/admission-status"}


def count(outcome):
    with COUNTERS_LOCK:
        COUNTERS[outcome] = COUNTERS.get(outcome, 0) + 1


def metrics():
    with COUNTERS_LOCK:
        rows = ["# TYPE gdc_gateway_route_requests_total counter"]
        rows.extend('gdc_gateway_route_requests_total{route="%s",outcome="%s"} %s' %
                    (ROUTE, outcome, COUNTERS[outcome]) for outcome in sorted(COUNTERS))
    return ("\n".join(rows) + "\n").encode()


def valid_json_error(payload):
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return False
    return isinstance(value, dict) and isinstance(value.get("error"), (dict, str))


class Handler(BaseHTTPRequestHandler):
    server_version = "GonkaRoute/1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/metrics":
            payload = metrics()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers(); self.wfile.write(payload)
            return
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        path = self.path.split("?", 1)[0]
        if path not in ALLOWED_PATHS:
            self.send_error(404); count("closed"); return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > MAX_ERROR_BODY:
                raise ValueError
        except ValueError:
            self.send_error(400); count("bad_request"); return
        body = self.rfile.read(length)
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in {"connection", "host", "content-length"}}
        headers["Host"] = UPSTREAM.netloc
        try:
            connection = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port, timeout=30)
            connection.request(self.command, self.path, body, headers)
            response = connection.getresponse()
            status = response.status
            # Errors are bounded and inspected before headers so an upstream that
            # labels a JSON error as text/plain is corrected without relabelling text.
            payload = response.read(MAX_ERROR_BODY + 1) if status >= 400 else None
            if payload is not None and len(payload) > MAX_ERROR_BODY:
                raise ValueError("upstream error body exceeds bound")
            self.send_response(status)
            content_type = response.getheader("Content-Type")
            if payload is not None and valid_json_error(payload):
                content_type = "application/json"
            for key, value in response.getheaders():
                if key.lower() not in {"connection", "transfer-encoding", "content-length", "content-type"}:
                    self.send_header(key, value)
            if content_type:
                self.send_header("Content-Type", content_type)
            if payload is not None:
                self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if payload is not None:
                self.wfile.write(payload)
            else:
                while True:
                    chunk = response.read(65536)
                    if not chunk: break
                    self.wfile.write(chunk); self.wfile.flush()
            count("%dxx" % (status // 100))
        except (OSError, http.client.HTTPException, ValueError):
            self.send_error(502); count("transport_error")
        finally:
            try: connection.close()
            except UnboundLocalError: pass


ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
