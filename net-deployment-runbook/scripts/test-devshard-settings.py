#!/usr/bin/env python3
"""Exercise the actual HTTP settings client against a loopback mock gateway."""

import copy
import fcntl
import importlib.util
import json
import subprocess
import threading
import tempfile
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SPEC = importlib.util.spec_from_file_location("settings", Path(__file__).resolve().parents[1] / "04-ops/devshard-settings.py")
settings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(settings)
MODEL = "Qwen/Qwen3-0.6B"


class HTTPSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.secret = self.directory / "secret.env"
        self.secret.write_text("DEVSHARD_PRIVATE_KEY=" + "1" * 64 + "\n"
                               "DEVSHARD_ADMIN_API_KEY=synthetic-admin-key-000000000\n"
                               "DEVSHARD_API_KEYS=synthetic-client-key-00000000\n")
        self.secret.chmod(0o600)
        self.value = {"default_model": "other", "unknown": {"retain": [3, False]},
                      "model_limits": [{"model_id": MODEL, "access_mode": "public", "limit": 77}],
                      "escrow_rotation": {"enabled": True, "settlement_enabled": True, "future": 42},
                      "participant_throttle": {"request_burst": 600, "recovery_per_minute": 10,
                                               "future": "preserve"}}
        self.initial = copy.deepcopy(self.value)
        self.posts = 0
        self.gets = 0
        self.drop_response = False
        self.discard_unknown = False
        self.drift = False
        self.models = [MODEL]
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def authorized(self):
                if self.headers.get("Authorization") != "Bearer synthetic-admin-key-000000000":
                    self.send_error(401)
                    return False
                return True

            def send_json(self, value):
                encoded = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self):
                if not self.authorized():
                    return
                if self.path == "/v1/admin/settings":
                    owner.gets += 1
                    if owner.drift and owner.gets == 2:
                        owner.value["unknown"]["concurrent"] = True
                    self.send_json(owner.value)
                elif self.path == "/v1/models":
                    self.send_json({"data": [{"id": name} for name in owner.models]})
                else:
                    self.send_error(404)

            def do_POST(self):
                if not self.authorized():
                    return
                if self.path != "/v1/admin/settings":
                    self.send_error(404)
                    return
                owner.posts += 1
                owner.value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if owner.discard_unknown:
                    owner.value.pop("unknown", None)
                if owner.drop_response:
                    self.close_connection = True
                    return
                self.send_json({"ok": True})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)
        self.gateway = settings.Gateway(self.server.server_port, self.secret)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def journal(self, suffix):
        return settings.Journal(self.directory / suffix)

    def test_preview_then_post_full_settings_and_readback(self):
        receipt = settings.configure(self.gateway, self.journal("preview"), MODEL)
        self.assertFalse(receipt["applied"])
        self.assertEqual(self.posts, 0)
        result = settings.configure(self.gateway, self.journal("apply"), MODEL,
                                    receipt["before_sha256"], True)
        self.assertEqual(result["outcome"], "PASS")
        self.assertEqual(self.posts, 1)
        self.assertEqual(self.value, settings.instances.settings(self.initial, MODEL, [MODEL]))
        self.assertEqual(self.value["participant_throttle"], {
            "request_burst": settings.instances.TEST_STAND_PARTICIPANT_BUDGET,
            "recovery_per_minute": settings.instances.TEST_STAND_PARTICIPANT_BUDGET,
            "future": "preserve",
        })
        for path in (self.directory / "apply").iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("synthetic-admin-key", path.read_text())
        with self.assertRaises(FileExistsError):
            self.journal("apply")

    def test_stale_preimage_and_concurrent_change_do_not_post(self):
        with self.assertRaisesRegex(ValueError, "preimage"):
            settings.configure(self.gateway, self.journal("stale"), MODEL, "0" * 64, True)
        self.assertEqual(self.posts, 0)
        self.gets = 0
        self.drift = True
        with self.assertRaisesRegex(ValueError, "drift"):
            settings.configure(self.gateway, self.journal("drift"), MODEL,
                               settings.instances.preview.digest(self.initial), True)
        self.assertEqual(self.posts, 0)

    def test_uncertain_post_is_never_retried_or_restored(self):
        self.drop_response = True
        with self.assertRaisesRegex(ValueError, "no automatic retry"):
            settings.configure(self.gateway, self.journal("uncertain"), MODEL,
                               settings.instances.preview.digest(self.initial), True)
        self.assertEqual(self.posts, 1)
        self.assertTrue(self.value["escrow_rotation"]["settlement_enabled"])
        terminal = next((self.directory / "uncertain").glob("*-terminal.json"))
        self.assertEqual(json.loads(terminal.read_text())["outcome"], "INCONCLUSIVE")

    def test_unknown_field_loss_fails_readback(self):
        self.discard_unknown = True
        with self.assertRaisesRegex(ValueError, "readback mismatch"):
            settings.configure(self.gateway, self.journal("loss"), MODEL,
                               settings.instances.preview.digest(self.initial), True)
        self.assertEqual(self.posts, 1)

    def test_absent_model_refuses_mutation(self):
        self.models = []
        with self.assertRaisesRegex(ValueError, "catalog"):
            settings.configure(self.gateway, self.journal("absent"), MODEL,
                               settings.instances.preview.digest(self.initial), True)
        self.assertEqual(self.posts, 0)

    def test_fresh_gateway_without_model_limits_preserves_global_defaults(self):
        self.value.pop("model_limits")
        self.value.update(max_concurrent_requests=512, max_input_tokens_in_flight=0)
        before = copy.deepcopy(self.value)
        preview = settings.configure(self.gateway, self.journal("fresh-preview"), MODEL)
        result = settings.configure(self.gateway, self.journal("fresh-apply"), MODEL,
                                    preview["before_sha256"], True)
        self.assertEqual(result["outcome"], "PASS")
        self.assertEqual(self.value["model_limits"], [{"model_id": MODEL, "access_mode": "api_key",
                         "max_concurrent_requests": 512, "max_input_tokens_in_flight": 0}])
        self.assertEqual(self.value["unknown"], before["unknown"])
        self.assertEqual(self.value["max_concurrent_requests"], 512)
        self.assertEqual(self.posts, 1)

    def test_missing_or_invalid_participant_throttle_refuses_mutation(self):
        for throttle in (None, {}, {"request_burst": 0, "recovery_per_minute": 1},
                         {"request_burst": 1, "recovery_per_minute": "1"}):
            with self.subTest(throttle=throttle):
                self.value = copy.deepcopy(self.initial)
                if throttle is None:
                    self.value.pop("participant_throttle")
                else:
                    self.value["participant_throttle"] = throttle
                with self.assertRaisesRegex(ValueError, "participant throttle"):
                    settings.configure(self.gateway, self.journal(f"throttle-{len(str(throttle))}"), MODEL)
                self.assertEqual(self.posts, 0)

    def test_cli_lock_refuses_overlap_before_request(self):
        lock = self.secret.parent / ".settings.lock"
        with lock.open("w") as stream:
            lock.chmod(0o600)
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            process = subprocess.run([
                "python3", str(Path(settings.__file__)), "--port", str(self.server.server_port),
                "--secret-file", str(self.secret), "--model", MODEL,
                "--evidence", str(self.directory / "overlap"),
            ], capture_output=True, text=True)
        self.assertEqual(process.returncode, 2)
        self.assertEqual(self.gets, 0)
        self.assertEqual(self.posts, 0)
        self.assertFalse((self.directory / "overlap").exists())
        self.assertNotIn("synthetic-admin-key", process.stderr + process.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
