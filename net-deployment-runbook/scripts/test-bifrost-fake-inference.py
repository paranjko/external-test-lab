#!/usr/bin/env python3
"""Fixture response headers never interpolate client message content."""
import http.client
import importlib.util
import json
from pathlib import Path
import threading
import unittest

spec = importlib.util.spec_from_file_location(
    "fake_inference", Path(__file__).with_name("bifrost-fake-inference.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class ResponseHeaders(unittest.TestCase):
    def test_request_ids_are_constants_on_the_wire(self):
        server = fixture.ThreadingHTTPServer(("127.0.0.1", 0), fixture.Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            cases = [
                ("receipt-one", "fixture-native-receipt-one"),
                ("receipt-two", "fixture-native-receipt-two"),
                ("receipt-fenced", "fixture-native-receipt-fenced"),
                ("ordinary", "fixture-native-request"),
                ("receipt-one\r\nX-Injected: yes", "fixture-native-request"),
                ("receipt-two\nX-Injected: yes", "fixture-native-request"),
            ]
            for marker, expected in cases:
                with self.subTest(marker=marker):
                    connection = http.client.HTTPConnection(*server.server_address, timeout=5)
                    try:
                        connection.request("POST", "/v1/chat/completions", json.dumps({
                            "messages": [{"role": "user", "content": marker}]}),
                            {"Content-Type": "application/json"})
                        response = connection.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.getheader("X-Request-Id"), expected)
                        self.assertIsNone(response.getheader("X-Injected"))
                        json.loads(response.read())
                    finally:
                        connection.close()
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
