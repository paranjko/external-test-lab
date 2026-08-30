#!/usr/bin/env python3
"""Regression contract for the scoped gateway admission observer."""

import http.client
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OBSERVER = os.path.join(ROOT, "04-ops", "gateway-admission-observer.py")


def unused_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    result = sock.getsockname()[1]
    sock.close()
    return result


class State:
    available = True
    authorization = None


class Gateway(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        State.authorization = self.headers.get("Authorization")
        if self.path != "/v1/admin/devshards" or not State.available:
            self.send_error(503)
            return
        body = {
            "capacity": {
                "total_weight": 23,
                "effective_weight": 17,
                "models": {
                    "Qwen/Qwen3-0.6B": {
                        "current_weight": 17,
                        "total_weight": 23,
                        "routable": True,
                        "private_metric": "drop-me",
                    }
                },
                "private_capacity": "drop-me",
            },
            "devshards": [{
                "id": "41",
                "active": True,
                "protocol_version": "v5",
                "chain_phase": "Inference",
                "runtime": {
                    "phase": "active",
                    "requests_blocked": False,
                    "session_version": "v5",
                    "private_key": "drop-me",
                    "storage_path": "/private/path",
                },
                "settings": {"admin_only": False},
            }],
            "settings": {"admin_key": "drop-me"},
            "private_key": "drop-me",
        }
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def request(port, token=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    headers = {}
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    connection.request("GET", "/v1/status", headers=headers)
    response = connection.getresponse()
    payload = json.loads(response.read())
    connection.close()
    return response.status, payload


gateway_port = unused_port()
gateway = ThreadingHTTPServer(("127.0.0.1", gateway_port), Gateway)
threading.Thread(target=gateway.serve_forever, daemon=True).start()

observer_port = unused_port()
environment = os.environ.copy()
environment.update({
    "DEVSHARD_ADMIN_API_KEY": "admin-secret",
    "GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN": "observer-secret",
    "GDC_GATEWAY_ADMIN_STATE_URL": "http://127.0.0.1:%s/v1/admin/devshards" % gateway_port,
    "GDC_GATEWAY_ADMISSION_OBSERVER_PORT": str(observer_port),
})
process = subprocess.Popen(
    [sys.executable, OBSERVER], env=environment,
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
try:
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", observer_port), timeout=0.05).close()
            break
        except OSError:
            time.sleep(0.02)
    else:
        raise RuntimeError("gateway admission observer did not start")

    assert request(observer_port) == (401, {"error": "authentication_required"})
    assert request(observer_port, "wrong-token") == (401, {"error": "authentication_required"})
    status, payload = request(observer_port, "observer-secret")
    assert status == 200
    assert State.authorization == "Bearer admin-secret"
    assert payload == {
        "capacity": {
            "effective_weight": 17,
            "models": {
                "Qwen/Qwen3-0.6B": {
                    "current_weight": 17,
                    "routable": True,
                    "total_weight": 23,
                }
            },
            "total_weight": 23,
        },
        "devshards": [{
            "active": True,
            "id": "41",
            "protocol_version": "v5",
            "runtime": {
                "chain_phase": "Inference",
                "phase": "active",
                "requests_blocked": False,
                "session_version": "v5",
            },
        }],
    }
    serialized = json.dumps(payload, sort_keys=True)
    for forbidden in ("admin-secret", "private", "settings", "storage"):
        assert forbidden not in serialized

    State.available = False
    assert request(observer_port, "observer-secret") == (
        503, {"error": "gateway_state_unavailable"})
finally:
    process.terminate()
    process.wait(3)
    gateway.shutdown()

print("PASS gateway admission observer exposes only authenticated read-only state")
