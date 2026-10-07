#!/usr/bin/env python3
"""Contract test for first apply and preserving Bifrost reapply."""
import importlib.util
import json
import os
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("provision", root / "04-ops/bifrost-provision.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class Handler(BaseHTTPRequestHandler):
    configured = False
    providers = []
    keys = []
    puts = 0
    posted_provider = 0
    posted_key = 0
    def log_message(self, *_args): pass
    def _body(self): return json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
    def _send(self, status, body):
        encoded = json.dumps(body).encode(); self.send_response(status); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
    def do_GET(self):
        auth = self.headers.get("Authorization")
        if self.path == "/api/config":
            if not type(self).configured: return self._send(200, {"is_db_connected": True})
            if auth != "Basic YWRtaW46VmFsaWQhUGFzc3dvcmQx": return self._send(401, {})
            return self._send(200, {"auth_config": {"is_enabled": True}})
        if auth != "Basic YWRtaW46VmFsaWQhUGFzc3dvcmQx": return self._send(401, {})
        if self.path == "/api/providers": return self._send(200, {"providers": type(self).providers})
        if self.path == "/api/providers/gonka-s/keys": return self._send(200, {"keys": type(self).keys})
        return self._send(404, {})
    def do_PUT(self):
        assert self.path == "/api/config" and not self.headers.get("Authorization")
        body = self._body(); assert body["auth_config"]["setup_token"] == "setup-token"; assert body["auth_config"]["admin_password"] == {"value": "Valid!Password1"}
        type(self).configured = True; type(self).puts += 1; self._send(200, {})
    def do_POST(self):
        if self.headers.get("Authorization") != "Basic YWRtaW46VmFsaWQhUGFzc3dvcmQx": return self._send(401, {})
        body = self._body()
        if self.path == "/api/providers":
            assert body == module.provider_payload("gonka-s", "http://127.0.0.1:18080/v1")
            type(self).providers = [{"name": "gonka-s", "network_config": body["network_config"], "custom_provider_config": body["custom_provider_config"]}]
            type(self).posted_provider += 1; return self._send(200, type(self).providers[0])
        if self.path == "/api/providers/gonka-s/keys":
            assert body == {"value": {"value": "provider-secret"}, "models": ["Qwen/Qwen3-0.6B"], "enabled": True}
            type(self).keys = [{"id": "actual-provider-key-id", "models": ["Qwen/Qwen3-0.6B"]}]
            type(self).posted_key += 1; return self._send(200, type(self).keys[0])
        return self._send(404, {})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory() as directory:
    binding = Path(directory) / "broker-binding.env"
    os.environ.update({
        "BIFROST_MANAGEMENT_URL": f"http://127.0.0.1:{server.server_port}", "BIFROST_ADMIN_USERNAME": "admin",
        "BIFROST_ADMIN_PASSWORD": "Valid!Password1", "BIFROST_SETUP_TOKEN": "setup-token", "BIFROST_GONKA_PROVIDER": "gonka-s",
        "BIFROST_GONKA_BASE_URL": "http://127.0.0.1:18080/v1", "BIFROST_GONKA_MODEL": "Qwen/Qwen3-0.6B",
        "BIFROST_GONKA_PROVIDER_KEY": "provider-secret", "BIFROST_BROKER_BINDING_FILE": str(binding),
    })
    initial = module.preview_state(module.client_from_environment())
    assert initial["current"] == {"bootstrap": "empty", "provider": None}
    assert initial["delta"] == ["bootstrap", "provider", "provider_key"]
    module.main(["--apply", "--expected-sha256", initial["before_sha256"]])
    assert Handler.puts == Handler.posted_provider == Handler.posted_key == 1
    assert binding.read_text() == "BIFROST_GONKA_PROVIDER=gonka-s\nBIFROST_GONKA_MODEL=Qwen/Qwen3-0.6B\nBIFROST_GONKA_KEY_ID=actual-provider-key-id\n"
    try:
        module.main(["--apply", "--expected-sha256", initial["before_sha256"]])
        raise AssertionError("stale Bifrost preview was accepted")
    except module.ProvisionError as error:
        assert str(error) == "Bifrost preview is stale; current state fingerprint changed"
    converged = module.preview_state(module.client_from_environment())
    assert converged["delta"] == []
    module.main(["--apply", "--expected-sha256", converged["before_sha256"]])
    assert Handler.puts == Handler.posted_provider == Handler.posted_key == 1
    assert oct(binding.stat().st_mode & 0o777) == "0o444"
server.shutdown(); server.server_close()
print("PASS Bifrost provision bootstraps only empty state and retains provider/key binding on reapply")
