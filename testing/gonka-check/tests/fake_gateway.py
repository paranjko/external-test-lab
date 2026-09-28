"""Local stand-in for the public DevNet API, chain reads and the admission proxy."""

import datetime
import json
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


EPOCH_LENGTH = 70
EPOCH_START = 507850
CHAIN_API = "/chain-api/productscience/inference/inference"
MODEL = "Qwen/Qwen3-0.6B"


class FakeGateway:
    """Height advances by one block on every chain status read."""

    def __init__(self, offset=30, scenario="ok", health="ready", status="routable"):
        self.height = EPOCH_START + offset
        self.scenario = scenario
        self.health = health
        self.status = status
        self.requests = []
        self.posts = []
        self.lock = threading.Lock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.base_url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, args=(0.05,), daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()

    def preset(self, **overrides):
        preset = {
            "name": "fake", "point": "fake", "base_url": self.base_url, "model": MODEL,
            "health_url": self.base_url + "/status/gateway-health",
            "chain_rpc": self.base_url + "/chain-rpc",
            "chain_api": self.base_url + CHAIN_API,
            "send_window": {"from_offset": 1, "stop_before_end": 20},
            "min_blocks_between_sends": 2, "deadline_s": 60, "socket_timeout_s": 5,
            "chain_poll_s": 0, "health_poll_s": 0.01, "health_max_age_s": 30,
            "budget": {"per_run": 4, "per_epoch": 4}, "profiles_allowed": ["smoke"],
            "forbid_paths": ["/status/gateway/", "/v1/admission-status"],
        }
        preset.update(overrides)
        return preset

    def epoch(self):
        return self.height // EPOCH_LENGTH

    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def _json(self, status, payload, headers=None):
                body = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                for name, value in (headers or {}).items():
                    self.send_header(name, str(value))
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _note(self, method, body=None):
                entry = {
                    "method": method, "path": self.path, "at": time.time(),
                    "authorization": self.headers.get("Authorization"),
                    "deadline_ms": self.headers.get("X-Request-Deadline-Ms"),
                    "height": fake.height, "body": body,
                }
                with fake.lock:
                    fake.requests.append(entry)
                return entry

            def do_GET(self):
                self._note("GET")
                path = self.path.split("?", 1)[0]
                if path == "/chain-rpc/status":
                    with fake.lock:
                        fake.height += 1
                    self._json(200, {"result": {"sync_info": {"latest_block_height": str(fake.height)}}})
                elif path == CHAIN_API + "/params":
                    self._json(200, {"params": {
                        "epoch_params": {
                            "epoch_length": str(EPOCH_LENGTH), "poc_stage_duration": "10",
                            "poc_exchange_duration": "2", "poc_validation_delay": "3",
                            "poc_validation_duration": "10", "set_new_validators_delay": "2",
                        },
                        "devshard_escrow_params": {"approved_versions": ["v5"]},
                    }})
                elif path == CHAIN_API + "/current_epoch_group_data":
                    self._json(200, {"epoch_group_data": {"epoch_index": str(fake.epoch())}})
                elif path == CHAIN_API + "/active_confirmation_poc_event":
                    self._json(200, {"is_active": False, "event": None})
                elif path == "/v1/status":
                    self._json(200, fake.status_doc())
                elif path == "/v1/models":
                    self._json(200, {"object": "list", "data": [{"id": MODEL, "object": "model"}]})
                elif path == "/status/gateway-health":
                    self._json(200, fake.health_doc())
                else:
                    self._json(404, {"error": {"code": "not_found"}})

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length) or b"null")
                entry = self._note("POST", body)
                if self.path != "/v1/chat/completions":
                    self._json(404, {"error": {"code": "not_found"}})
                    return
                with fake.lock:
                    fake.posts.append(entry)
                status, payload, headers = fake.completion(body, bool(entry["authorization"]))
                if status == 302:
                    self.send_response(302)
                    self.send_header("Location", fake.base_url + "/elsewhere")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self._json(status, payload, headers)

        return Handler

    def status_doc(self):
        doc = {"escrow_id": "27132", "nonce": 0, "phase": "active", "chain_phase": "Inference",
               "confirmation_poc_phase": "CONFIRMATION_POC_INACTIVE", "requests_blocked": False,
               "height_seed": {"state": "ok"}}
        if self.status == "confirmation":
            doc.update(confirmation_poc_phase="CONFIRMATION_POC_GENERATION", block_reason="confirmation_poc")
        return doc

    def health_doc(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        h = self.height
        doc = {"state": "READY", "readiness": "TRAFFIC_READY", "reason": "",
               "checked_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
               "completion_finished_ms": int(now.timestamp() * 1000),
               "admission": "dispatched_once", "admission_id": uuid.uuid4().hex,
               "safe_generation": "sha256:" + "a" * 64,
               "arrival_height": h, "permit_height": h, "dispatch_height": h, "response_height": h}
        if self.health == "poc_fence":
            doc.update(state="DEGRADED", readiness="UNAVAILABLE", reason="poc_fence",
                       admission="pre_dispatch_rejected")
        return doc

    def completion(self, body, authorized):
        h = self.height
        admission = {"X-GDC-Admission-ID": uuid.uuid4().hex, "X-GDC-Arrival-Height": h}
        if not authorized:
            admission["X-GDC-Admission"] = "pre_dispatch_rejected"
            return 401, {"error": {"code": "authentication_required"}}, admission
        if self.scenario == "redirect":
            return 302, None, None
        if self.scenario == "no_proxy":
            return 502, {"error": {"message": "bad gateway"}}, {}
        if self.scenario == "misconfigured":
            admission["X-GDC-Admission"] = "pre_dispatch_rejected"
            return 503, {"error": {"code": "admission_protocol_not_approved"}}, admission
        if self.scenario == "reject":
            admission["X-GDC-Admission"] = "pre_dispatch_rejected"
            return 503, {"error": {"code": "admission_poc_fence"}}, admission
        admission["X-GDC-Permit-Height"] = h
        admission["X-GDC-Safe-Generation"] = "sha256:" + "b" * 64
        if self.scenario == "leak":
            admission["X-GDC-Admission"] = "pre_dispatch_rejected"
            return 408, {"error": {"code": "admission_deadline_elapsed"}}, admission
        admission["X-GDC-Dispatch-Height"] = h
        if self.scenario == "dispatch_fail":
            admission["X-GDC-Admission"] = "dispatch_attempt_failed"
            return 504, {"error": {"code": "gateway_dispatch_timeout"}}, admission
        admission["X-GDC-Admission"] = "dispatched_once"
        admission["X-GDC-Response-Height"] = h
        prompt = body["messages"][0]["content"]
        tokens = 64
        if "7 + 5" in prompt:
            text = "<think>\n\n</think>\n\n12\n\n7 + 5 = 12."
        else:
            text = "1, 2, 3, 4, 5, 6, 7, 8, 9, 10"
            if self.scenario == "floor_broken":
                tokens = 1
        return 200, {
            "id": "chatcmpl-fake", "object": "chat.completion", "model": MODEL,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                         "finish_reason": "length"}],
            "usage": {"prompt_tokens": 20, "completion_tokens": tokens, "total_tokens": 20 + tokens},
        }, admission
