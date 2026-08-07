#!/usr/bin/env python3
import importlib.util
import sqlite3
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch


PROGRAM = Path(__file__).parent / "telegram-bot" / "assurance_probe.py"
SPEC = importlib.util.spec_from_file_location("telegram_assurance_probe", PROGRAM)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
SYNTHETIC_ID = -8_999_999_999_999_999_999


class FakeBot:
    def __init__(self):
        self.db = sqlite3.connect(":memory:")
        self.db.execute(
            "CREATE TABLE keys (telegram_id INTEGER PRIMARY KEY, api_key TEXT NOT NULL UNIQUE, issued_at INTEGER NOT NULL)"
        )

    def module(self):
        module = types.ModuleType("bot")

        class ConnectionProxy:
            def __init__(self, db):
                self.db = db

            def __getattr__(self, name):
                return getattr(self.db, name)

            def close(self):
                pass

        module.connection = lambda: ConnectionProxy(self.db)

        def issue(db, telegram_id, renew=False):
            del renew
            key = "test-only-key"
            db.execute(
                "INSERT INTO keys (telegram_id, api_key, issued_at) VALUES (?, ?, 1)",
                (telegram_id, key),
            )
            db.commit()
            return key, True

        module.issue = issue
        module.key_works = lambda key: key == "test-only-key"
        return module


class AssuranceProbeTest(unittest.TestCase):
    def test_creates_verifies_and_cleans_only_synthetic_assignment(self):
        fake = FakeBot()
        with patch.dict(sys.modules, {"bot": fake.module()}), patch.object(
            PROBE.time, "monotonic", side_effect=[10.0, 10.025]
        ):
            result = PROBE.run_probe(SYNTHETIC_ID, 60)
        self.assertEqual(result["elapsed_ms"], 25)
        self.assertTrue(result["within_sla"])
        self.assertTrue(result["temporary_assignment_cleaned"])
        self.assertNotIn("key", result)
        self.assertEqual(fake.db.execute("SELECT count(*) FROM keys").fetchone()[0], 0)

    def test_collision_is_rejected_without_deleting_existing_assignment(self):
        fake = FakeBot()
        fake.db.execute(
            "INSERT INTO keys (telegram_id, api_key, issued_at) VALUES (?, 'existing', 1)",
            (SYNTHETIC_ID,),
        )
        fake.db.commit()
        with patch.dict(sys.modules, {"bot": fake.module()}):
            with self.assertRaisesRegex(RuntimeError, "already exists"):
                PROBE.run_probe(SYNTHETIC_ID, 60)
        self.assertEqual(fake.db.execute("SELECT api_key FROM keys").fetchone()[0], "existing")

    def test_sla_is_measured_and_real_telegram_range_is_rejected(self):
        fake = FakeBot()
        with patch.dict(sys.modules, {"bot": fake.module()}), patch.object(
            PROBE.time, "monotonic", side_effect=[10.0, 10.061]
        ):
            result = PROBE.run_probe(SYNTHETIC_ID, 60)
        self.assertFalse(result["within_sla"])
        with self.assertRaisesRegex(ValueError, "outside"):
            PROBE.run_probe(-12345, 60)


if __name__ == "__main__":
    unittest.main()
