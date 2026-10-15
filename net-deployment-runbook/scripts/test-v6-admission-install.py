#!/usr/bin/env python3
"""Exercise the real installer and installed v6 process in a disposable root."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

if os.environ.get("GDC_TEST_DISPOSABLE_ROOT") != "true" or not Path("/.dockerenv").exists():
    raise SystemExit("requires isolated container with disposable /srv/dai")
ROOT = Path(__file__).resolve().parents[1]
EDGE = Path("/srv/dai/edge")
TOKEN = "fixture-observer-token-1234"


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def call(arguments, ok=True):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=15)
    assert (result.returncode == 0) == ok, result.stderr
    assert TOKEN not in result.stdout + result.stderr
    return result


backend_port, admission_port = port(), port()
backend = subprocess.Popen([sys.executable, str(ROOT / "scripts/bifrost-fake-inference.py"), str(backend_port)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
process = None
try:
    with tempfile.TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        binding, token, environment = (temporary / name for name in ("binding.json", "token", "admission.env"))
        origin = f"http://127.0.0.1:{backend_port}"
        binding.write_text(json.dumps({"upstream": origin, "observer": origin + "/v1/status",
            "chain_api": origin, "chain_rpc": origin, "approved_versions": origin + "/approved",
            "port": admission_port}))
        token.write_text(TOKEN)
        token.chmod(0o600)
        call([sys.executable, str(ROOT / "scripts/render-v6-admission.py"), "--binding", str(binding),
              "--observer-token-file", str(token), "--output", str(environment)])
        installer = ["bash", str(ROOT / "04-ops/edge-node/install-gateway-admission.sh"), str(environment)]
        call(installer)
        assert (EDGE / "gateway-admission.env").stat().st_mode & 0o777 == 0o600
        assert (EDGE / "gateway-admission-proxy.py").read_bytes() == (ROOT / "04-ops/edge-node/gateway-admission-proxy.py").read_bytes()
        for layout in ("flat", "legacy"):
            protected = Path("/srv/dai") / ("protected" if layout == "flat" else "deploy/protected")
            protected.parent.mkdir(parents=True, exist_ok=True)
            protected.write_text("validator and gateway state must survive")
            compose = EDGE / "compose.yaml"
            compose.write_bytes(compose.read_bytes() + b"\n# retained independent service binding\n")
            compose.chmod(0o640)
            expected = digest(compose)
            before = (EDGE / "gateway-admission.env").read_bytes()
            call(installer + ["--preserve-compose", "0" * 64], ok=False)
            assert (EDGE / "gateway-admission.env").read_bytes() == before
            assert digest(compose) == expected
            call(installer + ["--preserve-compose", expected])
            assert digest(compose) == expected and compose.stat().st_mode & 0o777 == 0o640
            assert protected.read_text() == "validator and gateway state must survive"
        invalid = temporary / "invalid.env"
        invalid.write_text(environment.read_text().replace('"v6":', '"v7":'))
        call([*installer[:-1], str(invalid), "--preserve-compose", expected], ok=False)
        assert (EDGE / "gateway-admission.env").read_bytes() == environment.read_bytes()
        target = EDGE / "gateway-admission.env"
        retained = EDGE / "retained-test.env"
        target.rename(retained)
        target.mkdir()
        sentinel = target / "must-survive"
        sentinel.write_text("retained")
        call(installer + ["--preserve-compose", expected], ok=False)
        assert sentinel.read_text() == "retained" and digest(compose) == expected
        sentinel.unlink()
        target.rmdir()
        target.symlink_to(retained)
        call(installer + ["--preserve-compose", expected], ok=False)
        assert retained.read_bytes() == environment.read_bytes()
        target.unlink()
        retained.rename(target)
        values = dict(line.split("=", 1) for line in (EDGE / "gateway-admission.env").read_text().splitlines())
        # First prove refusal, then restart with an exactly matching registry.
        # Do not replace rendered URLs or protocol settings in the installed env.
        for phase in ("mismatch", "mismatch-restart", "json", "sse"):
            if phase == "json":
                backend.terminate()
                backend.wait(5)
                archive = json.loads(values["GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON"])["v6"]
                backend = subprocess.Popen([sys.executable, str(ROOT / "scripts/bifrost-fake-inference.py"), str(backend_port)],
                    env=dict(os.environ, GDC_TEST_APPROVED_V6=json.dumps(dict(archive, name="v6"))),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            process = subprocess.Popen([sys.executable, str(EDGE / "gateway-admission-proxy.py")],
                env=dict(os.environ, **values), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for attempt in range(50):
                try:
                    connection = http.client.HTTPConnection("127.0.0.1", admission_port, timeout=2)
                    connection.request("GET", "/v1/admission-status")
                    response = connection.getresponse()
                    body = json.loads(response.read())
                    connection.close()
                    break
                except OSError:
                    time.sleep(0.05)
            else:
                raise AssertionError("installed admission never started")
            assert response.status == 200
            if phase.startswith("mismatch"):
                assert body["available"] is False and body["reason"] == "selected_protocol_not_approved", body
            else:
                assert body["available"] is True, body
                connection = http.client.HTTPConnection("127.0.0.1", admission_port, timeout=3)
                connection.request("POST", "/v1/chat/completions", json.dumps({"model": "test-model",
                    "messages": [{"role": "user", "content": "probe"}], "stream": phase == "sse"}),
                    {"Authorization": "Bearer fixture-client", "Content-Type": "application/json"})
                response = connection.getresponse()
                payload = response.read().decode()
                assert response.status == 200 and response.getheader("X-GDC-Admission") == "dispatched_once"
                if phase == "sse":
                    assert "data: [DONE]" in payload
                else:
                    assert json.loads(payload)["choices"][0]["message"]["content"] == "fixture-ok"
                connection.close()
            process.terminate()
            process.wait(5)
            process = None
        print("PASS installed rendered v6 admission: preserved layouts, failed-artifact refusal, restart, JSON and SSE")
finally:
    if process is not None:
        process.terminate()
        process.wait(5)
    backend.terminate()
    backend.wait(5)
