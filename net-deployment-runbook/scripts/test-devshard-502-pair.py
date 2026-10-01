#!/usr/bin/env python3
"""Fresh-start containment without starting Docker services."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("pair", Path(__file__).with_name("devshard-502-pair.py"))
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)


class PairContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "ds502-fixture-unit"
        for name in ("host", "bin", "gateway-a", "gateway-b"):
            (self.root / "data" / name).mkdir(parents=True)
        self.receipt = {"project": "ds502-fixture-test"}

    def test_refuses_existing_project_even_if_stopped_or_relabelled(self):
        p.fresh(self.root, self.receipt, [], [])
        for labels in ({"com.docker.compose.project": "ds502-fixture-test-a"},
                       {"org.gonka.test-lab.owner": "ds502-fixture-test-b"}):
            with self.assertRaisesRegex(ValueError, "already exists"):
                p.fresh(self.root, self.receipt, [{"Config": {"Labels": labels}}], [])
        with self.assertRaisesRegex(ValueError, "network already exists"):
            p.fresh(self.root, self.receipt, [], ["ds502-fixture-test_fixture"])

    def test_refuses_other_running_writable_mount_and_nonempty_state(self):
        container = {"Config": {}, "State": {"Running": True},
                     "Mounts": [{"Type": "bind", "RW": True, "Source": str(self.root.parent)}]}
        with self.assertRaisesRegex(ValueError, "another container"):
            p.fresh(self.root, self.receipt, [container], [])
        container["Mounts"][0]["RW"] = False
        p.fresh(self.root, self.receipt, [container], [])
        (self.root / "data/gateway-b/gateway.db").write_text("retained")
        with self.assertRaisesRegex(ValueError, "fresh empty"):
            p.fresh(self.root, self.receipt, [], [])

    def test_intent_blocks_retry_before_docker(self):
        (self.root / "start-intent.json").write_text("{}")
        with patch.object(p, "load", return_value=(self.receipt, {})), patch.object(p, "docker") as docker:
            with self.assertRaisesRegex(ValueError, "never retry"):
                p.start(self.root, "a" * 64)
            docker.assert_not_called()

    def test_receipt_write_is_exclusive_and_preserves_first_observation(self):
        path = self.root / "intent.json"
        p.record(path, {"outcome": "uncertain"})
        with self.assertRaises(FileExistsError):
            p.record(path, {"outcome": "pass"})
        self.assertEqual(json.loads(path.read_text()), {"outcome": "uncertain"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
