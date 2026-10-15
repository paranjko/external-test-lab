import copy
import json
import sqlite3
import unittest

import test_v6_budget_rotation as fixture

rotation = fixture.rotation


class HandoverTest(unittest.TestCase):
    def setUp(self):
        self.base = fixture.BudgetTest()
        self.base.setUp()
        self.addCleanup(self.base.doCleanups)
        self.base.tick()
        self.base.epoch = 11
        self.state = {'devshards': [{'id': '11', 'model': rotation.MODEL, 'active': True,
            'runtime': {'id': '11', 'model': rotation.MODEL, 'active': True,
                        'on_hold': False, 'requests_blocked': False, 'balance': 100}}],
            'capacity': {'escrow_weights': {'11': 1}, 'models': {
                rotation.MODEL: {'routable': True, 'current_weight': 1}}},
            'limiter': {'models': {rotation.MODEL: {'effective_max_concurrent_requests': 1,
                'max_input_tokens_in_flight': 1024,
                'effective_max_input_tokens_in_flight': 1024}}}}
        self.chain_change = None
        self.confirmation = ''
        self.debug_calls = 0
        self.found = True
        self.mismatch = False
        self.settlement_status = 200
        self.effective_epoch = 11
        self.created_epoch = None

    def request(self, path, data=None):
        if path == rotation.EFFECTIVE_EPOCH_ROUTE:
            self.assertIsNone(data)
            return {'status': 200, 'result': {'epoch_group_data': {'epoch_index': str(self.effective_epoch)}}}
        if path == '/v1/admin/state':
            self.assertIsNone(data)
            return {'status': 200, 'result': copy.deepcopy(self.state)}
        if path.startswith(rotation.ESCROW_ROUTE):
            self.assertIsNone(data)
            identity = path.rsplit('/', 1)[1]
            return {'status': 200, 'result': {'found': self.found, 'escrow': {
                'id': identity, 'epoch_index': self.created_epoch if identity == '11' and self.created_epoch is not None else identity,
                'amount': str(rotation.AMOUNT + int(self.mismatch)), 'settled': False}}}
        if path == '/v1/debug/rotation':
            self.debug_calls += 1
            result = self.base.request(path, data)
            result['result']['chain']['confirmation_poc_phase'] = self.confirmation
            if self.debug_calls == 2 and self.chain_change:
                result['result']['chain'].update(self.chain_change)
            return result
        if path.endswith('/settle'):
            self.assertIs(data['force'], False)
            self.base.settles += 1
            return {'status': self.settlement_status, 'result': {}}
        return self.base.request(path, data)

    def tick(self):
        self.debug_calls = 0
        return rotation.tick(self.base.path, 'a', self.request,
                             settle_after_replacement=True)

    def funded(self):
        self.assertTrue(self.tick().startswith('created:'))
        self.assertEqual(self.base.settles, 0)

    def test_create_before_retire_then_nonforced_settlement(self):
        self.funded()
        self.assertTrue(self.tick().startswith('waiting:'))
        self.assertEqual(self.base.settles, 1)
        self.tick()
        self.assertEqual((self.base.creates, self.base.settles), (2, 1))
        with sqlite3.connect(self.base.path / 'ledger.sqlite') as db:
            self.assertEqual(db.execute('SELECT sum(amount) FROM funding').fetchone()[0], 2*rotation.AMOUNT)

    def test_explicit_unlimited_tokens_allow_handover(self):
        self.funded()
        self.state['limiter']['models'][rotation.MODEL].update(
            max_input_tokens_in_flight=0, effective_max_input_tokens_in_flight=0)
        self.tick()
        self.assertEqual(self.base.settles, 1)

    def test_invalid_or_scaled_to_zero_tokens_refuse_handover(self):
        self.funded()
        limits = self.state['limiter']['models'][rotation.MODEL]
        for baseline, effective in ((1024, 0), (None, 0), (0, None),
                                    (-1, 0), (0, -1), (False, 0), (0, False),
                                    ('0', 0), (0, '0'), (0, 10)):
            with self.subTest(baseline=baseline, effective=effective):
                limits.update(max_input_tokens_in_flight=baseline,
                              effective_max_input_tokens_in_flight=effective)
                self.assertIn('prerequisites unavailable', self.tick())
                self.assertEqual(self.base.settles, 0)
        limits.pop('max_input_tokens_in_flight')
        self.assertIn('prerequisites unavailable', self.tick())
        self.assertEqual(self.base.settles, 0)

    def test_unusable_replacement_never_retires(self):
        self.funded()
        original = copy.deepcopy(self.state)
        mutations = [
            lambda s: s['devshards'][0].update(active=False),
            lambda s: s['devshards'][0].update(model='wrong'),
            lambda s: s['devshards'][0].update(runtime=None),
            lambda s: s['devshards'][0]['runtime'].update(requests_blocked=True),
            lambda s: s['devshards'][0]['runtime'].update(on_hold=True),
            lambda s: s['devshards'][0]['runtime'].update(balance=0),
            lambda s: s['devshards'][0]['runtime'].pop('requests_blocked'),
            lambda s: s['capacity']['escrow_weights'].update({'11': 0}),
            lambda s: s['capacity']['escrow_weights'].update({'11': float('nan')}),
            lambda s: s['capacity']['models'][rotation.MODEL].update(current_weight=0),
            lambda s: s['limiter']['models'][rotation.MODEL].update(effective_max_concurrent_requests=0),
            lambda s: s['devshards'].append(copy.deepcopy(s['devshards'][0])),
        ]
        for change in mutations:
            self.state = copy.deepcopy(original)
            change(self.state)
            self.assertIn('prerequisites unavailable', self.tick())
            self.assertEqual(self.base.settles, 0)

    def test_confirmation_and_epoch_transition_refuse(self):
        self.funded()
        for phase in ('CONFIRMATION_POC_GENERATION', 'CONFIRMATION_POC_GRACE_PERIOD',
                      'CONFIRMATION_POC_VALIDATION', 'unknown'):
            self.confirmation = phase
            self.assertIn('prerequisites unavailable', self.tick())
        self.confirmation = ''
        for change in ({'epoch_index': 12}, {'phase': 'PoC'}, {'blocks_to_epoch_switch': 14}):
            self.chain_change = change
            self.assertIn('window changed', self.tick())
        self.assertEqual(self.base.settles, 0)

    def test_completed_confirmation_allows_guarded_handover(self):
        self.funded()
        self.confirmation = 'CONFIRMATION_POC_COMPLETED'
        self.assertTrue(self.tick().startswith('waiting:'))
        self.assertEqual(self.base.settles, 1)

    def test_inactive_confirmation_allows_guarded_handover(self):
        self.funded()
        self.confirmation = 'CONFIRMATION_POC_INACTIVE'
        self.assertTrue(self.tick().startswith('waiting:'))
        self.assertEqual(self.base.settles, 1)

    def test_absent_or_mismatched_chain_never_becomes_settled(self):
        self.funded()
        self.found = False
        self.assertIn('requires reconciliation', self.tick())
        self.found = True
        self.mismatch = True
        self.assertIn('requires reconciliation', self.tick())
        self.assertEqual(self.base.settles, 0)

    def test_failed_settlement_still_halts_without_retry(self):
        self.funded()
        self.settlement_status = 502
        self.assertTrue(self.tick().startswith('halt:'))
        self.assertTrue(self.tick().startswith('halt:'))
        self.assertEqual(self.base.settles, 1)
        with sqlite3.connect(self.base.path / 'ledger.sqlite') as db:
            self.assertEqual(json.loads(db.execute('SELECT result FROM settlement').fetchone()[0])['status'], 502)

    def test_stale_unreconciled_escrow_refuses(self):
        self.base.epoch = 12
        self.assertIn('explicit reconciliation', self.tick())
        self.assertEqual((self.base.creates, self.base.settles), (1, 0))

    def test_effective_epoch_lag_does_not_reserve_or_create(self):
        self.effective_epoch = 10
        self.assertIn('latest and effective epochs differ', self.tick())
        self.assertEqual((self.base.creates, self.base.settles), (1, 0))
        with sqlite3.connect(self.base.path / 'ledger.sqlite') as db:
            self.assertEqual(db.execute('SELECT count(*) FROM funding').fetchone()[0], 1)

    def test_post_creation_epoch_mismatch_reserves_without_relabel_or_retry(self):
        self.created_epoch = '10'
        self.assertIn('created escrow chain epoch', self.tick())
        self.assertIn('requires reconciliation', self.tick())
        self.assertEqual((self.base.creates, self.base.settles), (2, 0))
        with sqlite3.connect(self.base.path / 'ledger.sqlite') as db:
            self.assertEqual(db.execute('SELECT epoch,amount,escrow FROM funding ORDER BY epoch').fetchall(),
                             [(10,rotation.AMOUNT,'10'),(11,rotation.AMOUNT,'11')])


if __name__ == '__main__':
    unittest.main()
