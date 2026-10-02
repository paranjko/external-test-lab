#!/usr/bin/env python3
"""Public stable-protocol edge: translate only verified sk-gdc keys to Bifrost virtual keys."""
import http.client
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"}
SECRET_HEADERS = {"authorization", "x-api-key", "x-goog-api-key", "api-key", "x-bf-vk"}


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"{name} is required")
    return value


def loopback_url(value, name):
    parsed = urlsplit(value)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "::1"} or parsed.path not in {"", "/"}:
        raise ValueError(f"{name} must be a loopback HTTP origin")
    return parsed


class EdgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def _reject(self, status):
        self.send_response(status); self.send_header("Content-Length", "0"); self.send_header("Connection", "close"); self.end_headers()

    def _external_key(self):
        path = urlsplit(self.path).path
        if path.startswith("/v1/"):
            expected = self.headers.get("Authorization", "")
            if not expected.startswith("Bearer "):
                return None
            key = expected[7:]
        elif path.startswith("/anthropic/"):
            key = self.headers.get("x-api-key", "")
        elif path.startswith("/genai/"):
            key = self.headers.get("x-goog-api-key", "")
        else:
            return None
        if key.startswith("sk-bf-"):
            raise PermissionError("native Bifrost credentials are never public")
        if not key.startswith("sk-gdc-"):
            return None
        for header in SECRET_HEADERS:
            value = self.headers.get(header, "")
            if header not in {"authorization" if path.startswith("/v1/") else "x-api-key" if path.startswith("/anthropic/") else "x-goog-api-key"} and value:
                raise ValueError("conflicting credential header")
            if value.startswith("sk-bf-"):
                raise PermissionError("native Bifrost credentials are never public")
        return key

    def _resolve(self, external):
        request = Request(self.server.broker_url + "/v1/resolve", data=json.dumps({"key": external}).encode(), headers={
            "Authorization": f"Bearer {self.server.edge_token}", "Content-Type": "application/json",
        }, method="POST")
        try:
            with urlopen(request, timeout=5) as response:
                body = json.load(response)
        except (HTTPError, URLError, OSError, ValueError, json.JSONDecodeError):
            return None
        value = body.get("virtual_key") if isinstance(body, dict) else None
        return value if isinstance(value, str) and value.startswith("sk-bf-") else None

    def _proxy(self, native):
        length = self.headers.get("Content-Length", "0")
        if self.headers.get("Transfer-Encoding"):
            raise ValueError("requests require a bounded Content-Length")
        length = int(length)
        if length < 0 or length > self.server.max_body:
            raise ValueError("invalid request size")
        body = self.rfile.read(length)
        headers = {name: value for name, value in self.headers.items()
                   if name.lower() not in HOP_BY_HOP | SECRET_HEADERS | {"host", "content-length"}}
        headers.update({"Host": self.server.upstream.netloc, "Content-Length": str(len(body)), "x-bf-vk": native})
        connection = http.client.HTTPConnection(self.server.upstream.hostname, self.server.upstream.port, timeout=60)
        try:
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in HOP_BY_HOP | {"content-length"}:
                    self.send_header(name, value)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            if self.command != "HEAD":
                while chunk := response.read(65536):
                    self.wfile.write(f"{len(chunk):X}\r\n".encode() + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
        finally:
            connection.close()

    def _handle(self):
        try:
            external = self._external_key()
            if external is None:
                self._reject(401); return
            native = self._resolve(external)
            if native is None:
                self._reject(401); return
            self._proxy(native)
        except PermissionError:
            self._reject(403)
        except ValueError:
            self._reject(400)
        except (http.client.HTTPException, OSError):
            self._reject(502)

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_DELETE = _handle
    do_PATCH = _handle


def serve(host, port, broker_url, edge_token, upstream_url, max_body=32 * 1024 * 1024):
    if not isinstance(edge_token, str) or len(edge_token) < 24:
        raise ValueError("edge token must have at least 24 characters")
    broker = loopback_url(broker_url, "BIFROST_EDGE_BROKER_URL")
    upstream = loopback_url(upstream_url, "BIFROST_EDGE_UPSTREAM_URL")
    if not isinstance(max_body, int) or max_body <= 0:
        raise ValueError("max body must be positive")
    server = ThreadingHTTPServer((host, port), EdgeHandler)
    server.broker_url, server.edge_token, server.upstream, server.max_body = broker.geturl().rstrip("/"), edge_token, upstream, max_body
    return server


if __name__ == "__main__":
    serve(required("BIFROST_EDGE_HOST"), int(required("BIFROST_EDGE_PORT")), required("BIFROST_EDGE_BROKER_URL"),
          required("BIFROST_EDGE_TOKEN"), required("BIFROST_EDGE_UPSTREAM_URL"), int(os.environ.get("BIFROST_EDGE_MAX_BODY", str(32 * 1024 * 1024)))).serve_forever()
