#!/usr/bin/env python3
"""Private HTTP observation and single-dispatch transport for DevShard workload."""

import http.client
import importlib.util
import ipaddress
from pathlib import Path
import re
import socket as socketlib
import threading
import time
from urllib.parse import urlsplit


SPEC = importlib.util.spec_from_file_location("workload", Path(__file__).with_name("devshard-workload.py"))
workload = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workload)
require = workload.require
MAX_BODY = 1024 * 1024
PRIVATE = tuple(ipaddress.ip_network(value) for value in ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))


def endpoint(value):
    parsed = urlsplit(value)
    require(parsed.scheme == "http" and not parsed.username and not parsed.password and
            parsed.path in ("", "/") and not parsed.query and not parsed.fragment,
            "private HTTP base URL required")
    address = ipaddress.ip_address(parsed.hostname or "")
    require(address.version == 4 and any(address in network for network in PRIVATE),
            "literal loopback or RFC1918 address required; DNS and public routes are forbidden")
    require(parsed.port is not None and 1024 <= parsed.port <= 65535, "explicit nonprivileged port required")
    return str(address), parsed.port


def first_content(events):
    for event in events:
        try:
            data = b"\n".join(line[5:].lstrip(b" ") for line in event.splitlines() if line.startswith(b"data:"))
            if not data or data == b"[DONE]":
                continue
            value = workload.decode(data)
            if any(isinstance(choice.get("delta", {}).get("content"), str) and choice["delta"]["content"]
                   for choice in value.get("choices", [])):
                return True
        except (ValueError, TypeError, AttributeError):
            # Keep malformed bytes for the authoritative response validator.
            continue
    return False


class ObservationError(ValueError):
    """Failed observations retain their receipt for the campaign journal."""

    def __init__(self, receipt):
        super().__init__("private observation failed; retain receipt, no retry")
        self.receipt = receipt


class Transport:
    def __init__(self, endpoints, secret_files):
        require(set(endpoints) == set(secret_files) == {"A", "B"}, "two gateway bindings required")
        self.endpoints = {name: endpoint(value) for name, value in endpoints.items()}
        require(len(set(self.endpoints.values())) == 2, "A/B endpoints must differ")
        secrets = {name: workload.settings.instances.secrets(path) for name, path in secret_files.items()}
        require(not set(secrets["A"]) & set(secrets["B"]), "A/B secrets must be independent")
        self.keys = {name: {"admin": values[1], "client": values[2]} for name, values in secrets.items()}

    def connection(self, gateway):
        return http.client.HTTPConnection(*self.endpoints[gateway])

    def request_path(self, gateway, path):
        return path

    def request(self, gateway, method, path, role, deadline, wire=None, request_id=None):
        require(gateway in self.endpoints, "unknown gateway")
        require((method == "GET" and role == "admin" and path in
                 ("/v1/admin/devshards", "/v1/admin/settings", "/v1/models")) or
                (method == "POST" and role == "client" and path == "/v1/chat/completions"),
                "unsupported observation or workload operation")
        require((method == "GET" and wire is None) or (isinstance(wire, bytes) and len(wire) <= MAX_BODY),
                "invalid request body")
        require(request_id is None or (isinstance(request_id, str) and 0 < len(request_id) <= 128 and
                all(char.isascii() and (char.isalnum() or char in "-_.") for char in request_id)), "invalid request ID")
        started = time.monotonic()
        require(workload.number(deadline) and deadline > started, "request deadline already expired")
        deadline = min(deadline, started + workload.REQUEST_SECONDS)
        body, pending, ttft, status = bytearray(), b"", None, None
        complete, error, reply = False, None, None
        timer, expired = None, threading.Event()
        connection = self.connection(gateway)
        response_headers = {}

        def remaining():
            value = deadline - time.monotonic()
            if value <= 0:
                raise TimeoutError("absolute request deadline")
            return value

        try:
            connection.timeout = min(5, remaining())
            connection.connect()
            socket = connection.sock

            def interrupt():
                expired.set()
                try:
                    socket.shutdown(socketlib.SHUT_RDWR)
                except OSError:
                    pass

            # Header parsing can perform many reads; a per-read socket timeout
            # alone does not bound a peer that continuously trickles headers.
            timer = threading.Timer(remaining(), interrupt)
            timer.daemon = True
            timer.start()
            socket.settimeout(remaining())
            headers = {"Authorization": "Bearer " + self.keys[gateway][role], "Connection": "close"}
            if wire is not None:
                headers["Content-Type"] = "application/json"
            if request_id is not None:
                headers["X-Request-ID"] = request_id
            connection.request(method, self.request_path(gateway, path), body=wire, headers=headers)
            socket.settimeout(remaining())
            reply = connection.getresponse()
            status = reply.status
            response_headers = {name: reply.getheader(name) for name in ("Content-Type", "X-Devshard-Id")
                                if reply.getheader(name) is not None}
            while True:
                # Content-Length completion can close the last socket owner
                # inside read1; do not touch that descriptor again.
                if reply.isclosed():
                    require(reply.length in (None, 0), "truncated HTTP body")
                    remaining()
                    complete = True
                    break
                socket.settimeout(remaining())
                chunk = reply.read1(min(65536, MAX_BODY + 1 - len(body)))
                if not chunk:
                    require(reply.length in (None, 0), "truncated HTTP body")
                    remaining()
                    complete = True
                    break
                body.extend(chunk)
                require(len(body) <= MAX_BODY, "response body limit exceeded")
                if ttft is None and wire is not None:
                    pending = (pending + chunk).replace(b"\r\n", b"\n")
                    *events, pending = pending.split(b"\n\n")
                    if first_content(events):
                        ttft = time.monotonic() - started
        except (Exception, KeyboardInterrupt) as failure:
            error = type(failure).__name__
        finally:
            if timer is not None:
                timer.cancel()
                timer.join()
            if reply is not None:
                reply.close()
            connection.close()
        if expired.is_set():
            error, complete = "TimeoutError", False
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            text = body.decode("utf-8", errors="replace")
            error, complete = "UnicodeDecodeError", False
        return {"http_status": status, "body": text, "body_complete": complete,
                "body_hex": bytes(body).hex() if error == "UnicodeDecodeError" else None,
                "transport_error": error, "elapsed_seconds": time.monotonic() - started,
                "ttft_seconds": ttft, "response_headers": response_headers}

    def send(self, gateway, wire, deadline, request_id):
        return self.request(gateway, "POST", "/v1/chat/completions", "client", deadline, wire, request_id)

    def observe(self, gateway, path, deadline):
        result = self.request(gateway, "GET", path, "admin", deadline)
        receipt = {"gateway": gateway, "path": path, "response": result}
        if not result["body_complete"] or result["transport_error"] is not None or result["http_status"] != 200:
            raise ObservationError(receipt)
        try:
            return {**receipt, "value": workload.decode(result["body"])}
        except (ValueError, TypeError) as error:
            raise ObservationError(receipt) from error


class PublicTransport(Transport):
    """Explicit TLS client-only ingress; never send admin credentials outside."""

    def __init__(self, endpoints, secret_files):
        require(set(endpoints) == set(secret_files) == {"A", "B"}, "two gateway bindings required")
        self.endpoints, self.prefixes, self.keys = {}, {}, {}
        for name, value in endpoints.items():
            parsed = urlsplit(value)
            require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
                    and not parsed.query and not parsed.fragment and
                    re.fullmatch(r"(?:/[A-Za-z0-9_-]+)*", parsed.path) is not None,
                    "explicit HTTPS client base URL required")
            self.endpoints[name] = (parsed.hostname, parsed.port or 443)
            self.prefixes[name] = parsed.path
            key = workload.settings.instances.private_file(secret_files[name]).read_text().strip()
            require(re.fullmatch(r"[A-Za-z0-9_.:-]{24,256}", key) is not None,
                    "public transport requires a client-only token file, not gateway credentials")
            self.keys[name] = {"client": key}
        require(len({(*self.endpoints[name], self.prefixes[name]) for name in self.endpoints}) == 2,
                "A/B endpoints must differ")
        require(self.keys["A"]["client"] != self.keys["B"]["client"], "distinct A/B client keys required")

    def connection(self, gateway):
        return http.client.HTTPSConnection(*self.endpoints[gateway])

    def request_path(self, gateway, path):
        return self.prefixes[gateway] + path

    def request(self, gateway, method, path, role, deadline, wire=None, request_id=None):
        require(method == "POST" and role == "client" and path == "/v1/chat/completions",
                "public transport only accepts client completions")
        return super().request(gateway, method, path, role, deadline, wire, request_id)
