import importlib.util
import fcntl
import io
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock

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
        self.amount = rotation.AMOUNT
        self.minimum = rotation.AMOUNT
        self.maximum = 10 * rotation.AMOUNT

    def request(self, path, data=None):
        if path == rotation.PARAMS_ROUTE:
            return {'status': 200, 'result': {'params': {'devshard_escrow_params': {
                'min_amount': str(self.minimum), 'max_amount': str(self.maximum)}}}}
        if path == '/v1/admin/settings':
            return {'status': 200, 'result': {'escrow_rotation': {'enabled': self.enabled}}}
        if path == '/v1/debug/rotation':
            return {'status': 200, 'result': {'chain': {'epoch_index': self.epoch,
                    'phase': self.phase, 'blocks_to_epoch_switch': self.blocks}}}
        if path == '/v1/admin/escrows':
            self.creates += 1
            self.assertEqual(data['amount'], self.amount)
            if self.timeout:
                raise TimeoutError('uncertain transaction')
            return {'status': 200, 'result': {'escrow_id': self.epoch}}
        if path.endswith('/settle'):
            self.settles += 1
            self.assertIs(data['force'], False)
            return {'status': 200, 'result': {}}
        self.fail('unexpected API route')

    def tick(self):
        return rotation.tick(self.path, 'a', self.request, self.amount)

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
        with self.assertRaises(ValueError):
            rotation.tick(self.path, 'b', self.request)
        self.enabled = True
        with self.assertRaises(ValueError):
            self.tick()
        self.assertEqual(self.creates, 0)

    def test_boundary_and_poc(self):
        self.blocks = 14
        self.assertTrue(self.tick().startswith('waiting:'))
        self.blocks = 50
        self.phase = 'PoC'
        self.assertTrue(self.tick().startswith('waiting:'))
        self.assertEqual(self.creates, 0)

    def test_mixed_amounts_preserve_history_and_gross_cap(self):
        unit = rotation.UNITS_PER_GNK
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            db.executemany('INSERT INTO funding VALUES (?,?,?, ?,1)',
                [(1, unit, '{"status":200}', '1'),
                 (2, 4994 * unit, '{"status":200}', '2')])
            before = db.execute('SELECT * FROM funding ORDER BY epoch').fetchall()
        self.minimum = self.amount = 5 * unit
        self.assertEqual(self.tick(), 'created: reserved_units=5000000000000')
        self.epoch += 1
        self.assertTrue(self.tick().startswith('budget exhausted'))
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            self.assertEqual(db.execute('SELECT * FROM funding WHERE epoch < 10 ORDER BY epoch').fetchall(), before)

    def test_insufficient_remainder_does_not_round_or_reduce_amount(self):
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            db.execute('INSERT INTO funding VALUES (1,?, ?,"1",1)',
                       (4996 * rotation.AMOUNT, '{"status":200}'))
        self.minimum = self.amount = 5 * rotation.AMOUNT
        self.assertTrue(self.tick().startswith('budget exhausted'))
        self.assertEqual(self.creates, 0)

    def test_changed_chain_limits_refuse_before_mutation(self):
        self.minimum = 5 * rotation.AMOUNT
        self.assertTrue(self.tick().startswith('halt: requested amount'))
        self.assertEqual((self.creates, self.settles), (0, 0))
        self.amount = self.minimum
        self.assertTrue(self.tick().startswith('created:'))
        self.minimum = 6 * rotation.AMOUNT
        self.epoch += 2
        self.assertTrue(self.tick().startswith('halt: requested amount'))
        self.assertEqual((self.creates, self.settles), (1, 0))

    def test_invalid_historical_amount_fails_closed(self):
        for value in (0, -1, 'unknown', 1.5):
            with self.subTest(value=value):
                with sqlite3.connect(self.path / 'ledger.sqlite') as db:
                    db.execute('DELETE FROM funding')
                    db.execute('INSERT INTO funding VALUES (1,?,NULL,NULL,0)', (value,))
                with self.assertRaises(ValueError):
                    self.tick()
        self.assertEqual(self.creates, 0)

    def test_devnet_amount_boundaries_before_reservation_or_dispatch(self):
        self.minimum = 5_000_000_000
        self.maximum = 10_000_000_000
        for amount, accepted in ((1_000_000, False),
                                 (self.minimum - 1, False),
                                 (self.minimum, True),
                                 (self.maximum, True),
                                 (self.maximum + 1, False)):
            with self.subTest(amount=amount):
                self.amount = amount
                with sqlite3.connect(self.path / 'ledger.sqlite') as db:
                    before = db.execute('SELECT * FROM funding ORDER BY epoch').fetchall()
                creates, settles = self.creates, self.settles
                result = self.tick()
                with sqlite3.connect(self.path / 'ledger.sqlite') as db:
                    after = db.execute('SELECT * FROM funding ORDER BY epoch').fetchall()
                if accepted:
                    self.assertTrue(result.startswith('created:'), result)
                    self.assertEqual(self.creates, creates + 1)
                    self.assertEqual(after[-1][1], amount)
                    self.epoch += 1
                else:
                    self.assertEqual(result, 'halt: requested amount outside current chain limits')
                    self.assertEqual(after, before)
                    self.assertEqual((self.creates, self.settles), (creates, settles))

    def test_concurrent_tick_cannot_reserve(self):
        with (self.path / 'lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.tick()
        self.assertEqual(self.creates, 0)

    def test_amount_parser_rejects_lossy_values(self):
        for value in (True, False, 1.5, '1.0', '-1', 'NaN', 0):
            with self.subTest(value=value), self.assertRaises(ValueError):
                rotation.positive_integer(value)

    def test_new_amount_timeout_remains_fully_reserved(self):
        self.minimum = self.amount = 5 * rotation.AMOUNT
        self.timeout = True
        with self.assertRaises(TimeoutError):
            self.tick()
        self.timeout = False
        self.assertTrue(self.tick().startswith('halt:'))
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            self.assertEqual(db.execute('SELECT amount,result FROM funding').fetchall(),
                             [(self.amount, None)])

    def test_unavailable_chain_limits_do_not_mutate(self):
        def request(path, data=None):
            if path == rotation.PARAMS_ROUTE:
                return {'status': 503, 'result': {}}
            return self.request(path, data)
        self.assertTrue(rotation.tick(self.path, 'a', request).startswith('halt:'))
        self.assertEqual((self.creates, self.settles), (0, 0))

    def test_invalid_limits_do_not_mutate(self):
        self.minimum = 'unknown'
        with self.assertRaises(ValueError):
            self.tick()
        self.assertEqual((self.creates, self.settles), (0, 0))

    def test_cli_requires_explicit_amount_and_model_before_reading_credentials(self):
        with mock.patch('sys.argv', ['rotation', 'a']), \
             mock.patch.object(Path, 'read_text') as read, \
             mock.patch('sys.stderr', new_callable=io.StringIO), \
             self.assertRaises(SystemExit) as result:
            rotation.main()
        self.assertEqual(result.exception.code, 2)
        read.assert_not_called()

    def test_cli_chain_request_does_not_receive_gateway_credential(self):
        requests = []
        def urlopen(request, timeout):
            requests.append(request)
            response = mock.MagicMock()
            response.status = 200
            response.read.return_value = b'{}'
            response.__enter__.return_value = response
            return response
        def tick(path, instance, request, amount, model):
            self.assertEqual((instance, amount, model), ('a', 5000000000, 'fixture-model'))
            request(rotation.PARAMS_ROUTE)
            request(rotation.EFFECTIVE_EPOCH_ROUTE)
            request('/v1/admin/settings')
            return 'waiting: fixture'
        with mock.patch('sys.argv', ['rotation', 'a', '--amount', '5000000000', '--model', 'fixture-model']), \
             mock.patch.object(Path, 'read_text', return_value='DEVSHARD_ADMIN_API_KEY=fixture-secret'), \
             mock.patch.object(rotation, 'tick', side_effect=tick), \
             mock.patch.object(rotation.urllib.request, 'urlopen', side_effect=urlopen), \
             mock.patch('sys.stdout', new_callable=io.StringIO), \
             mock.patch.object(rotation.os, 'umask'):
            rotation.main()
        self.assertEqual(requests[0].full_url, 'http://127.0.0.1:1317' + rotation.PARAMS_ROUTE)
        self.assertIsNone(requests[0].get_header('Authorization'))
        self.assertEqual(requests[1].full_url, 'http://127.0.0.1:1317' + rotation.EFFECTIVE_EPOCH_ROUTE)
        self.assertIsNone(requests[1].get_header('Authorization'))
        self.assertEqual(requests[2].get_header('Authorization'), 'Bearer fixture-secret')

    def reconcile_request(self, path, data=None):
        self.assertIsNone(data, 'reconciliation must never POST')
        if path == rotation.ESCROW_ROUTE + '10':
            return {'status': 200, 'result': {'found': True, 'escrow': {
                'id': '10', 'amount': str(rotation.AMOUNT), 'epoch_index': '10', 'settled': True}}}
        if path == '/v1/admin/state':
            return {'status': 200, 'result': {'devshards': [{'id': '10', 'active': False}]}}
        self.fail('unexpected reconciliation request')

    def test_reconciliation_preserves_failure_and_amount(self):
        self.tick()
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            db.execute('INSERT INTO settlement VALUES (10,1,?)', ('{"status":502}',))
            before = db.execute('SELECT * FROM funding').fetchall()
        result = rotation.reconcile_settled(self.path, 'a', self.reconcile_request, 10)
        self.assertTrue(result.startswith('reconciled:'))
        self.assertTrue(rotation.reconcile_settled(self.path, 'a', self.reconcile_request, 10).startswith('reconciled:'))
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            self.assertEqual(db.execute('SELECT * FROM funding').fetchall(), before)
            self.assertEqual(db.execute('SELECT result FROM settlement').fetchall(), [('{"status":502}',)])
            self.assertEqual(db.execute('SELECT count(*) FROM reconciliation').fetchone()[0], 1)
        self.epoch += 2
        self.assertTrue(self.tick().startswith('created:'))
        self.assertEqual(self.settles, 0)

    def test_reconciliation_rejects_absent_or_mismatched_chain(self):
        self.tick()
        for field, value in [('found', False), ('settled', False), ('amount', '2'), ('id', '11'), ('epoch_index', '9')]:
            def request(path, data=None):
                result = self.reconcile_request(path, data)
                if path.startswith(rotation.ESCROW_ROUTE):
                    if field == 'found':
                        result['result']['found'] = value
                    else:
                        result['result']['escrow'][field] = value
                return result
            with self.subTest(field=field):
                self.assertTrue(rotation.reconcile_settled(self.path, 'a', request, 10).startswith('halt:'))
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            self.assertIsNone(db.execute("SELECT 1 FROM sqlite_master WHERE name='reconciliation'").fetchone())

    def test_reconciliation_rejects_active_runtime(self):
        self.tick()
        def request(path, data=None):
            result = self.reconcile_request(path, data)
            if path == '/v1/admin/state':
                result['result']['devshards'][0]['active'] = True
            return result
        self.assertTrue(rotation.reconcile_settled(self.path, 'a', request, 10).startswith('halt:'))

    def test_missing_identity_or_failed_creation_halts(self):
        for result in [{'status': 200, 'result': {}}, {'status': 500, 'result': 'failed'}]:
            with sqlite3.connect(self.path / 'ledger.sqlite') as db:
                db.execute('DELETE FROM funding')
            def request(path, data=None):
                return result if path == '/v1/admin/escrows' else self.request(path, data)
            self.assertTrue(rotation.tick(self.path, 'a', request).startswith('halt:'))
            self.epoch += 1
            self.assertTrue(self.tick().startswith('halt:'))

    def pruned_request(self, path, data=None):
        self.assertIsNone(data)
        if path == rotation.ESCROW_ROUTE + '10':
            return {'status': 200, 'result': {'found': False}}
        if path == '/v1/debug/rotation':
            return self.request(path)
        return self.reconcile_request(path, data)

    def test_deferred_pruned_retains_debit_and_failures_without_retry(self):
        self.tick()
        self.epoch += 2
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            db.execute('INSERT INTO settlement VALUES (10,1,NULL)')
            before = db.execute('SELECT * FROM funding').fetchall()
        result = rotation.reconcile_settled(self.path, 'a', self.pruned_request, 10, defer_pruned=True)
        self.assertTrue(result.startswith('deferred:'))
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            self.assertEqual(db.execute('SELECT * FROM funding').fetchall(), before)
            self.assertEqual(db.execute('SELECT result FROM settlement').fetchall(), [(None,)])
            self.assertIn('settlement unknown', db.execute('SELECT proof FROM deferred_pruned').fetchone()[0])
        self.assertEqual(self.tick(), 'created: reserved_units=2000000000')
        self.assertEqual(self.settles, 0)

    def test_deferred_pruned_refuses_current_present_active_and_unknown_creation(self):
        self.tick()
        self.assertTrue(rotation.reconcile_settled(self.path, 'a', self.pruned_request, 10, True).startswith('halt:'))
        self.epoch += 2
        self.assertTrue(rotation.reconcile_settled(self.path, 'a', self.reconcile_request, 10, True).startswith('halt:'))
        def active(path, data=None):
            result = self.pruned_request(path, data)
            if path == '/v1/admin/state':
                result['result']['devshards'][0]['active'] = True
            return result
        self.assertTrue(rotation.reconcile_settled(self.path, 'a', active, 10, True).startswith('halt:'))
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            db.execute('UPDATE funding SET result=NULL')
        self.assertTrue(rotation.reconcile_settled(self.path, 'a', self.pruned_request, 10, True).startswith('halt:'))

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
        self.assertTrue(rotation.tick(self.path, 'a', request).startswith('waiting:'))
        with sqlite3.connect(self.path / 'ledger.sqlite') as db:
            self.assertEqual(db.execute('SELECT count(*) FROM settlement').fetchone()[0], 3)
        self.epoch += 1
        self.assertTrue(rotation.tick(self.path, 'a', request).startswith('created:'))

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

    def test_failed_third_settlement_still_halts_after_restart(self):
        self.tick()
        self.epoch += 2
        statuses = iter([409, 409, 502])
        def request(path, data=None):
            if path.endswith('/settle'):
                self.assertIs(data['force'], False)
                return {'status': next(statuses), 'result': 'fixture failure'}
            return self.request(path, data)
        for _ in range(3):
            result = rotation.tick(self.path, 'a', request)
        self.assertTrue(result.startswith('halt:'))
        creates = self.creates
        self.epoch += 1
        self.assertTrue(self.tick().startswith('halt:'))
        self.assertEqual(self.creates, creates)
        self.assertEqual(self.settles, 0)


if __name__ == '__main__':
    unittest.main()
