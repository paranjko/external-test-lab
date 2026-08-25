#!/usr/bin/env python3
"""Bounded public-edge admission with one and only one gateway dispatch."""
import http.client
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def env(name, default):
    return os.environ.get(name, str(default))


HOST = env("GDC_GATEWAY_ADMISSION_HOST", "127.0.0.1")
PORT = int(env("GDC_GATEWAY_ADMISSION_PORT", 18083))
UPSTREAM = urlsplit(env("GDC_GATEWAY_ADMISSION_UPSTREAM", "http://127.0.0.1:18080"))
STATUS_URL = env("GDC_GATEWAY_ADMISSION_STATUS_URL", "http://127.0.0.1:18080/v1/status")
EPOCH_URL = env("GDC_GATEWAY_ADMISSION_EPOCH_URL", "http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data")
CHAIN_STATUS_URL = env("GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL", "http://127.0.0.1:26657/status")
CHAIN_PARAMS_URL = env("GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL", "http://127.0.0.1:1317/productscience/inference/inference/params")
SAFE_GUARD_BLOCKS = int(env("GDC_GATEWAY_ADMISSION_SAFE_GUARD_BLOCKS", 10))
MAX_QUEUE = int(env("GDC_GATEWAY_ADMISSION_MAX_QUEUE", 16))
MAX_WAIT = float(env("GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS", 20))
POLL = float(env("GDC_GATEWAY_ADMISSION_POLL_SECONDS", 0.25))
MAX_BODY = int(env("GDC_GATEWAY_ADMISSION_MAX_BODY_BYTES", 1048576))
if not (MAX_QUEUE > 0 and MAX_WAIT > 0 and POLL > 0 and MAX_BODY > 0 and SAFE_GUARD_BLOCKS > 0):
    raise SystemExit("gateway admission configuration must be positive")
SLOTS = threading.BoundedSemaphore(MAX_QUEUE)


def get_json(url):
    with urlopen(Request(url, headers={"Accept": "application/json"}), timeout=3) as response:
        if response.status != 200:
            raise ValueError("state response was not successful")
        return json.load(response)


def safe_generation():
    """Fresh phase generation only when capacity and participants agree."""
    try:
        status = get_json(STATUS_URL)
        epoch = get_json(EPOCH_URL).get("epoch_group_data", {}).get("epoch_index")
        height = get_json(CHAIN_STATUS_URL).get("result", {}).get("sync_info", {}).get("latest_block_height")
        params = get_json(CHAIN_PARAMS_URL).get("params", {}).get("epoch_params", {})
    except Exception:
        return None, "state_unavailable"
    try:
        height = int(height)
        epoch_length = int(params["epoch_length"])
        safe_start = sum(int(params[name]) for name in ("poc_stage_duration", "poc_exchange_duration", "poc_validation_delay", "poc_validation_duration", "set_new_validators_delay")) + 1
    except (KeyError, TypeError, ValueError):
        return None, "state_invalid"
    # A block-derived fence is required in addition to a fresh runtime view:
    # do not open a first dispatch near a known PoC lifecycle boundary.
    if not safe_start <= height % epoch_length <= epoch_length - SAFE_GUARD_BLOCKS:
        return None, "poc_fence"
    if not isinstance(epoch, (str, int)):
        return None, "epoch_invalid"
    capacity = status.get("capacity", {})
    weights = [capacity.get("total_weight"), capacity.get("effective_weight")]
    weights.extend((item or {}).get("current_weight", (item or {}).get("total_weight"))
                   for item in (capacity.get("models") or {}).values())
    try:
        positive = any(float(weight) > 0 for weight in weights if weight is not None)
    except (TypeError, ValueError):
        return None, "capacity_invalid"
    participants = []
    for item in status.get("devshards", []):
        runtime = item.get("runtime") or item
        if item.get("active") is True and runtime.get("phase") == "active" and not runtime.get("requests_blocked", False):
            if item.get("id") is not None:
                participants.append(str(item["id"]))
    if not positive or not participants:
        return None, "runtime_unavailable"
    return "%s:%s:%s" % (epoch, height, ",".join(sorted(participants))), None


class Handler(BaseHTTPRequestHandler):
    server_version = "GonkaAdmission/1"

    def log_message(self, _format, *_args):
        # Prompts, credentials and request URLs are never written to logs.
        pass

    def reject(self, status, code, admission="pre_dispatch_rejected"):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-GDC-Admission", admission)
        self.end_headers()
        self.wfile.write(json.dumps({"error": {"code": code}}).encode())

    def deadline(self):
        client_deadline = self.headers.get("X-Request-Deadline-Ms")
        if client_deadline is None:
            return time.monotonic() + MAX_WAIT
        try:
            remaining = int(client_deadline) / 1000.0 - time.time()
        except ValueError:
            return None
        return time.monotonic() + min(MAX_WAIT, remaining)

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/v1/chat/completions":
            self.reject(404, "not_found")
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.reject(400, "invalid_content_length")
            return
        if length < 0 or length > MAX_BODY:
            self.reject(413, "request_too_large")
            return
        body = self.rfile.read(length)
        # Authentication failure has no accepted inference, nonce or accounting
        # outcome. Preserve the gateway's normal 401 contract without making a
        # capacity-dependent admission decision for an unauthenticated probe.
        if not self.headers.get("Authorization"):
            self.dispatch_once(body)
            return
        deadline = self.deadline()
        if deadline is None or deadline <= time.monotonic():
            self.reject(408, "admission_deadline_elapsed")
            return
        if not SLOTS.acquire(blocking=False):
            self.reject(429, "admission_queue_full")
            return
        try:
            previous = None
            rejection = "admission_runtime_unavailable"
            while time.monotonic() < deadline:
                current, reason = safe_generation()
                # The same generation must be observed after the request was
                # queued; both observations are before the sole dispatch site.
                if current is not None and current == previous:
                    self.dispatch_once(body)
                    return
                if current is None:
                    rejection = "admission_%s" % reason
                elif previous is not None:
                    rejection = "admission_generation_unstable"
                previous = current
                time.sleep(min(POLL, max(0, deadline - time.monotonic())))
            self.reject(503, rejection)
        finally:
            SLOTS.release()

    def dispatch_once(self, body):
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in {"host", "connection", "content-length"}}
        headers["Host"] = UPSTREAM.netloc
        headers["Content-Length"] = str(len(body))
        connection = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port or 80, timeout=30)
        try:
            # No code path retries after this connection is requested.
            connection.request("POST", self.path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            self.send_response(response.status, response.reason)
            self.send_header("X-GDC-Admission", "dispatched_once")
            for key, value in response.getheaders():
                if key.lower() not in {"connection", "transfer-encoding", "content-length"}:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception:
            self.reject(502, "gateway_dispatch_failed", "dispatch_attempt_failed")
        finally:
            connection.close()


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
