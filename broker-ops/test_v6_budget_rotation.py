import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('rotation', Path(__file__).with_name('v6-budget-rotation.py'))
rotation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rotation)


class BudgetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'campaign'
        rotation.initialize(self.path, 'a')
        self.epoch = 10
        self.enabled = False
        self.phase = 'Inference'
        self.blocks = 50
        self.creates = 0
        self.settles = 0
        self.timeout = False

    def request(self, path, data=None):
        if path == '/v1/admin/settings':
            return {'status': 200, 'result': {'escrow_rotation': {'enabled': self.enabled}}}
        if path == '/v1/debug/rotation':
            return {'status': 200, 'result': {'chain': {'epoch_index': self.epoch,
                    'phase': self.phase, 'blocks_to_epoch_switch': self.blocks}}}
        if path == '/v1/admin/escrows':
            self.creates += 1
            self.assertEqual(data['amount'], 1000000000)
            if self.timeout:
                raise TimeoutError('uncertain transaction')
            return {'status': 200, 'result': {'escrow_id': self.epoch}}
        if path.endswith('/settle'):
            self.settles += 1
            self.assertIs(data['force'], False)
            return {'status': 200, 'result': {}}
        self.fail('unexpected API route')

    def tick(self):
        return rotation.tick(self.path, 'a', self.request)

    def test_once_per_epoch_and_restart(self):
        self.assertTrue(self.tick().startswith('created:'))
        self.assertTrue(self.tick().startswith('waiting:'))
        self.assertEqual(self.creates, 1)
        self.epoch += 1
        self.tick()
        self.assertEqual(self.creates, 2)
        self.assertEqual(self.settles, 0)
        self.epoch += 1
        self.tick()
        self.assertEqual(self.settles, 1)

    def test_timeout_reserves_and_halts(self):
        self.timeout = True
        with self.assertRaises(TimeoutError):
            self.tick()
        self.timeout = False
        self.epoch += 1
        self.assertTrue(self.tick().startswith('halt:'))
        self.assertEqual(self.creates, 1)

    def test_cap_is_gross_and_persistent(self):
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            db.executemany('INSERT INTO funding VALUES (?,?,?, ?,1)',
                [(i, rotation.AMOUNT, '{"status":200}', str(i)) for i in range(rotation.CAP)])
        self.epoch = rotation.CAP + 10
        self.assertTrue(self.tick().startswith('budget exhausted'))
        self.assertEqual(self.creates, 0)

    def test_missing_ledger_not_recreated(self):
        (self.path / 'ledger.sqlite').unlink()
        with self.assertRaises(sqlite3.OperationalError):
            self.tick()
        self.assertFalse((self.path / 'ledger.sqlite').exists())

    def test_no_reinitialization(self):
        with self.assertRaises(FileExistsError):
            rotation.initialize(self.path, 'a')

    def test_binding_and_native_rotation(self):
        with self.assertRaises(AssertionError):
            rotation.tick(self.path, 'b', self.request)
        self.enabled = True
        with self.assertRaises(AssertionError):
            self.tick()
        self.assertEqual(self.creates, 0)

    def test_boundary_and_poc(self):
        self.blocks = 14
        self.assertTrue(self.tick().startswith('waiting:'))
        self.blocks = 50
        self.phase = 'PoC'
        self.assertTrue(self.tick().startswith('waiting:'))
        self.assertEqual(self.creates, 0)

    def test_missing_identity_or_failed_creation_halts(self):
        for result in [{'status': 200, 'result': {}}, {'status': 500, 'result': 'failed'}]:
            with sqlite3.connect(self.path / 'ledger.sqlite') as db:
                db.execute('DELETE FROM funding')
            def request(path, data=None):
                return result if path == '/v1/admin/escrows' else self.request(path, data)
            self.assertTrue(rotation.tick(self.path, 'a', request).startswith('halt:'))
            self.epoch += 1
            self.assertTrue(self.tick().startswith('halt:'))

    def test_busy_settlement_is_bounded_and_never_forced(self):
        self.tick()
        self.epoch += 2
        def request(path, data=None):
            if path.endswith('/settle'):
                self.assertIs(data['force'], False)
                return {'status': 409, 'result': 'busy'}
            return self.request(path, data)
        for _ in range(3):
            rotation.tick(self.path, 'a', request)
        self.assertTrue(rotation.tick(self.path, 'a', request).startswith('halt:'))

    def test_ambiguous_settlement_blocks_new_funding(self):
        self.tick()
        self.epoch += 2
        def request(path, data=None):
            if path.endswith('/settle'):
                raise TimeoutError()
            return self.request(path, data)
        with self.assertRaises(TimeoutError):
            rotation.tick(self.path, 'a', request)
        self.assertTrue(self.tick().startswith('halt:'))
        self.assertEqual(self.creates, 1)


if __name__ == '__main__':
    unittest.main()
