#!/usr/bin/env python3
"""Regression contract for bounded, pre-dispatch gateway admission."""
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROXY = os.path.join(ROOT, "04-ops", "edge-node", "gateway-admission-proxy.py")


def port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    result = sock.getsockname()[1]
    sock.close()
    return result


class State:
    ready = False
    epochs = ["7"]
    epoch_index = 0
    height = 50
    advance_height = False
    dispatches = 0


class Backend(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == "/v1/status":
            body = {"capacity": {"models": {"model": {"current_weight": 1 if State.ready else 0}}}, "devshards": [{"id": "41", "active": State.ready, "runtime": {"phase": "active", "requests_blocked": False}}]}
        elif self.path == "/epoch":
            epoch = State.epochs[State.epoch_index % len(State.epochs)]
            State.epoch_index += 1
            body = {"epoch_group_data": {"epoch_index": epoch}}
        elif self.path == "/chain-status":
            height = State.height
            if State.advance_height:
                State.height += 1
            body = {"result": {"sync_info": {"latest_block_height": str(height)}}}
        elif self.path == "/params":
            body = {"params": {"epoch_params": {"epoch_length": "100", "poc_stage_duration": "2", "poc_exchange_duration": "2", "poc_validation_delay": "2", "poc_validation_duration": "2", "set_new_validators_delay": "2"}}}
        else:
            self.send_error(404)
            return
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        State.dispatches += 1
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        if not self.headers.get("Authorization"):
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # A gateway failure is an accounting outcome, not permission to replay.
        body = b'{"error":"single outcome"}'
        self.send_response(429)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def post_details(proxy_port, deadline=None, authorization=True):
    connection = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=3)
    headers = {"Content-Type": "application/json"}
    if authorization:
        headers["Authorization"] = "Bearer test"
    if deadline is not None:
        headers["X-Request-Deadline-Ms"] = str(deadline)
    connection.request("POST", "/v1/chat/completions", b'{"model":"model"}', headers)
    response = connection.getresponse()
    body = response.read()
    admission = response.getheader("X-GDC-Admission")
    connection.close()
    return response.status, body, admission


def post(proxy_port, deadline=None, authorization=True):
    status, body, _admission = post_details(proxy_port, deadline, authorization)
    return status, body


def start_proxy(backend_port, max_queue=1, wait=0.35, state_paths=None):
    proxy_port = port()
    state_paths = state_paths or {}
    env = os.environ.copy()
    env.update({
        "GDC_GATEWAY_ADMISSION_PORT": str(proxy_port),
        "GDC_GATEWAY_ADMISSION_UPSTREAM": "http://127.0.0.1:%s" % backend_port,
        "GDC_GATEWAY_ADMISSION_STATUS_URL": "http://127.0.0.1:%s%s" % (backend_port, state_paths.get("status", "/v1/status")),
        "GDC_GATEWAY_ADMISSION_EPOCH_URL": "http://127.0.0.1:%s%s" % (backend_port, state_paths.get("epoch", "/epoch")),
        "GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL": "http://127.0.0.1:%s%s" % (backend_port, state_paths.get("chain", "/chain-status")),
        "GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL": "http://127.0.0.1:%s%s" % (backend_port, state_paths.get("params", "/params")),
        "GDC_GATEWAY_ADMISSION_MAX_QUEUE": str(max_queue),
        "GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS": str(wait),
        "GDC_GATEWAY_ADMISSION_POLL_SECONDS": "0.03",
    })
    process = subprocess.Popen([sys.executable, PROXY], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", proxy_port), timeout=0.05).close()
            return process, proxy_port
        except OSError:
            time.sleep(0.02)
    process.terminate()
    raise RuntimeError("admission proxy did not start")


backend_port = port()
server = ThreadingHTTPServer(("127.0.0.1", backend_port), Backend)
threading.Thread(target=server.serve_forever, daemon=True).start()
processes = []
try:
    # A request queued while phase state is unsafe dispatches only after two
    # fresh, matching generation observations and never replays a 429 outcome.
    State.ready = False; State.epochs = ["7"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port); processes.append(process)
    assert post_details(proxy_port, authorization=False) == (401, b"", "dispatched_once")
    assert State.dispatches == 1, "unauthenticated request did not preserve gateway auth contract"
    State.dispatches = 0
    result = []
    worker = threading.Thread(target=lambda: result.append(post(proxy_port)))
    worker.start()
    time.sleep(0.08)
    assert State.dispatches == 0, "unsafe phase dispatched before admission"
    State.ready = True
    worker.join(2)
    assert result == [(429, b'{"error":"single outcome"}')]
    assert State.dispatches == 1, "gateway outcome was replayed"
    process.terminate(); process.wait(2); processes.remove(process)

    # Consecutive fresh observations may span different block heights.  The
    # phase generation stays stable, so the proxy dispatches exactly once.
    State.ready = True; State.epochs = ["8"]; State.epoch_index = 0; State.height = 50; State.advance_height = True; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port); processes.append(process)
    assert post_details(proxy_port) == (429, b'{"error":"single outcome"}', "dispatched_once")
    assert State.dispatches == 1, "fresh height progression blocked safe dispatch"
    State.advance_height = False
    process.terminate(); process.wait(2); processes.remove(process)

    # A changing epoch generation is stale admission state, even with capacity.
    State.ready = True; State.epochs = ["8", "9"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port, wait=0.18); processes.append(process)
    assert post_details(proxy_port) == (503, b'{"error": {"code": "admission_generation_unstable"}}', "pre_dispatch_rejected")
    assert State.dispatches == 0, "stale phase generation dispatched"
    process.terminate(); process.wait(2); processes.remove(process)

    # The block-derived PoC boundary fence also rejects before the one dispatch site.
    State.ready = True; State.epochs = ["9"]; State.epoch_index = 0; State.height = 95; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port, wait=0.18); processes.append(process)
    assert post_details(proxy_port) == (503, b'{"error": {"code": "admission_poc_fence"}}', "pre_dispatch_rejected")
    assert State.dispatches == 0, "PoC-boundary admission dispatched"
    process.terminate(); process.wait(2); processes.remove(process)

    # Each unavailable admission-state source is sanitized before dispatch.
    State.ready = True; State.epochs = ["10"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    for source, expected in (("status", "status_unavailable"), ("epoch", "epoch_unavailable"), ("chain", "chain_status_unavailable"), ("params", "params_unavailable")):
        process, proxy_port = start_proxy(backend_port, wait=0.18, state_paths={source: "/missing"}); processes.append(process)
        assert post_details(proxy_port) == (503, ('{"error": {"code": "admission_%s"}}' % expected).encode(), "pre_dispatch_rejected")
        assert State.dispatches == 0, "unavailable %s state dispatched" % source
        process.terminate(); process.wait(2); processes.remove(process)

    # Queue capacity and an original expired deadline reject before dispatch.
    State.ready = False; State.epochs = ["10"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port, max_queue=1, wait=0.2); processes.append(process)
    pending = threading.Thread(target=lambda: post(proxy_port))
    pending.start(); time.sleep(0.05)
    assert post(proxy_port)[0] == 429
    assert post(proxy_port, int((time.time() - 1) * 1000))[0] == 408
    pending.join(2)
    assert State.dispatches == 0, "pre-dispatch rejection reached gateway"
finally:
    for process in processes:
        process.terminate()
        process.wait(2)
    server.shutdown()

print("PASS gateway admission is bounded, generation-fresh, deadline-preserving, and exactly-once")
