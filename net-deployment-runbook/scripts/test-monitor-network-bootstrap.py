#!/usr/bin/env python3
"""Behavioral checks; only loopback HTTP/TCP and synthetic Telegram credentials."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("monitor", ROOT / "scripts/monitor-network-bootstrap.py")
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)
SCHEMA = json.loads((ROOT / "bootstrap/v1.bootstrap.schema.json").read_text())
RAW_GENESIS = b'{ "chain_id": "gonka-fixture", "memo": "escaped \\" }", "app_state": {} }'


class Fixture:
    def __init__(self):
        self.routes = {}
        self.requests = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                fixture.requests.append((self.server.server_port, self.path))
                value = fixture.routes.get((self.server.server_port, self.path), (404, b"missing"))
                if isinstance(value, list):
                    value = value.pop(0)
                code, body = value
                if not isinstance(body, bytes):
                    body = json.dumps(body).encode()
                self.send_response(code)
                if code == 302:
                    self.send_header("Location", "/redirect-target")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.servers = [ThreadingHTTPServer(("127.0.0.1", 0), Handler) for _ in range(2)]
        for server in self.servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        self.origins = [f"http://127.0.0.1:{server.server_port}" for server in self.servers]
        self.url = self.origins[0] + "/gonka-fixture/bootstrap.json"
        self.schema_url = self.origins[0] + "/schema.json"
        self.doc = {
            "$schema": SCHEMA["$id"], "chain_id": "gonka-fixture",
            "genesis": {"sha256": hashlib.sha256(RAW_GENESIS).hexdigest()},
            "seeds": [{"node_id": str(index + 1) * 40,
                       "rpc": origin + "/chain-rpc",
                       "p2p": origin.replace("http:", "tcp:"),
                       "api": origin} for index, origin in enumerate(self.origins)],
            "brokers": [],
        }
        self.route(0, "/gonka-fixture/bootstrap.json", self.doc)
        for index, seed in enumerate(self.doc["seeds"]):
            self.route(index, "/chain-rpc/status", {"result": {"node_info": {
                "id": seed["node_id"], "network": "gonka-fixture"}}})
            self.route(index, "/chain-rpc/genesis", b'{"result":{"genesis":' + RAW_GENESIS + b'}}')
            self.route(index, "/v1/participants", {"participants": []})

    def route(self, index, path, body, status=200):
        self.routes[(self.servers[index].server_port, path)] = (status, body)

    def close(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()


class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = Fixture()

    @classmethod
    def tearDownClass(cls):
        cls.fixture.close()

    def setUp(self):
        self.saved_routes = copy.deepcopy(self.fixture.routes)
        self.doc = copy.deepcopy(self.fixture.doc)
        self.transport = monitor.Transport(timeout=1, attempts=1)

    def tearDown(self):
        self.fixture.routes = self.saved_routes

    def check(self, schema=SCHEMA):
        self.fixture.route(0, "/gonka-fixture/bootstrap.json", self.doc)
        return monitor.check_bootstrap("gonka-fixture", self.fixture.url, schema, self.transport)

    def test_healthy_checks_every_seed(self):
        result = self.check()
        self.assertTrue(result["ok"], result)
        self.assertEqual([item["stage"] for item in result["checks"]],
                         ["bootstrap", "rpc", "genesis", "p2p", "api", "rpc", "genesis", "p2p", "api"])

    def test_wrong_node_chain_genesis_and_api_do_not_skip_other_seed(self):
        for kind, body in (("node", {"id": "0" * 40, "network": "gonka-fixture"}),
                           ("chain", {"id": "1" * 40, "network": "another-chain"})):
            with self.subTest(kind=kind):
                self.fixture.route(0, "/chain-rpc/status", {"result": {"node_info": body}})
                self.fixture.route(0, "/chain-rpc/genesis", b'{"result":{"genesis":{"chain_id":"other"}}}')
                self.fixture.route(0, "/v1/participants", {"message": "not participants"})
                result = self.check()
                self.assertFalse(result["ok"])
                self.assertEqual([c["stage"] for c in result["checks"] if not c["ok"]], ["rpc", "genesis", "api"])
                self.assertTrue(all(c["ok"] for c in result["checks"][-4:]))

    def test_wrong_bootstrap_chain_is_rejected(self):
        self.doc["chain_id"] = "gonka-wrong"
        self.assertIn("chain ID", self.check()["checks"][0]["error"])

    def test_wrong_genesis_chain_even_with_matching_hash(self):
        raw = b'{"chain_id":"other"}'
        self.doc["genesis"]["sha256"] = hashlib.sha256(raw).hexdigest()
        self.fixture.route(0, "/chain-rpc/genesis", b'{"result":{"genesis":' + raw + b'}}')
        errors = self.check()["checks"]
        self.assertIn("genesis chain ID", errors[2]["error"])

    def test_schema_and_semantic_failures_prevent_seed_requests(self):
        for change in (lambda d: d.pop("genesis"),
                       lambda d: d["seeds"][1].update(node_id=d["seeds"][0]["node_id"]),
                       lambda d: d["seeds"][0].update(api="https://secret:password@example.net")):
            self.doc = copy.deepcopy(self.fixture.doc)
            change(self.doc)
            result = self.check()
            self.assertFalse(result["ok"])
            self.assertEqual(len(result["checks"]), 1)

    def test_published_schema_extension_is_used(self):
        schema = copy.deepcopy(SCHEMA)
        schema["properties"]["software"] = {"type": "object"}
        self.doc["software"] = {}
        self.assertTrue(self.check(schema)["ok"])
        self.assertFalse(self.check()["ok"])

    def test_refused_p2p_and_unavailable_http_are_reported(self):
        with socket.socket() as refused:
            # Reserve a port without listening: real P2P refusal, HTTP remains available.
            refused.bind(("127.0.0.1", 0))
            self.doc["seeds"][0]["p2p"] = f"tcp://127.0.0.1:{refused.getsockname()[1]}"
            self.fixture.route(0, "/chain-rpc/status", b"offline", 503)
            result = self.check()
        self.assertEqual([c["stage"] for c in result["checks"] if not c["ok"]], ["rpc", "p2p"])

    def test_real_http_limits_retries_and_redirects(self):
        origin = self.fixture.origins[0]
        self.fixture.route(0, "/large", b"x" * 11)
        with self.assertRaisesRegex(monitor.MonitorError, "size limit"):
            self.transport.get(origin + "/large", limit=10)
        self.fixture.route(0, "/redirect", b"", 302)
        with self.assertRaisesRegex(monitor.MonitorError, "redirect refused"):
            self.transport.get(origin + "/redirect")
        route = (self.fixture.servers[0].server_port, "/retry")
        self.fixture.routes[route] = [(503, b"down"), (200, b"recovered")]
        with patch.object(monitor.time, "sleep"):
            self.assertEqual(monitor.Transport(timeout=1).get(origin + "/retry"), b"recovered")
        self.fixture.route(0, "/retry", b"down", 503)
        previous = self.fixture.requests.count(route)
        with patch.object(monitor.time, "sleep"), self.assertRaisesRegex(monitor.MonitorError, "HTTP 503"):
            monitor.Transport(timeout=1).get(origin + "/retry")
        self.assertEqual(self.fixture.requests.count(route) - previous, 2)

    def test_cli_writes_report_and_ci_output_on_success_and_failure(self):
        # Real subprocess, actual HTTP and TCP; only the fixed schema origin is redirected to loopback.
        schema = copy.deepcopy(SCHEMA)
        schema["$id"] = self.fixture.schema_url
        self.fixture.route(0, "/schema.json", schema)
        loader = ("import importlib.util,sys; "
                  "s=importlib.util.spec_from_file_location('monitor',sys.argv[1]); "
                  "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                  "m.SCHEMA_URL=sys.argv[2]; sys.exit(m.main(sys.argv[3:]))")
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            (directory / "gonka-fixture.json").write_text("{}")
            report = directory / "report.json"
            output = directory / "output"
            args = [sys.executable, "-c", loader, str(ROOT / "scripts/monitor-network-bootstrap.py"),
                    self.fixture.schema_url, "check", "--release-dir", str(directory),
                    "--base-url", self.fixture.origins[0], "--report", str(report)]
            for expected in (0, 1):
                if expected:
                    self.fixture.route(0, "/gonka-fixture/bootstrap.json", b"{broken")
                result = subprocess.run(args, env={**os.environ, "GITHUB_OUTPUT": str(output)},
                                        text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
                self.assertEqual(json.loads(report.read_text())["results"][0]["ok"], expected == 0)
            self.assertEqual(output.read_text(), "failed=false\nfailed=true\n")


class ParsingTests(unittest.TestCase):
    def test_raw_genesis_preserves_bytes(self):
        for raw in (RAW_GENESIS, '{\n "chain_id": "gonka-fixture", "unicode": "ж"\n}'.encode()):
            payload = b'{"id":1,"result":{"extra":"{\\\"genesis\\\":0}","genesis": \n' + raw + b',"after":[]}}'
            self.assertEqual(monitor.genesis_bytes(payload), raw)

    def test_strict_json_rejects_duplicates_and_constants(self):
        for raw in (b'{"a":1,"a":2}', b'{"x":NaN}', b'{"x":Infinity}'):
            with self.assertRaises(monitor.MonitorError):
                monitor.strict_json(raw)
        for raw in (b'null', b'[]', b'{"result":null}', b'{"result":{"genesis":[]}}'):
            with self.assertRaises(monitor.MonitorError):
                monitor.genesis_bytes(raw)

    def test_schema_failure_marks_all_networks_and_refuses_external_refs(self):
        class Transport:
            def get(self, url):
                return json.dumps({"$id": monitor.SCHEMA_URL, "$ref": "https://untrusted.invalid/schema"}).encode()
        results = monitor.run_checks([("gonka-a", "https://example.net/a"),
                                     ("gonka-b", "https://example.net/b")], Transport())
        self.assertEqual(len(results), 2)
        self.assertTrue(all(not r["ok"] and r["checks"][0]["stage"] == "schema" for r in results))
        self.assertIn("external schema references", results[0]["checks"][0]["error"])

    def test_inventory_adds_new_networks_and_rejects_empty_inventory(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            with self.assertRaises(monitor.MonitorError):
                monitor.targets(directory, "https://example.net")
            for name in ("gonka-new.json", "gonka-testnet.json", "v1.bootstrap.schema.json"):
                (directory / name).touch()
            self.assertEqual(monitor.targets(directory, "https://example.net/"), [
                ("gonka-new", "https://example.net/gonka-new/bootstrap.json"),
                ("gonka-testnet", "https://example.net/gonka-testnet/bootstrap.json")])


class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.environment = {"GDC_TELEGRAM_BOT_TOKEN": "123:synthetic", "GDC_TELEGRAM_NOTIFICATION": "-456",
                            "GITHUB_RUN_ID": "789", "GITHUB_REPOSITORY": "owner/repo"}
        self.result = {"chain_id": "gonka-testnet", "bootstrap_url": "https://example.net/bootstrap.json", "ok": False}

    def test_exact_message_and_one_notification_per_failed_network(self):
        sent = []
        result = monitor.notify([self.result, {**self.result, "ok": True}], self.environment,
                                sender=lambda token, payload: sent.append((token, payload)))
        self.assertEqual(result, 0)
        self.assertEqual(sent, [("123:synthetic", {
            "chat_id": "-456", "parse_mode": "HTML",
            "text": '<b>⚠️ Warning:</b> The Bootstrap <a href="https://example.net/bootstrap.json">gonka-testnet</a> needs to be updated, validation for <a href="https://github.com/owner/repo/actions/runs/789">789</a> failed'})])

    def test_html_is_escaped_and_json_serializes(self):
        payload = monitor.telegram_payload({**self.result, "chain_id": '<b>&"',
                                            "bootstrap_url": 'https://example.net/?a="&b=1'},
                                           'chat"id', "https://github.com/run/1", "1<2")
        self.assertIn("&lt;b&gt;&amp;&quot;", payload["text"])
        self.assertIn("?a=&quot;&amp;b=1", payload["text"])
        self.assertEqual(json.loads(json.dumps(payload)), payload)

    def test_no_failures_need_no_secrets_and_missing_secrets_fail_closed(self):
        self.assertEqual(monitor.notify([{**self.result, "ok": True}], {}), 0)
        with self.assertRaises(monitor.MonitorError):
            monitor.notify([self.result], {})

    def test_send_failure_does_not_skip_next_network(self):
        sent = []
        def sender(token, payload):
            sent.append(payload)
            if len(sent) == 1:
                raise monitor.MonitorError("synthetic failure")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(monitor.notify([self.result, self.result], self.environment, sender), 1)
        self.assertEqual(len(sent), 2)

    def test_telegram_post_body_and_no_credential_leak_or_retry(self):
        payload = monitor.telegram_payload(self.result, "-456", "https://github.com/run/789", "789")
        with patch.object(monitor, "build_opener") as build:
            build.return_value.open.return_value.__enter__.return_value.read.return_value = b'{"ok":true}'
            monitor.send_telegram("123:synthetic", payload)
            request = build.return_value.open.call_args.args[0]
            self.assertEqual(request.method, "POST")
            self.assertEqual(request.headers["Content-type"], "application/json")
            self.assertEqual(json.loads(request.data), payload)
        for problem in (HTTPError("https://api.telegram.org/bot123:synthetic/sendMessage", 403, "secret", {}, None),
                        b'{"ok":false,"description":"123:synthetic"}', b'not JSON'):
            with patch.object(monitor, "build_opener") as build:
                if isinstance(problem, Exception):
                    build.return_value.open.side_effect = problem
                else:
                    build.return_value.open.return_value.__enter__.return_value.read.return_value = problem
                with self.assertRaises(monitor.MonitorError) as caught:
                    monitor.send_telegram("123:synthetic", payload)
                self.assertNotIn("synthetic", str(caught.exception))
                self.assertEqual(build.return_value.open.call_count, 1)


if __name__ == "__main__":
    unittest.main()
