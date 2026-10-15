#!/usr/bin/env python3
"""Loopback-only OpenAI-shaped upstream for pinned Bifrost adapter tests."""
import json
import os
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUESTS = []
REQUEST_LOCK = threading.Lock()
REQUEST_IDS = {
    "receipt-one": "fixture-native-receipt-one",
    "receipt-two": "fixture-native-receipt-two",
    "receipt-fenced": "fixture-native-receipt-fenced",
}
V6 = json.loads(os.environ.get("GDC_TEST_APPROVED_V6", json.dumps(
    {"name": "v6", "binary": "https://example.invalid/v6.zip", "sha256": "a" * 64})))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def do_GET(self):
        if self.path == "/fixture/requests":
            with REQUEST_LOCK:
                encoded = json.dumps(REQUESTS).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        # Synthetic chain/runtime observations for the real admission process.
        payloads = {
            "/v1/status": {"capacity": {"models": {"test-model": {"current_weight": 1}}},
                           "limiter": {"models": {"test-model": {"effective_max_concurrent_requests": 1}}},
                           "devshards": [{"id": "41", "active": True, "chain_phase": "Inference",
                                           "runtime": {"phase": "active", "requests_blocked": False,
                                                       "session_version": "v6"}}]},
            "/epoch": {"epoch_group_data": {"epoch_index": "7"}},
            "/epoch-info": {"latest_epoch": {"poc_start_block_height": "0"}},
            "/chain-status": {"result": {"sync_info": {"latest_block_height": "50"}}},
            "/params": {"params": {"epoch_params": {"epoch_length": "100", "poc_stage_duration": "2",
                "poc_exchange_duration": "2", "poc_validation_delay": "2", "poc_validation_duration": "2",
                "set_new_validators_delay": "2"}, "devshard_escrow_params": {"approved_versions": [
                    V6]}}},
            "/approved": {"versions": [V6]},
        }
        path = {"/productscience/inference/inference/current_epoch_group_data": "/epoch",
                "/productscience/inference/inference/epoch_info": "/epoch-info",
                "/productscience/inference/inference/params": "/params",
                "/status": "/chain-status"}.get(self.path, self.path)
        if path not in payloads:
            self.send_error(404)
            return
        if path == "/chain-status" and os.path.exists(os.environ.get("GDC_TEST_POC_FENCE_FILE", "")):
            payloads[path]["result"]["sync_info"]["latest_block_height"] = "1"
        encoded = json.dumps(payloads[path]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        # This fixture deliberately accepts the adapter's provider request and
        # returns one OpenAI completion; caller assertions prove each returned
        # public protocol is transformed back to its native response shape.
        if not isinstance(body, dict):
            self.send_error(400, "Bifrost provider request must be JSON")
            return
        marker = body.get("messages", [{}])[-1].get("content", "")
        request_id = REQUEST_IDS.get(marker, "fixture-native-request")
        tracked = marker in REQUEST_IDS
        if tracked:
            with REQUEST_LOCK:
                REQUESTS.append(marker)
            time.sleep(0.2)
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("X-Request-Id", "fixture-native-stream")
            self.send_header("X-Devshard-ID", "41")
            self.end_headers()
            for content, finish in (("fixture-ok", None), ("", "stop")):
                event = {"id": "fixture", "object": "chat.completion.chunk", "created": 1,
                         "model": "test-model", "choices": [{"index": 0,
                         "delta": {"content": content}, "finish_reason": finish}]}
                self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
                self.wfile.flush()
                time.sleep(0.1)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        response = json.dumps({
            "id": "fixture", "object": "chat.completion", "created": 1, "model": "test-model",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": marker if tracked else "fixture-ok"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("X-Request-Id", request_id)
        self.send_header("X-Devshard-ID", "fixture-native-escrow")
        self.send_header("Content-Length", str(len(response))); self.end_headers(); self.wfile.write(response)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
