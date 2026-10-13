#!/usr/bin/env python3
"""Bounded HTTP and WebSocket adapter for cached network observations.

The collector remains the authority for request validation, per-chain cache
selection, observation queueing, and response semantics. This process only
adds a persistent WebSocket transport around the same read-only interface.
"""

import base64
import hashlib
import json
import os
import re
import socket
import subprocess
import time
from urllib.parse import urlsplit


COLLECTOR = os.environ.get(
    "GDC_NETWORK_OBSERVER_COLLECTOR", "/usr/local/lib/gonka-devnet/network-observer.sh"
)
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CHAIN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
MAX_HEADER_BYTES = 16384
MAX_FRAME_BYTES = 125
WEBSOCKET_LIFETIME_SECONDS = 300
SNAPSHOT_INTERVAL_SECONDS = 5
FRAME_READ_TIMEOUT_SECONDS = 5
SINGLETON_HEADERS = {
    "host",
    "origin",
    "sec-websocket-key",
    "sec-websocket-version",
    "x-forwarded-host",
}


class IncompleteFrame(Exception):
    pass


def read_request(stream):
    data = bytearray()
    deadline = time.monotonic() + 5.0
    while b"\r\n\r\n" not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        stream.settimeout(min(5.0, remaining))
        chunk = stream.recv(2048)
        if not chunk:
            return None
        data.extend(chunk)
        if len(data) > MAX_HEADER_BYTES:
            return None
    head, trailing = bytes(data).split(b"\r\n\r\n", 1)
    if trailing:
        return None
    try:
        lines = head.decode("ascii").split("\r\n")
        method, target, version = lines[0].split(" ")
    except (UnicodeDecodeError, ValueError):
        return None
    if version not in ("HTTP/1.0", "HTTP/1.1"):
        return None
    headers = {}
    for line in lines[1:]:
        if ":" not in line:
            return None
        key, value = line.split(":", 1)
        key = key.strip().lower()
        if not key:
            return None
        value = value.strip()
        if key in headers:
            if key != "via" or key in SINGLETON_HEADERS:
                return None
            headers[key] = f"{headers[key]}, {value}"
        else:
            headers[key] = value
    return method, target, version, headers


def collector_response(target):
    if target.startswith("/status/network/ws"):
        target = "/status/network" + target[len("/status/network/ws"):]
    request = f"GET {target} HTTP/1.1\r\nHost: local\r\n\r\n".encode("ascii")
    try:
        result = subprocess.run(
            ["/bin/bash", COLLECTOR, "--serve"],
            input=request,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=4,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: 43\r\n\r\n{\"error\":\"network_observation_unavailable\"}"
    return result.stdout


def respond(sock, status, body):
    reason = {
        400: "Bad Request",
        404: "Not Found",
        405: "Method Not Allowed",
        426: "Upgrade Required",
    }[status]
    payload = body.encode("utf-8")
    sock.sendall(
        f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n"
        f"Cache-Control: no-store\r\nConnection: close\r\n"
        f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii")
        + payload
    )


def parse_route(target, websocket=False):
    expected = "/status/network/ws" if websocket else "/status/network"
    try:
        parsed = urlsplit(target)
    except ValueError:
        return None
    if parsed.scheme or parsed.netloc or parsed.path != expected or parsed.fragment or parsed.query.count("&") > 0:
        return None
    if not parsed.query:
        return "/status/network/ws" if websocket else "/status/network"
    match = re.fullmatch(r"chainId=([A-Za-z0-9][A-Za-z0-9._-]{0,127})", parsed.query)
    if not match or not CHAIN_RE.fullmatch(match.group(1)):
        return None
    return f"/status/network{'/ws' if websocket else ''}?chainId={match.group(1)}"


def read_frame(sock):
    frame_started = False

    def receive_exact(size):
        nonlocal frame_started
        data = bytearray()
        deadline = time.monotonic() + FRAME_READ_TIMEOUT_SECONDS
        while len(data) < size:
            try:
                chunk = sock.recv(size - len(data))
            except socket.timeout:
                if time.monotonic() >= deadline:
                    if frame_started:
                        raise IncompleteFrame
                    raise
                continue
            if not chunk:
                return None
            frame_started = True
            data.extend(chunk)
        return bytes(data)

    head = receive_exact(2)
    if head is None or len(head) != 2:
        return None
    opcode = head[0] & 0x0F
    masked = bool(head[1] & 0x80)
    size = head[1] & 0x7F
    if size == 126:
        extra = receive_exact(2)
        if extra is None:
            return None
        size = int.from_bytes(extra, "big")
    elif size == 127:
        return None
    if size > MAX_FRAME_BYTES or not masked or not head[0] & 0x80 or head[0] & 0x70:
        return None
    mask = receive_exact(4)
    if mask is None:
        return None
    payload = receive_exact(size)
    if payload is None:
        return None
    return opcode, bytes(value ^ mask[index % 4] for index, value in enumerate(payload))


def send_frame(sock, opcode, payload):
    size = len(payload)
    if size < 126:
        header = bytes((0x80 | opcode, size))
    elif size <= 65535:
        header = bytes((0x80 | opcode, 126)) + size.to_bytes(2, "big")
    else:
        header = bytes((0x80 | opcode, 127)) + size.to_bytes(8, "big")
    sock.sendall(header + payload)


def send_snapshot(sock, body):
    try:
        snapshot = json.loads(body)
        payload = json.dumps(
            {"type": "network_snapshot", "snapshot": snapshot}, separators=(",", ":")
        ).encode("utf-8")
    except (ValueError, TypeError):
        payload = b'{"type":"network_observation_unavailable"}'
    send_frame(sock, 0x1, payload)
    return hashlib.sha256(payload).digest()


def websocket(sock, target, headers):
    route = parse_route(target, websocket=True)
    key = headers.get("sec-websocket-key", "")
    try:
        origin = urlsplit(headers["origin"]) if "origin" in headers else None
    except ValueError:
        origin = None
        invalid_origin = True
    else:
        invalid_origin = False
    forwarded_host = headers.get("x-forwarded-host", headers.get("host", "")).lower()
    if (
        route is None
        or headers.get("upgrade", "").lower() != "websocket"
        or "upgrade" not in {token.strip().lower() for token in headers.get("connection", "").split(",")}
        or headers.get("sec-websocket-version") != "13"
        or not re.fullmatch(r"[A-Za-z0-9+/]{22}==", key)
        or invalid_origin
        or (
            origin is not None
            and (origin.scheme not in ("http", "https") or origin.netloc.lower() != forwarded_host)
        )
    ):
        respond(sock, 400 if route is None else 426, '{"error":"invalid_websocket_request"}')
        return
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
    sock.sendall(
        ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
         "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode("ascii")
    )
    deadline = time.monotonic() + WEBSOCKET_LIFETIME_SECONDS
    sock.settimeout(1.0)
    response = collector_response(route)
    body = response.partition(b"\r\n\r\n")[2]
    sent_snapshot = None
    if body:
        sent_snapshot = send_snapshot(sock, body)
    next_read = time.monotonic() + SNAPSHOT_INTERVAL_SECONDS
    try:
        while True:
            now = time.monotonic()
            if now >= deadline:
                send_frame(sock, 0x8, b"\x03\xe8")
                return
            sock.settimeout(min(1.0, max(0.1, min(next_read, deadline) - now)))
            try:
                frame = read_frame(sock)
            except socket.timeout:
                if time.monotonic() >= next_read:
                    response = collector_response(route)
                    body = response.partition(b"\r\n\r\n")[2]
                    if body:
                        try:
                            payload = json.dumps(
                                {"type": "network_snapshot", "snapshot": json.loads(body)},
                                separators=(",", ":"),
                            ).encode("utf-8")
                        except (ValueError, TypeError):
                            payload = b'{"type":"network_observation_unavailable"}'
                        digest = hashlib.sha256(payload).digest()
                        if digest != sent_snapshot:
                            sent_snapshot = send_snapshot(sock, body)
                    next_read = time.monotonic() + SNAPSHOT_INTERVAL_SECONDS
                continue
            if frame is None:
                return
            opcode, payload = frame
            if opcode == 0x8:
                send_frame(sock, 0x8, payload[:125])
                return
            if opcode == 0x9:
                send_frame(sock, 0xA, payload)
            elif opcode not in (0x1, 0x2, 0xA):
                send_frame(sock, 0x8, b"\x03\xea")
                return
    except IncompleteFrame:
        try:
            send_frame(sock, 0x8, b"\x03\xea")
        except OSError:
            pass
        return
    except (BrokenPipeError, ConnectionResetError, OSError):
        return


def main():
    try:
        sock = socket.socket(fileno=0)
        sock.settimeout(5.0)
        request = read_request(sock)
        if request is None:
            respond(sock, 400, '{"error":"invalid_request"}')
            return
        method, target, _version, headers = request
        if method != "GET":
            respond(sock, 405, '{"error":"read_only"}')
            return
        if target == "/status/network/ws" or target.startswith("/status/network/ws?"):
            websocket(sock, target, headers)
            return
        route = parse_route(target)
        if route is None:
            respond(sock, 404, '{"error":"not_found"}')
            return
        sock.sendall(collector_response(route))
    except (BrokenPipeError, ConnectionResetError, OSError):
        return


if __name__ == "__main__":
    main()
