#!/usr/bin/env python3
"""Expose the minimum read-only gateway state required by public admission."""

import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen


HOST = os.environ.get("GDC_GATEWAY_ADMISSION_OBSERVER_HOST", "127.0.0.1")
PORT = int(os.environ.get("GDC_GATEWAY_ADMISSION_OBSERVER_PORT", "18084"))
ADMIN_URL = os.environ.get(
    "GDC_GATEWAY_ADMIN_STATE_URL", "http://127.0.0.1:18080/v1/admin/devshards")
ADMIN_KEY = os.environ.get("DEVSHARD_ADMIN_API_KEY", "")
OBSERVER_TOKEN = os.environ.get("GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN", "")


def sanitize_runtime(runtime):
    if not isinstance(runtime, dict):
        return None
    return {
        key: runtime.get(key)
        for key in ("phase", "chain_phase", "requests_blocked", "session_version")
        if key in runtime
    }


def sanitize_capacity(capacity):
    if not isinstance(capacity, dict):
        raise ValueError("gateway capacity is not an object")
    safe = {
        key: capacity.get(key)
        for key in ("total_weight", "effective_weight")
        if key in capacity
    }
    models = capacity.get("models")
    if not isinstance(models, dict):
        raise ValueError("gateway capacity lacks model weights")
    safe["models"] = {}
    for model_id, model in models.items():
        if not isinstance(model_id, str) or not isinstance(model, dict):
            raise ValueError("gateway model capacity is invalid")
        safe["models"][model_id] = {
            key: model.get(key)
            for key in ("current_weight", "total_weight", "routable")
            if key in model
        }
    return safe


def sanitize_state(payload):
    """Drop gateway settings, credentials, storage paths, and private state."""
    if not isinstance(payload, dict):
        raise ValueError("gateway state is not an object")
    capacity = payload.get("capacity")
    devshards = payload.get("devshards")
    if not isinstance(capacity, dict) or not isinstance(devshards, list):
        raise ValueError("gateway state lacks capacity or runtimes")
    safe_devshards = []
    for item in devshards:
        if not isinstance(item, dict):
            raise ValueError("gateway runtime is not an object")
        safe = {
            key: item.get(key)
            for key in ("id", "active", "protocol_version")
            if key in item
        }
        if "runtime" in item:
            safe["runtime"] = sanitize_runtime(item["runtime"])
            if "chain_phase" not in safe["runtime"] and "chain_phase" in item:
                safe["runtime"]["chain_phase"] = item["chain_phase"]
        safe_devshards.append(safe)
    return {"capacity": sanitize_capacity(capacity), "devshards": safe_devshards}


def read_gateway_state():
    request = Request(
        ADMIN_URL,
        headers={"Accept": "application/json", "Authorization": "Bearer " + ADMIN_KEY},
    )
    with urlopen(request, timeout=3) as response:
        if response.status != 200:
            raise ValueError("gateway admin state is unavailable")
        return sanitize_state(json.load(response))


class Handler(BaseHTTPRequestHandler):
    server_version = "GonkaAdmissionObserver/1"

    def log_message(self, _format, *_args):
        pass

    def respond(self, status, payload):
        encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path != "/v1/status":
            self.respond(404, {"error": "not_found"})
            return
        authorization = self.headers.get("Authorization", "")
        expected = "Bearer " + OBSERVER_TOKEN
        if not hmac.compare_digest(authorization, expected):
            self.respond(401, {"error": "authentication_required"})
            return
        try:
            payload = read_gateway_state()
        except Exception:
            self.respond(503, {"error": "gateway_state_unavailable"})
            return
        self.respond(200, payload)


if __name__ == "__main__":
    if not ADMIN_KEY or not OBSERVER_TOKEN or ADMIN_KEY == OBSERVER_TOKEN:
        raise SystemExit("gateway admission observer credentials are not configured")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
