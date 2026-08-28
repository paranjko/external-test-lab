#!/usr/bin/env python3
"""Regression contract for bounded, pre-dispatch gateway admission."""
import http.client
import importlib.util
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
proxy_spec = importlib.util.spec_from_file_location("gateway_admission_proxy", PROXY)
proxy_module = importlib.util.module_from_spec(proxy_spec)
proxy_spec.loader.exec_module(proxy_module)


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
    in_flight = 0
    max_in_flight = 0
    dispatch_delay = 0
    state_delay = 0
    chain_phase = "Inference"
    lock = threading.Lock()


class Backend(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if State.state_delay:
            time.sleep(State.state_delay)
        if self.path == "/v1/status":
            body = {"capacity": {"models": {"model": {"current_weight": 1 if State.ready else 0}}}, "devshards": [{"id": "41", "active": State.ready, "chain_phase": State.chain_phase, "runtime": {"phase": "active", "requests_blocked": False}}]}
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
        try:
            self.wfile.write(encoded)
        except BrokenPipeError:
            # The deadline regression intentionally closes this state request.
            pass

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        with State.lock:
            State.dispatches += 1
            State.in_flight += 1
            State.max_in_flight = max(State.max_in_flight, State.in_flight)
        if State.dispatch_delay:
            time.sleep(State.dispatch_delay)
        if not self.headers.get("Authorization"):
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            # A gateway failure is an accounting outcome, not permission to replay.
            body = b'{"error":"single outcome"}'
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        with State.lock:
            State.in_flight -= 1


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


audit_files = {}


def start_proxy(backend_port, max_queue=1, wait=0.35, max_deadline=None,
                state_paths=None, upstream_port=None):
    proxy_port = port()
    state_paths = state_paths or {}
    env = os.environ.copy()
    audit_file = tempfile.NamedTemporaryFile(delete=False).name
    audit_files[proxy_port] = audit_file
    max_deadline = max_deadline if max_deadline is not None else max(wait, 1.5)
    env.update({
        "GDC_GATEWAY_ADMISSION_PORT": str(proxy_port),
        "GDC_GATEWAY_ADMISSION_UPSTREAM": "http://127.0.0.1:%s" % (upstream_port or backend_port),
        "GDC_GATEWAY_ADMISSION_STATUS_URL": "http://127.0.0.1:%s%s" % (backend_port, state_paths.get("status", "/v1/status")),
        "GDC_GATEWAY_ADMISSION_EPOCH_URL": "http://127.0.0.1:%s%s" % (backend_port, state_paths.get("epoch", "/epoch")),
        "GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL": "http://127.0.0.1:%s%s" % (backend_port, state_paths.get("chain", "/chain-status")),
        "GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL": "http://127.0.0.1:%s%s" % (backend_port, state_paths.get("params", "/params")),
        "GDC_GATEWAY_ADMISSION_MAX_QUEUE": str(max_queue),
        "GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS": str(wait),
        "GDC_GATEWAY_ADMISSION_MAX_DEADLINE_SECONDS": str(max_deadline),
        "GDC_GATEWAY_ADMISSION_POLL_SECONDS": "0.03",
        "GDC_GATEWAY_ADMISSION_AUDIT_FILE": audit_file,
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


def audit_records(proxy_port):
    with open(audit_files[proxy_port], encoding="utf-8") as source:
        return [json.loads(line) for line in source if line.strip()]


backend_port = port()
server = ThreadingHTTPServer(("127.0.0.1", backend_port), Backend)
threading.Thread(target=server.serve_forever, daemon=True).start()
processes = []
try:
    # The one upstream connection gets the entire remaining absolute deadline;
    # a fixed shorter transport cap would create a false dispatch failure.
    assert proxy_module.upstream_timeout(time.monotonic() + 31.5) > 30
    assert proxy_module.safe_upstream_content_type("application/json; charset=utf-8") == "application/json"
    assert proxy_module.safe_upstream_content_type("text/plain\\r\\nX-Injected: yes") == "application/octet-stream"

    # A request queued while phase state is unsafe dispatches only after two
    # fresh, matching generation observations and never replays a 429 outcome.
    State.ready = False; State.epochs = ["7"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port); processes.append(process)
    assert post_details(proxy_port, authorization=False) == (401, b'{"error": {"code": "authentication_required"}}', "pre_dispatch_rejected")
    assert State.dispatches == 0, "unauthenticated request bypassed the shared permit"
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

    # An explicit bounded client deadline may outlive the short default wait.
    # This is required for serialized exact-boundary observations.
    State.ready = True; State.epochs = ["8"]; State.epoch_index = 0; State.height = 50
    State.dispatches = 0; State.dispatch_delay = 0.25
    process, proxy_port = start_proxy(backend_port, wait=0.15, max_deadline=1); processes.append(process)
    observed = post_details(proxy_port, int((time.time() + 0.8) * 1000))
    assert observed == (429, b'{"error":"single outcome"}', "dispatched_once")
    assert State.dispatches == 1, "explicit deadline was incorrectly capped by the default wait"
    State.dispatch_delay = 0
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
    # Two serial four-source observations must fit even under a briefly busy
    # hosted runner; this fixture is proving generation change, not a timeout.
    process, proxy_port = start_proxy(backend_port, wait=1.5); processes.append(process)
    observed = post_details(proxy_port)
    assert observed == (503, b'{"error": {"code": "admission_generation_unstable"}}', "pre_dispatch_rejected"), observed
    assert State.dispatches == 0, "stale phase generation dispatched"
    process.terminate(); process.wait(2); processes.remove(process)

    # The block-derived PoC boundary fence also rejects before the one dispatch site.
    State.ready = True; State.epochs = ["9"]; State.epoch_index = 0; State.height = 95; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port, wait=0.5); processes.append(process)
    assert post_details(proxy_port) == (503, b'{"error": {"code": "admission_poc_fence"}}', "pre_dispatch_rejected")
    assert State.dispatches == 0, "PoC-boundary admission dispatched"
    process.terminate(); process.wait(2); processes.remove(process)

    # Positive capacity and an active runtime are stale during PoC lifecycle
    # phases. Keep the request queued and reject before dispatch if Inference
    # does not return within its absolute deadline.
    State.ready = True; State.chain_phase = "PoCGenerateWindDown"; State.epochs = ["9"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port, wait=0.5); processes.append(process)
    assert post_details(proxy_port) == (503, b'{"error": {"code": "admission_runtime_unavailable"}}', "pre_dispatch_rejected")
    assert State.dispatches == 0, "non-Inference runtime dispatched"
    State.chain_phase = "Inference"
    process.terminate(); process.wait(2); processes.remove(process)

    # Each unavailable admission-state source is sanitized before dispatch.
    State.ready = True; State.epochs = ["10"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    for source, expected in (("status", "status_unavailable"), ("epoch", "epoch_unavailable"), ("chain", "chain_status_unavailable"), ("params", "params_unavailable")):
        process, proxy_port = start_proxy(backend_port, wait=2, state_paths={source: "/missing"}); processes.append(process)
        observed = post_details(proxy_port)
        assert observed == (503, ('{"error": {"code": "admission_%s"}}' % expected).encode(), "pre_dispatch_rejected"), (source, observed)
        assert State.dispatches == 0, "unavailable %s state dispatched" % source
        process.terminate(); process.wait(2); processes.remove(process)

    # A final lookup that reaches the deadline must not erase the concrete
    # state-source failure observed throughout the request's wait window.
    State.ready = True; State.epochs = ["10"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port, wait=0.08, state_paths={"epoch": "/missing"}); processes.append(process)
    assert post_details(proxy_port) == (503, b'{"error": {"code": "admission_epoch_unavailable"}}', "pre_dispatch_rejected")
    assert State.dispatches == 0, "deadline edge erased the state-source failure after dispatch"
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

    # A slow chain-state sample consumes the same original absolute deadline.
    # The proxy returns locally and does not open an upstream connection.
    State.ready = True; State.epochs = ["10"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0; State.state_delay = 0.12
    process, proxy_port = start_proxy(backend_port, wait=0.4); processes.append(process)
    assert post_details(proxy_port, int((time.time() + 0.05) * 1000)) == (408, b'{"error": {"code": "admission_deadline_elapsed"}}', "pre_dispatch_rejected")
    assert State.dispatches == 0, "expired state lookup opened an upstream connection"
    State.state_delay = 0
    process.terminate(); process.wait(2); processes.remove(process)

    # Three queued requests may observe one safe generation, but the governor
    # opens only one upstream connection at a time and one dispatch per block.
    State.ready = True; State.epochs = ["11"]; State.epoch_index = 0; State.height = 50; State.advance_height = True
    State.dispatches = 0; State.in_flight = 0; State.max_in_flight = 0; State.dispatch_delay = 0.08
    process, proxy_port = start_proxy(backend_port, max_queue=3, wait=1); processes.append(process)
    results = []
    workers = [threading.Thread(target=lambda: results.append(post_details(proxy_port))) for _ in range(3)]
    for worker in workers: worker.start()
    for worker in workers: worker.join(3)
    assert len(results) == 3 and all(item[0] == 429 and item[2] == "dispatched_once" for item in results)
    assert State.dispatches == 3 and State.max_in_flight == 1, "concurrent upstream dispatch escaped the permit"
    records = audit_records(proxy_port)
    assert len(records) == 3
    assert all(record["admission"] == "dispatched_once" and record["upstream_http_status"] == 429
               and record["error_class"] == "upstream_http_429" for record in records)
    assert all(isinstance(record["arrival_height"], int) and isinstance(record["permit_height"], int)
               and isinstance(record["dispatch_height"], int) and isinstance(record["response_height"], int)
               and record["safe_generation"] for record in records)
    State.advance_height = False; State.dispatch_delay = 0
    process.terminate(); process.wait(2); processes.remove(process)

    # A client that disconnects while waiting loses its queue entry before any
    # dispatch. An expired absolute deadline is equally pre-dispatch only.
    State.ready = False; State.epochs = ["12"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    process, proxy_port = start_proxy(backend_port, max_queue=2, wait=0.4); processes.append(process)
    abandoned = socket.create_connection(("127.0.0.1", proxy_port), timeout=1)
    abandoned.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer test\r\nContent-Length: 17\r\n\r\n{\"model\":\"model\"}")
    abandoned.close()
    time.sleep(0.12)
    assert State.dispatches == 0, "disconnected request reached upstream"
    assert post(proxy_port, int((time.time() - 1) * 1000))[0] == 408
    records = audit_records(proxy_port)
    assert any(record["error_class"] == "client_disconnected" for record in records)
    assert any(record["error_class"] == "admission_deadline_elapsed" for record in records)
    process.terminate(); process.wait(2); processes.remove(process)

    # A connection failure after the one dispatch site remains one observable
    # outcome with a distinct machine-readable class; it is never replayed.
    State.ready = True; State.epochs = ["13"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    unavailable_upstream = port()
    process, proxy_port = start_proxy(backend_port, wait=0.4, upstream_port=unavailable_upstream); processes.append(process)
    status, _body, admission = post_details(proxy_port)
    assert (status, admission) == (502, "dispatch_attempt_failed")
    assert State.dispatches == 0, "unavailable upstream unexpectedly dispatched to fixture backend"
    records = audit_records(proxy_port)
    assert len(records) == 1 and records[0]["error_class"] == "gateway_dispatch_connection_failed"
    assert records[0]["admission"] == "dispatch_attempt_failed" and records[0]["upstream_http_status"] == 0
    process.terminate(); process.wait(2); processes.remove(process)

    # A dispatch timeout is distinguishable from an upstream HTTP response and
    # remains a single attempt, preserving the external-blocker discriminator.
    State.ready = True; State.epochs = ["14"]; State.epoch_index = 0; State.height = 50; State.dispatches = 0
    State.dispatch_delay = 2
    process, proxy_port = start_proxy(backend_port, wait=2); processes.append(process)
    status, _body, admission = post_details(proxy_port, int((time.time() + 1.1) * 1000))
    assert (status, admission) == (504, "dispatch_attempt_failed")
    assert State.dispatches == 1, "dispatch timeout retried the upstream request"
    records = audit_records(proxy_port)
    assert len(records) == 1 and records[0]["error_class"] == "gateway_dispatch_timeout"
    assert records[0]["admission"] == "dispatch_attempt_failed" and records[0]["upstream_http_status"] == 0
    State.dispatch_delay = 0
finally:
    for process in processes:
        process.terminate()
        process.wait(2)
    server.shutdown()
    for audit_file in audit_files.values():
        try:
            os.unlink(audit_file)
        except FileNotFoundError:
            pass

print("PASS gateway admission is bounded, generation-fresh, deadline-preserving, and exactly-once")
