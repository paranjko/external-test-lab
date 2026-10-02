#!/usr/bin/env python3
"""Local HTTP evidence, deadline and secret-boundary contracts."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("transport", Path(__file__).resolve().parents[1] / "04-ops/devshard-transport.py")
t = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(t)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.server.calls.append({"method": self.command, "path": self.path, "headers": dict(self.headers), "body": body})
        mode = self.server.mode
        if mode == "slow-headers":
            try:
                self.wfile.write(b"HTTP/1.1 200 OK\r\n")
                for index in range(8):
                    self.wfile.write(f"X-Delay-{index}: value\r\n".encode())
                    self.wfile.flush()
                    time.sleep(.04)
                self.wfile.write(b"Content-Length: 0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://192.0.2.1:8080/credential-sink")
            self.end_headers()
            return
        self.send_response(200)
        if mode == "truncated":
            self.send_header("Content-Length", "99")
        elif mode == "length-and-close":
            self.send_header("Content-Length", "16")
            self.send_header("Connection", "close")
        self.end_headers()
        try:
            if mode == "sse":
                self.wfile.write(b'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n')
                self.wfile.flush()
                time.sleep(.12)
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n')
            elif mode == "slow":
                self.wfile.write(b"partial")
                self.wfile.flush()
                time.sleep(.3)
                self.wfile.write(b"late")
            elif mode == "invalid-utf8":
                self.wfile.write(b"\xff")
            elif mode == "invalid-json":
                self.wfile.write(b'{"unfinished":')
            elif mode == "oversize":
                self.wfile.write(b"x" * (t.MAX_BODY + 2))
            else:
                self.wfile.write(b'{"fixture":true}')
        except (BrokenPipeError, ConnectionResetError):
            pass


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        root.chmod(0o700)
        secrets, endpoints = {}, {}
        self.servers = {}
        for i, name in enumerate(("A", "B"), 1):
            directory = root / name
            directory.mkdir(mode=0o700)
            secret = directory / "gateway.env"
            secret.write_text(f"DEVSHARD_PRIVATE_KEY={i:064x}\nDEVSHARD_ADMIN_API_KEY=fixture-{name}-admin-key-not-for-live\n"
                              f"DEVSHARD_API_KEYS=fixture-{name}-client-key-not-for-live\n")
            secret.chmod(0o600)
            secrets[name] = secret
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.mode, server.calls = "json", []
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            self.servers[name] = server
            endpoints[name] = f"http://127.0.0.1:{server.server_port}"
        self.transport = t.Transport(endpoints, secrets)
        self.secrets = {}
        for name in ("A", "B"):
            key = root / name / "client.key"
            key.write_text(f"fixture-{name}-client-key-not-for-live\n")
            key.chmod(0o600)
            self.secrets[name] = key

    def test_public_transport_is_tls_client_only_with_explicit_prefix(self):
        public = t.PublicTransport({"A": "https://example.test/a", "B": "https://example.test/b"}, self.secrets)
        self.assertEqual(public.request_path("B", "/v1/chat/completions"), "/b/v1/chat/completions")
        self.assertEqual(set(public.keys["A"]), {"client"})
        self.secrets["A"].write_text("DEVSHARD_PRIVATE_KEY=do-not-export\nDEVSHARD_API_KEYS=client-secret\n")
        with self.assertRaisesRegex(ValueError, "client-only"):
            t.PublicTransport({"A": "https://example.test/a", "B": "https://example.test/b"}, self.secrets)
        self.secrets["A"].write_text("fixture-A-client-key-not-for-live\n")
        with patch.object(t.http.client, "HTTPSConnection") as constructor:
            public.connection("A")
            constructor.assert_called_once_with("example.test", 443)
        with self.assertRaises(ValueError):
            public.observe("A", "/v1/admin/devshards", time.monotonic() + 2)
        for url in ("http://example.test/a", "https://user:secret@example.test/a", "https://example.test/a?x=1",
                    "https://example.test/a/../admin", "https://example.test/a#fragment"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                t.PublicTransport({"A": url, "B": "https://example.test/b"}, self.secrets)

    def test_public_transport_reuses_single_dispatch_and_streaming_deadline(self):
        public = t.PublicTransport({"A": "https://example.test/a", "B": "https://example.test/b"}, self.secrets)
        public.connection = self.transport.connection
        self.servers["A"].mode = "sse"
        result = public.send("A", b'{"stream":true}', time.monotonic() + 2, "public-test")
        self.assertTrue(result["body_complete"])
        self.assertGreaterEqual(result["ttft_seconds"], .1)
        calls = self.servers["A"].calls
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["path"], "/a/v1/chat/completions")
        self.assertEqual(calls[0]["headers"]["Authorization"], "Bearer fixture-A-client-key-not-for-live")

    def send(self, name="A", duration=2):
        return self.transport.send(name, b'{"stream":true}', time.monotonic() + duration, "fixture-request-1")

    def test_single_dispatch_client_key_and_separate_admin_observation(self):
        result = self.send()
        self.assertTrue(result["body_complete"])
        self.assertIsNone(result["transport_error"])
        self.assertEqual(result["body"], '{"fixture":true}')
        self.assertEqual(len(self.servers["A"].calls), 1)
        call = self.servers["A"].calls[0]
        self.assertEqual(call["headers"]["Authorization"], "Bearer fixture-A-client-key-not-for-live")
        self.assertEqual(call["body"], b'{"stream":true}')
        observed = self.transport.observe("B", "/v1/admin/devshards", time.monotonic() + 2)
        self.assertEqual(observed["value"], {"fixture": True})
        self.assertEqual(self.servers["B"].calls[0]["headers"]["Authorization"], "Bearer fixture-B-admin-key-not-for-live")
        self.assertNotIn("fixture-A-client-key", json.dumps(result))

    def test_ttft_waits_for_content_not_role_or_headers(self):
        self.servers["A"].mode = "sse"
        result = self.send()
        self.assertGreaterEqual(result["ttft_seconds"], .1)
        self.assertLessEqual(result["ttft_seconds"], result["elapsed_seconds"])
        self.assertIsNone(result["transport_error"])

    def test_content_length_completion_survives_socket_close(self):
        self.servers["A"].mode = "length-and-close"
        result = self.send()
        self.assertEqual(result["body"], '{"fixture":true}')
        self.assertTrue(result["body_complete"])
        self.assertIsNone(result["transport_error"])
        self.assertEqual(len(self.servers["A"].calls), 1)

    def test_timeout_retains_partial_body_without_retry(self):
        self.servers["A"].mode = "slow"
        result = self.send(duration=.1)
        self.assertEqual(result["body"], "partial")
        self.assertEqual(result["transport_error"], "TimeoutError")
        self.assertFalse(result["body_complete"])
        self.assertLess(result["elapsed_seconds"], .3)
        self.assertEqual(len(self.servers["A"].calls), 1)

    def test_redirect_is_retained_and_never_followed(self):
        self.servers["A"].mode = "redirect"
        result = self.send()
        self.assertEqual(result["http_status"], 302)
        self.assertEqual(len(self.servers["A"].calls), 1)

    def test_absolute_deadline_interrupts_trickling_response_headers(self):
        self.servers["A"].mode = "slow-headers"
        result = self.send(duration=.1)
        self.assertFalse(result["body_complete"])
        self.assertEqual(result["transport_error"], "TimeoutError")
        self.assertLess(result["elapsed_seconds"], .25)
        self.assertEqual(len(self.servers["A"].calls), 1)

    def test_truncated_http_and_invalid_utf8_are_not_complete(self):
        for mode in ("truncated", "invalid-utf8"):
            self.servers["A"].mode = mode
            result = self.send()
            self.assertFalse(result["body_complete"])
            self.assertIsNotNone(result["transport_error"])
        self.assertEqual(result["body_hex"], "ff")

    def test_response_size_bound_retains_failure(self):
        self.servers["A"].mode = "oversize"
        result = self.send()
        self.assertEqual(result["transport_error"], "ValueError")
        self.assertFalse(result["body_complete"])
        self.assertEqual(len(result["body"]), t.MAX_BODY + 1)

    def test_endpoint_and_operation_scope_reject_before_io(self):
        for value in ("https://127.0.0.1:8000", "http://localhost:8000", "http://169.254.169.254:8080",
                      "http://8.8.8.8:8080", "http://u:p@127.0.0.1:8000", "http://127.0.0.1:8000/path"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                t.endpoint(value)
        with self.assertRaises(ValueError):
            self.transport.request("A", "POST", "/v1/admin/settings", "admin", time.monotonic() + 1, b"{}")
        with self.assertRaises(ValueError):
            self.transport.send("A", b"{}", time.monotonic() - 1, "id")
        self.assertFalse(self.servers["A"].calls)

    def test_failed_observations_retain_http_or_decode_receipts(self):
        for mode in ("redirect", "slow", "invalid-json"):
            with self.subTest(mode=mode):
                self.servers["A"].mode = mode
                count = len(self.servers["A"].calls)
                with self.assertRaises(t.ObservationError) as caught:
                    self.transport.observe("A", "/v1/admin/devshards", time.monotonic() + .1)
                receipt = caught.exception.receipt
                self.assertEqual(receipt["gateway"], "A")
                self.assertEqual(receipt["path"], "/v1/admin/devshards")
                self.assertIn("body", receipt["response"])
                self.assertNotIn("fixture-A-admin-key", json.dumps(receipt))
                self.assertEqual(len(self.servers["A"].calls), count + 1)
                if mode == "slow":
                    self.assertEqual(receipt["response"]["body"], "partial")
                elif mode == "invalid-json":
                    self.assertEqual(receipt["response"]["body"], '{"unfinished":')


if __name__ == "__main__":
    unittest.main(verbosity=2)
