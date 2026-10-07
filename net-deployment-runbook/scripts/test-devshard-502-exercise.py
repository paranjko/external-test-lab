#!/usr/bin/env python3
"""Synthetic escrow exercise must stop on uncertainty, never remint."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock


SPEC = importlib.util.spec_from_file_location("exercise", Path(__file__).with_name("devshard-502-exercise.py"))
e = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(e)


class ExerciseContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.subject = e.Exercise.__new__(e.Exercise)
        self.subject.root = Path(self.temp.name)
        self.subject.endpoints = {"A": "http://127.0.0.1:8000", "B": "http://127.0.0.1:8001"}
        self.subject.secrets = {"A": ["private", "admin", "client"]}
        self.subject.chain = "http://127.0.0.1:26657"
        self.subject.save = Mock()
        self.empty = {"devshards": [], "settings": {"escrow_rotation": {"enabled": False, "settlement_enabled": False}}}

    def test_nonfixture_chain_stops_before_creation(self):
        self.subject.http = Mock(return_value={"result": {"node_info": {"network": "gonka-devnet-community"}}})
        self.subject.create = Mock()
        with self.assertRaisesRegex(ValueError, "only isolated"):
            self.subject.run("127.0.0.1:9090")
        self.subject.create.assert_not_called()

    def test_uncertain_creation_preserves_intent_and_refuses_second_post(self):
        self.subject.http = Mock(side_effect=[self.empty, ValueError("connection lost"), self.empty])
        with self.assertRaisesRegex(ValueError, "connection lost"):
            self.subject.create("A", "127.0.0.1:9090")
        self.assertTrue((self.subject.root / "create-A-intent.json").is_file())
        with self.assertRaises(FileExistsError):
            self.subject.create("A", "127.0.0.1:9090")
        self.assertEqual(sum(call.args[1] == "POST" for call in self.subject.http.call_args_list), 1)

    def test_chain_mismatch_stops_after_one_create_without_replacement(self):
        created = {"registered": True, "creator": "fixture-a", "tx_hash": "hash", "escrow_id": 2}
        self.subject.http = Mock(side_effect=[self.empty, created])
        self.subject.query = Mock(return_value={"found": True, "escrow": {"creator": "another"}})
        with self.assertRaisesRegex(ValueError, "binding mismatch"):
            self.subject.create("A", "127.0.0.1:9090")
        self.assertEqual(self.subject.http.call_count, 2)

    def test_confirmed_creation_requires_chain_and_registry_readbacks(self):
        created = {"registered": True, "creator": "fixture-a", "tx_hash": "hash", "escrow_id": 2}
        self.subject.http = Mock(side_effect=[self.empty, created, {"devshards": [{"id": "2"}]}])
        self.subject.query = Mock(return_value={"found": True, "escrow": {
            "creator": "fixture-a", "id": "2", "model_id": e.w.MODEL}})
        self.assertEqual(self.subject.create("A", "127.0.0.1:9090"), created)
        self.subject.query.assert_called_once_with(2, "127.0.0.1:9090")
        self.subject.save.assert_called_once()

    def test_smoke_drain_waits_for_idle_and_preserves_each_read(self):
        busy = {"id": "2", "active_requests": 0, "pending_race_cleanup": 1}
        idle = dict(busy, pending_race_cleanup=0)
        transport, campaign, clock = Mock(), Mock(), Mock()
        clock.monotonic.return_value = 0
        transport.observe.side_effect = [{"value": {"devshards": [{"runtime": row}]}} for row in (busy, idle)]
        self.assertEqual(self.subject.drain(transport, campaign, "A", "smoke-A", "2", clock), idle)
        self.assertEqual(campaign.append.call_count, 2)
        clock.sleep.assert_called_once_with(1)

    def test_smoke_drain_is_bounded_and_does_not_resend(self):
        transport, campaign, clock = Mock(), Mock(), Mock()
        clock.monotonic.side_effect = [0, 0, 0, 0, e.w.DRAIN_SECONDS]
        transport.observe.return_value = {"value": {"devshards": [{"runtime": {
            "id": "2", "active_requests": 1, "pending_race_cleanup": 0}}]}}
        with self.assertRaisesRegex(TimeoutError, "drain deadline"):
            self.subject.drain(transport, campaign, "A", "smoke-A", "2", clock)
        transport.send.assert_not_called()
        transport.observe.assert_called_once()

    def test_smoke_drain_rejects_escrow_switch(self):
        transport, campaign = Mock(), Mock()
        transport.observe.return_value = {"value": {"devshards": [{"runtime": {"id": "3"}}]}}
        with self.assertRaisesRegex(ValueError, "escrow changed"):
            self.subject.drain(transport, campaign, "A", "smoke-A", "2")
        campaign.append.assert_called_once()


if __name__ == "__main__":
    unittest.main(verbosity=2)
