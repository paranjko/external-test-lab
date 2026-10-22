#!/usr/bin/env python3
"""Identity-bound readiness does not depend on native runtime count."""
import importlib.util
import copy
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("consumer_tests", Path(__file__).with_name("test-telegram-bot.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
BOT = fixtures.BOT


class AdmissionSummaryTest(unittest.TestCase):
    def observe(self, summary):
        backend = {"name": "A", "api_key": "test", "admission_url": "https://a.example/v1/admission-status", "base_url": "https://a.example/v1"}
        with BOT.connection() as db, patch.object(BOT, "urlopen", return_value=fixtures.FakeResponse(summary)) as request:
            BOT.observe_backend(db, backend)
            row = db.execute("SELECT state,reason FROM status_observations ORDER BY id DESC LIMIT 1").fetchone()
            self.assertEqual(request.call_count, 1)
            return tuple(row)

    def ready(self):
        return {"available": True, "state": "READY", "reason": None, "gateway": "A", "model": BOT.MODEL, "protocol": "v6"}

    def test_ready_summary_is_sufficient_with_one_runtime(self):
        self.assertEqual(self.observe(self.ready()), ("ELIGIBLE", "model_eligible"))

    def test_identity_and_readiness_mismatch_fail_closed(self):
        for key, value in [("gateway", "B"), ("model", "another-model"), ("protocol", "v6/invalid"), ("protocol", None), ("state", "UNVERIFIED"), ("reason", "blocked")]:
            with self.subTest(key=key, value=value):
                self.assertEqual(self.observe({**self.ready(), key: value}), ("UNVERIFIED", "status_observation_unavailable"))
        for key in ("gateway", "model", "protocol", "state"):
            payload = self.ready()
            del payload[key]
            self.assertEqual(self.observe(payload), ("UNVERIFIED", "status_observation_unavailable"))

    def test_unavailable_summary_remains_unavailable(self):
        self.assertEqual(self.observe({**self.ready(), "available": False, "reason": "poc_fence"}), ("UNAVAILABLE", "poc_fence"))


class NativeStatusTest(unittest.TestCase):
    backend = {"name": "A", "api_key": "test", "status_mode": "native",
               "admission_url": "https://a.example/ops-gateways/A_V6/status",
               "base_url": "https://a.example/gateway/v6/v1"}

    def ready(self):
        return {"capacity": {"models": {BOT.MODEL: {
            "current_weight": 100, "routable": True, "access_enabled": True}}},
            "limiter": {"models": {BOT.MODEL: {"effective_max_concurrent_requests": 3}}},
            "devshards": [{"active": True, "phase": "active", "requests_blocked": False,
                           "chain_phase": "Inference", "model": BOT.MODEL}]}

    def test_native_status_is_used_once_for_observation_and_admission(self):
        with BOT.connection() as db, patch.object(BOT, "urlopen", return_value=fixtures.FakeResponse(self.ready())) as request:
            BOT.observe_backend(db, self.backend)
            row = db.execute("SELECT state FROM status_observations ORDER BY id DESC LIMIT 1").fetchone()
            self.assertEqual(row[0], "ELIGIBLE")
            BOT.require_gateway_admission(db, self.backend)
            self.assertEqual(request.call_count, 2)
            self.assertTrue(all(call.args[0].full_url == self.backend["admission_url"] for call in request.call_args_list))

    def test_native_status_fails_closed_for_wrong_model_blocked_or_malformed(self):
        cases = [None, {}, {"available": True}]
        for field, value in [("model", "other"), ("requests_blocked", True), ("chain_phase", "PoC")]:
            status = self.ready()
            status["devshards"][0][field] = value
            cases.append(status)
        for field, value in [("current_weight", 0), ("access_enabled", False), ("routable", False), ("current_weight", True)]:
            status = self.ready()
            status["capacity"]["models"][BOT.MODEL][field] = value
            cases.append(status)
        status = self.ready()
        status["limiter"]["models"][BOT.MODEL]["effective_max_concurrent_requests"] = 0
        cases.append(status)
        for payload in cases:
            with self.subTest(payload=payload), BOT.connection() as db:
                with patch.object(BOT, "urlopen", return_value=fixtures.FakeResponse(copy.deepcopy(payload))):
                    with self.assertRaises(BOT.GatewayPreDispatchRejected):
                        BOT.require_gateway_admission(db, self.backend)


if __name__ == "__main__":
    unittest.main()
