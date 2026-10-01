#!/usr/bin/env python3
"""Real B readiness process and actual participant Caddy in both edge layouts."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("readiness_manager", ROOT / "04-ops/gateway-readiness.py")
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Backend(BaseHTTPRequestHandler):
    weight = 296
    limit = 1
    version = "v5"
    def log_message(self, *_):
        pass
    def do_GET(self):
        if self.path == "/v1/admin/devshards":
            if self.headers.get("Authorization") != "Bearer private-admin":
                self.send_error(401)
                return
            body = {"capacity": {"models": {"model": {"current_weight": self.weight, "routable": True}}},
                    "limiter": {"models": {"model": {"effective_max_concurrent_requests": self.limit}}},
                    "devshards": [{"id": "B-owned", "model": "model", "active": True, "phase": "active", "chain_phase": "Inference", "session_version": self.version, "requests_blocked": False}]}
        elif self.path == "/epoch":
            body = {"epoch_group_data": {"epoch_index": 7}}
        elif self.path == "/epoch-info":
            body = {"latest_epoch": {"poc_start_block_height": 0}}
        elif self.path == "/chain":
            body = {"result": {"sync_info": {"latest_block_height": "50", "latest_block_time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "catching_up": False}}}
        elif self.path == "/params":
            body = {"params": {"epoch_params": {"epoch_length": 100, "poc_stage_duration": 2, "poc_exchange_duration": 2, "poc_validation_delay": 2, "poc_validation_duration": 2, "set_new_validators_delay": 2}, "devshard_escrow_params": {"approved_versions": [{"name": "v5", "binary": "https://example.invalid/v5.zip", "sha256": "a" * 64}]}}}
        elif self.path == "/v1/status":
            body = {"gateway": "native-B"}
        else:
            self.send_error(404)
            return
        encoded = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def request(port_number, path, token="devnet_fixture", method="GET", host="127.0.0.1"):
    connection = http.client.HTTPConnection(host, port_number, timeout=8)
    headers = {"Authorization": "Bearer " + token} if token else {}
    connection.request(method, path, headers=headers)
    response = connection.getresponse()
    result = response.status, response.read()
    connection.close()
    return result


native_port, readiness_port = port(), port()
backend = ThreadingHTTPServer(("127.0.0.1", native_port), Backend)
threading.Thread(target=backend.serve_forever, daemon=True).start()
process = None
try:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        secret = root / "srv/dai/broker-tests/ds502-b/gateway.env"
        secret.parent.mkdir(parents=True)
        secret.write_text("DEVSHARD_ADMIN_API_KEY=private-admin\nDEVSHARD_API_KEYS=devnet_fixture\n")
        files = manager.desired_files(root, ROOT / "04-ops/edge-node/gateway-admission-proxy.py", readiness_port, native_port, "model", "https://example.invalid/v5.zip", "a" * 64)
        for relative, (content, mode) in files.items():
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            target.chmod(mode)
        environment = manager.read_env(root / manager.SCOPE / "admission.env")
        for variable, path in (("EPOCH_URL", "/epoch"), ("EPOCH_INFO_URL", "/epoch-info"), ("CHAIN_STATUS_URL", "/chain"), ("CHAIN_PARAMS_URL", "/params")):
            environment["GDC_GATEWAY_ADMISSION_" + variable] = "http://127.0.0.1:%s%s" % (native_port, path)
        process = subprocess.Popen([sys.executable, str(root / manager.SCOPE / "gateway-admission-proxy.py")], env={**os.environ, **environment})
        for _ in range(100):
            try:
                if request(readiness_port, "/v1/admission-status")[0] == 200:
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise AssertionError("managed B readiness did not start")
        assert request(readiness_port, "/v1/admission-status", None)[0] == 401
        assert request(readiness_port, "/v1/admission-status", "devnet_A")[0] == 401
        assert request(readiness_port, "/v1/status")[0] == 404
        assert request(readiness_port, "/v1/admission-status", method="POST")[0] == 405
        for layout in ("srv/dai/edge", "srv/dai/deploy/edge"):
            edge = root / layout
            edge.mkdir(parents=True, exist_ok=True)
            config = (ROOT / "04-ops/edge-node/Caddyfile").read_text().replace("admin 127.0.0.1:2019", "admin off").replace("  email {$ACME_EMAIL}\n", "")
            # Fixture port mapping preserves native route dispatch, without
            # claiming or binding the operator's real 18100 listener.
            config = config.replace("reverse_proxy 127.0.0.1:18100", "reverse_proxy 127.0.0.1:%s" % native_port)
            (edge / "Caddyfile").write_text(config)
            caddy_port = port()
            name = "gdc-readiness-fixture-%s-%s" % (os.getpid(), caddy_port)
            command = ["docker", "run", "--detach", "--name", name, "--network", "host", "--read-only", "--tmpfs", "/data", "--tmpfs", "/config",
                       "--volume", str(edge / "Caddyfile") + ":/etc/caddy/Caddyfile:ro"]
            for key, value in {"PUBLIC_HOST": "http://:%s" % caddy_port, "PUBLIC_EDGE_HOST": "example.invalid", "PUBLIC_EDGE_CIDR": "192.0.2.1/32", "MONITORING_CIDR": "192.0.2.1/32", "MONITORING_DOCKER_CIDR": "192.0.2.1/32", "GDC_GATEWAY_METRICS_UPSTREAM": "http://127.0.0.1:%s" % native_port, "GDC_GATEWAY_B_READINESS_UPSTREAM": "http://127.0.0.1:%s" % readiness_port}.items():
                command += ["--env", key + "=" + value]
            command += ["caddy:2.11.4-alpine"]
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    try:
                        status, body = request(caddy_port, "/gateway-b/v1/admission-status")
                        if status == 200:
                            break
                    except OSError:
                        pass
                    time.sleep(0.05)
                else:
                    raise AssertionError("Caddy B handoff did not start")
                assert json.loads(body) == {"state": "READY", "available": True, "reason": None, "gateway": "B", "model": "model", "protocol": "v5"}
                assert request(caddy_port, "/gateway-b/v1/admission-status", "wrong")[0] == 401
                assert request(caddy_port, "/gateway-b/v1/admission-status", method="POST")[0] == 403
                native_status, native_body = request(caddy_port, "/gateway-b/v1/status")
                assert native_status == 200 and json.loads(native_body) == {"gateway": "native-B"}
                # UDP connect selects a local route only, it sends no packet.
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
                    route.connect(("192.0.2.1", 9))
                    nonloopback = route.getsockname()[0]
                assert not nonloopback.startswith("127.")
                assert request(caddy_port, "/gateway-b/v1/admission-status", host=nonloopback)[0] == 403
                Backend.limit = 0
                assert json.loads(request(caddy_port, "/gateway-b/v1/admission-status")[1])["available"] is False
                Backend.limit = 1
                process.terminate()
                process.wait(3)
                process = subprocess.Popen([sys.executable, str(root / manager.SCOPE / "gateway-admission-proxy.py")], env={**os.environ, **environment})
                subprocess.run(["docker", "restart", name], check=True, stdout=subprocess.DEVNULL)
                for _ in range(100):
                    try:
                        if json.loads(request(caddy_port, "/gateway-b/v1/admission-status")[1])["available"]:
                            break
                    except OSError:
                        time.sleep(0.05)
                else:
                    raise AssertionError("B handoff did not survive restart")
                print("PASS B private readiness process, auth/source/method gates and restart in " + layout)
            finally:
                subprocess.run(["docker", "rm", "--force", name], check=True, stdout=subprocess.DEVNULL)
finally:
    if process is not None:
        process.terminate()
        process.wait(3)
    backend.shutdown()
    backend.server_close()
