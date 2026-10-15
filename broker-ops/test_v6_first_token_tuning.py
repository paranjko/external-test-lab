import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('tuning', Path(__file__).with_name('v6-first-token-tuning.py'))
tuning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tuning)


class TuningTests(unittest.TestCase):
    def setUp(self):
        self.state = {'redundancy': {tuning.FIELD: 1000, 'speed_policy': 'hybrid'},
                      'escrow_rotation': {'enabled': False}, 'max_concurrent_requests': 35}
        self.writes = []

    def api(self, payload):
        if payload is not None:
            self.writes.append(payload)
            self.state['redundancy'].update(payload['redundancy'])
        return copy.deepcopy(self.state)

    def test_dry_run(self):
        self.assertFalse(tuning.change(self.api, 1000, 20000)['applied'])
        self.assertEqual(self.writes, [])

    def test_scoped_apply_and_rollback(self):
        original = copy.deepcopy(self.state)
        with tempfile.TemporaryDirectory() as d:
            receipt = Path(d) / 'receipt.json'
            self.assertTrue(tuning.change(self.api, 1000, 20000, receipt)['other_settings_unchanged'])
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(receipt.read_text())['before'], original)
            self.assertEqual(self.writes, [{'redundancy': {tuning.FIELD: 20000}}])
            tuning.change(self.api, 20000, 1000, Path(d) / 'rollback.json')
            self.assertEqual(self.state, original)

    def test_preconditions_never_write(self):
        for expected, target in [(20000, 20000), (1000, 0), (1000, 30001)]:
            with self.assertRaises(ValueError):
                tuning.change(self.api, expected, target)
        with tempfile.TemporaryDirectory() as d:
            receipt = Path(d) / 'existing'
            receipt.touch()
            with self.assertRaises(FileExistsError):
                tuning.change(self.api, 1000, 20000, receipt)
        self.assertEqual(self.writes, [])

    def test_readback_detects_unrelated_change_without_overwriting_it(self):
        def raced(payload):
            result = self.api(payload)
            if payload is not None:
                self.state['max_concurrent_requests'] = 99
            return result
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                tuning.change(raced, 1000, 20000, Path(d) / 'receipt')
        self.assertEqual(self.state['max_concurrent_requests'], 99)
        self.assertEqual(len(self.writes), 1)
