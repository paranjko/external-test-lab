"""gcheck against a local fake gateway: no request leaves the machine."""

import contextlib
import hashlib
import io
import json
import os
import subprocess
import tempfile
import time
import unittest

from gonka_check import cli
from gonka_check.preflight import health_blocker, status_blocker
from gonka_check.summary import SSL_HINT, hints
from gonka_check.record import Recorder
from gonka_check.scheduler import RunLock
from gonka_check.target import ROOT, TargetRefused, load_preset
from gonka_check.transport import Client

from tests.fake_gateway import EPOCH_LENGTH, FakeGateway


KEY = "sk-fake-" + "c" * 24


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {name: os.environ.get(name) for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME")}
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "config")
        os.environ["XDG_DATA_HOME"] = os.path.join(self.tmp.name, "data")
        self.config = os.path.join(self.tmp.name, "config", "gonka-check")
        os.makedirs(self.config)
        self.key_file = os.path.join(self.config, "fake.key")
        with open(self.key_file, "w", encoding="utf-8") as handle:
            handle.write(KEY + "\n")
        os.chmod(self.key_file, 0o600)

    def tearDown(self):
        for name, value in self.env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def gcheck(self, fake, *args, **preset_overrides):
        path = os.path.join(self.tmp.name, "preset-%d.json" % time.monotonic_ns())
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(fake.preset(**preset_overrides), handle)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["run", "--preset", path, "--wait", "2"] + list(args))
        self.stderr = err.getvalue()
        summary = None
        if code != 4 or "records" in out.getvalue():
            run_dir = out.getvalue().rsplit("records  ", 1)[1].strip()
            with open(os.path.join(run_dir, "summary.json"), encoding="utf-8") as handle:
                summary = json.load(handle)
        return code, summary

    def verdicts(self, summary):
        return {item["check"]: item["verdict"] for item in summary["verdicts"]}

    def assert_key_only_in_posts(self, fake, summary):
        for request in fake.requests:
            if request["method"] == "POST":
                self.assertEqual(request["authorization"], "Bearer " + KEY)
            else:
                self.assertIsNone(request["authorization"], request["path"])
        for folder, _dirs, files in os.walk(os.path.join(self.tmp.name, "data")):
            for name in files:
                with open(os.path.join(folder, name), encoding="utf-8") as handle:
                    self.assertNotIn(KEY, handle.read(), name)
        with open(os.path.join(summary["run_dir"], "manifest.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
        self.assertEqual(manifest["key_sha256_prefix"], hashlib.sha256(KEY.encode()).hexdigest()[:12])

    def assert_no_forbidden_paths(self, fake):
        for request in fake.requests:
            self.assertFalse(request["path"].startswith(("/status/gateway/", "/v1/admission-status", "/elsewhere")),
                             request["path"])


class DryRun(Harness):
    def test_ready_sends_no_completion(self):
        with FakeGateway() as fake:
            code, summary = self.gcheck(fake, "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(summary["overall"], "READY")
        self.assertEqual(fake.posts, [])
        self.assert_no_forbidden_paths(fake)
        self.assert_key_only_in_posts(fake, summary)

    def test_poc_fence_health_is_blocked(self):
        with FakeGateway(health="poc_fence") as fake:
            code, summary = self.gcheck(fake, "--dry-run", "--wait", "0")
        self.assertEqual(code, 3)
        self.assertIn("poc_fence", " ".join(summary["readiness"]["reasons"]))
        self.assertEqual(fake.posts, [])

    def test_confirmation_poc_is_blocked(self):
        with FakeGateway(status="confirmation") as fake:
            code, summary = self.gcheck(fake, "--dry-run", "--wait", "0")
        self.assertEqual(code, 3)
        self.assertIn("CONFIRMATION_POC_GENERATION", " ".join(summary["readiness"]["reasons"]))

    def test_open_key_file_is_blocked(self):
        os.chmod(self.key_file, 0o644)
        with FakeGateway() as fake:
            code, summary = self.gcheck(fake, "--dry-run")
        self.assertEqual(code, 3)
        self.assertIn("key_permissions", " ".join(summary["readiness"]["reasons"]))


class Smoke(Harness):
    def test_ready_gateway_passes_with_two_posts(self):
        with FakeGateway() as fake:
            started_ms = time.time() * 1000
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 0, summary)
        self.assertEqual(self.verdicts(summary), {
            "model_served": "PASS", "canary": "PASS", "floor64": "PASS", "fence_audit": "PASS"})
        self.assertEqual(len(fake.posts), 2)
        for post in fake.posts:
            deadline = int(post["deadline_ms"])
            self.assertGreater(deadline, started_ms + 55000)
            self.assertLess(deadline, post["at"] * 1000 + 61000)
            self.assertEqual(post["body"]["model"], "Qwen/Qwen3-0.6B")
        self.assertGreaterEqual(fake.posts[1]["height"] - fake.posts[0]["height"], 2)
        self.assert_key_only_in_posts(fake, summary)
        self.assert_no_forbidden_paths(fake)
        with open(os.path.join(self.config, "ledger.jsonl"), encoding="utf-8") as handle:
            self.assertEqual(len(handle.readlines()), 2)

    def test_sends_wait_for_the_window(self):
        with FakeGateway(offset=5) as fake:
            code, _summary = self.gcheck(fake)
        self.assertEqual(code, 0)
        offsets = [post["height"] % EPOCH_LENGTH for post in fake.posts]
        self.assertEqual(offsets[0], 29)
        self.assertIn("waiting for send window 29..50", self.stderr)
        self.assertTrue(all(29 <= offset <= 50 for offset in offsets), offsets)

    def test_output_floor_regression_fails(self):
        with FakeGateway(scenario="floor_broken") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 1)
        self.assertEqual(self.verdicts(summary)["floor64"], "FAIL")
        self.assertEqual(self.verdicts(summary)["canary"], "PASS")

    def test_permit_leak_stops_the_run(self):
        with FakeGateway(scenario="leak") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "permit_leak_suspected")
        self.assertEqual(len(fake.posts), 1)

    def test_dispatch_failure_stops_the_run(self):
        with FakeGateway(scenario="dispatch_fail") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "gateway_dispatch_failure")
        self.assertEqual(len(fake.posts), 1)

    def test_reply_without_admission_headers_stops_the_run(self):
        with FakeGateway(scenario="no_proxy") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "no_admission_header")

    def test_redirect_is_not_followed(self):
        with FakeGateway(scenario="redirect") as fake:
            code, _summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(len(fake.posts), 1)
        self.assert_no_forbidden_paths(fake)

    def test_protocol_misconfiguration_stops_at_once(self):
        with FakeGateway(scenario="misconfigured") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "proxy_misconfigured")
        self.assertEqual(self.verdicts(summary)["canary"], "FAIL")
        self.assertEqual(len(fake.posts), 1)

    def test_two_pre_dispatch_rejections_block(self):
        with FakeGateway(scenario="reject") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 3)
        self.assertTrue(summary["guard"]["blocked"])
        self.assertEqual(len(fake.posts), 2)

    def test_spent_epoch_budget_sends_nothing(self):
        with FakeGateway() as fake:
            epoch = fake.epoch()
            with open(os.path.join(self.config, "ledger.jsonl"), "w", encoding="utf-8") as handle:
                for _ in range(4):
                    handle.write(json.dumps({"target": fake.base_url, "epoch": epoch}) + "\n")
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 3)
        self.assertEqual(fake.posts, [])
        self.assertEqual(self.verdicts(summary)["canary"], "BLOCKED")

    def test_busy_lock_sends_nothing(self):
        with FakeGateway() as fake, RunLock(os.path.join(self.config, "run.lock")):
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 3)
        self.assertIn("lock", " ".join(summary["readiness"]["reasons"]))
        self.assertEqual(fake.posts, [])


class Guard(Harness):
    def test_foreign_target_is_refused(self):
        with FakeGateway() as fake:
            preset = fake.preset(base_url="https://example.com",
                                 chain_rpc="https://example.com/chain-rpc",
                                 chain_api="https://example.com/chain-api")
            path = os.path.join(self.tmp.name, "foreign.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(preset, handle)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["run", "--dry-run", "--preset", path]), 4)
            self.assertEqual(fake.requests, [])

    def test_forbidden_path_is_never_requested(self):
        with FakeGateway() as fake:
            path = os.path.join(self.tmp.name, "fake.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(fake.preset(), handle)
            client = Client(load_preset(path), Recorder(os.path.join(self.tmp.name, "run")))
            for forbidden in ("/status/gateway/v1/admission-status", "/v1/admission-status"):
                with self.assertRaises(TargetRefused):
                    client.get(fake.base_url + forbidden)
            with self.assertRaises(ValueError):
                client._send("GET", fake.base_url + "/v1/models", None, KEY, 5, None)
        self.assertEqual(fake.requests, [])

    def test_plan_runs_from_bin_without_network(self):
        result = subprocess.run([os.path.join(ROOT, "bin", "gcheck"), "plan"], capture_output=True, text=True,
                                env=dict(os.environ), check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("total    2 POST", result.stdout)


class Rules(unittest.TestCase):
    SINGLE = {"escrow_id": "1", "phase": "active", "requests_blocked": False, "chain_phase": "Inference",
              "confirmation_poc_phase": "CONFIRMATION_POC_INACTIVE", "height_seed": {"state": "ok"}}

    def test_status_rule(self):
        self.assertIsNone(status_blocker(self.SINGLE))
        self.assertIsNone(status_blocker(dict(self.SINGLE, height_seed=None)))
        self.assertEqual(status_blocker(dict(self.SINGLE, height_seed={"state": "missed"})), "height_seed=missed")
        self.assertIn("confirmation_poc_phase", status_blocker(
            dict(self.SINGLE, confirmation_poc_phase="CONFIRMATION_POC_GENERATION")))
        self.assertIn("requests_blocked", status_blocker(dict(self.SINGLE, requests_blocked=True)))
        pooled = {"capacity": {"total_weight": 5}, "devshards": [
            {"active": True, "runtime": {"phase": "active", "requests_blocked": False, "chain_phase": "Inference"}}]}
        self.assertIsNone(status_blocker(pooled))
        pooled["devshards"][0]["runtime"]["requests_blocked"] = True
        self.assertEqual(status_blocker(pooled), "runtime_not_routable")
        self.assertIsNone(status_blocker({"routable": True}))

    def test_ssl_failure_gets_a_hint(self):
        failed = {"readiness": {"reasons": ["chain: chain_unreachable (SSLCertVerificationError: "
                                            "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed)"]},
                  "verdicts": []}
        self.assertEqual(hints(failed), [SSL_HINT])
        self.assertEqual(hints({"readiness": {"reasons": ["key: key_missing"]}, "verdicts": []}), [])

    def test_health_rule(self):
        now = time.time()
        receipt = {"state": "READY", "readiness": "TRAFFIC_READY", "admission": "dispatched_once",
                   "admission_id": "a" * 32, "safe_generation": "sha256:" + "0" * 64,
                   "arrival_height": 10, "permit_height": 10, "dispatch_height": 11, "response_height": 12,
                   "completion_finished_ms": int(now * 1000),
                   "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))}
        self.assertIsNone(health_blocker(receipt, 30, now))
        self.assertIn("stale", health_blocker(receipt, 30, now + 60))
        self.assertIn("malformed", health_blocker(dict(receipt, admission_id="xyz"), 30, now))
        self.assertIn("order", health_blocker(dict(receipt, dispatch_height=9), 30, now))
        self.assertIn("UNAVAILABLE", health_blocker(dict(receipt, readiness="UNAVAILABLE"), 30, now))


if __name__ == "__main__":
    unittest.main()
