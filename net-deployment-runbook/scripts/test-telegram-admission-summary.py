#!/usr/bin/env python3
"""Identity-bound readiness does not depend on native runtime count."""
import importlib.util
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


if __name__ == "__main__":
    unittest.main()
