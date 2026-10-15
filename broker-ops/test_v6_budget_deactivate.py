import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('rotation', Path(__file__).with_name('v6-budget-rotation.py'))
rotation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rotation)


class DeactivateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'campaign'
        rotation.initialize(self.path, 'a')
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            db.execute('INSERT INTO funding VALUES (?,?,?,?,?)',
                       (10, 5000000000, json.dumps({'status': 200}), '123', 0))
        self.timer = 'inactive'
        self.epoch = 12
        self.found = False
        self.requests = 0
        self.active = True
        self.posts = []

    def systemd(self, args, **kwargs):
        self.assertEqual(args, ['systemctl', 'show', 'gdc-v6-budget-a.timer', '--property=ActiveState', '--value'])
        return SimpleNamespace(stdout=self.timer)

    def request(self, route, payload=None):
        if payload is not None:
            self.assertEqual(route, '/v1/admin/devshards/123/deactivate')
            self.assertEqual(payload, {})
            self.posts.append(route)
            self.active = False
            return {'status': 200, 'result': {'id': '123', 'active': False}}
        if route == rotation.ESCROW_ROUTE + '123':
            result = {'found': self.found}
        elif route == '/v1/debug/rotation':
            result = {'chain': {'epoch_index': self.epoch}}
        elif route == '/v1/admin/settings':
            result = {'escrow_rotation': {'enabled': False}}
        elif route == '/v1/admin/devshards/123/participants':
            result = {'id': '123', 'active_requests': self.requests, 'active': self.active}
        elif route == '/v1/admin/state':
            result = {'devshards': [{'id': '123', 'active': self.active}]}
        else:
            raise AssertionError('unexpected request: ' + route)
        return {'status': 200, 'result': result}

    def invoke(self):
        return rotation.deactivate_pruned(self.path, 'a', self.request, 123,
                                         self.root / 'receipt.json', self.systemd)

    def test_deactivates_without_ledger_change(self):
        before = (self.path / 'ledger.sqlite').read_bytes()
        self.assertTrue(self.invoke().startswith('deactivated:'))
        self.assertEqual(self.posts, ['/v1/admin/devshards/123/deactivate'])
        self.assertEqual((self.path / 'ledger.sqlite').read_bytes(), before)
        self.assertEqual((self.root / 'receipt.json').stat().st_mode & 0o777, 0o600)

    def test_guards_before_post(self):
        for field, value in [('timer', 'active'), ('epoch', 11), ('found', True),
                             ('requests', 1), ('requests', None)]:
            original = getattr(self, field)
            setattr(self, field, value)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.invoke()
            setattr(self, field, original)
        self.assertEqual(self.posts, [])

    def test_no_receipt_overwrite(self):
        (self.root / 'receipt.json').write_text('preserved')
        with self.assertRaises(FileExistsError):
            self.invoke()
        self.assertEqual(self.posts, [])

    def test_second_chain_read_blocks_changed_state(self):
        original = self.request
        reads = 0
        def changed(route, payload=None):
            nonlocal reads
            if route == rotation.ESCROW_ROUTE + '123':
                reads += 1
                self.found = reads == 2
            return original(route, payload)
        self.request = changed
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertEqual(self.posts, [])


if __name__ == '__main__':
    unittest.main()
