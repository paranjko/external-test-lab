#!/usr/bin/env python3
"""Pure drain predicates, not an official-image restart acceptance test."""

import copy
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location('drain', Path(__file__).resolve().parents[1]
                                            / '04-ops/devshard-cache-drain.py')
drain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drain)


class DrainContracts(unittest.TestCase):
    def state(self):
        return {'settings': {'disabled': {'enabled': True},
                             'escrow_rotation': {'enabled': False, 'settlement_enabled': False},
                             'unknown_preserved': {'value': 7}},
                'devshards': [{'id': '42', 'active': True, 'model': 'synthetic-model',
                               'runtime': {'id': '42', 'active': True, 'active_requests': 0,
                                           'pending_race_cleanup': 0, 'reserved_tokens': 0,
                                           'nonce': 23, 'balance': 1000, 'session_version': '/devshard/v5'}}]}

    def test_two_quiet_samples_and_restart_preserve_full_state(self):
        first = self.state()
        original = copy.deepcopy(first)
        sealed = drain.confirm_drained(first, copy.deepcopy(first))
        receipt = drain.confirm_preserved(sealed, first)
        self.assertTrue(receipt['preserved'])
        self.assertEqual(receipt['escrow_count'], 1)
        self.assertEqual(first, original)

    def retired_state(self):
        state = self.state()
        state['devshards'].append({'id': '41', 'active': False,
                                  'model': 'synthetic-model',
                                  'storage_path': '/root/.devshardctl/escrow-41',
                                  'unknown_retained': {'keep': 7}})
        return state

    def test_retired_runtime_less_record_is_preserved_without_invented_accounting(self):
        state = self.retired_state()
        original = copy.deepcopy(state)
        checkpoint = drain.confirm_drained(state, copy.deepcopy(state))
        self.assertEqual(set(checkpoint['escrows']), {'41', '42'})
        self.assertIsNone(checkpoint['escrows']['41']['session'])
        self.assertEqual(checkpoint['escrows']['41']['persisted'], state['devshards'][1])
        self.assertEqual(drain.confirm_preserved(checkpoint, state)['escrow_count'], 2)
        self.assertEqual(state, original)

    def test_retired_record_loss_change_or_reactivation_refuses_preservation(self):
        before = self.retired_state()
        checkpoint = drain.snapshot(before)
        for mutation in (
            lambda s: s['devshards'].pop(),
            lambda s: s['devshards'][1]['unknown_retained'].update(keep=8),
            lambda s: s['devshards'][1].update(active=True),
            lambda s: s['devshards'][1].update(storage_path='changed'),
        ):
            after = copy.deepcopy(before)
            mutation(after)
            with self.assertRaises(ValueError):
                drain.confirm_preserved(checkpoint, after)

    def test_retired_record_does_not_hide_unknown_runtime_or_pending_settlement(self):
        for fields in ({'runtime': None}, {'runtime': {}}, {'active': 0},
                       {'settlement_pending': True}, {'private_key_hex': 'synthetic-secret'}):
            state = self.retired_state()
            state['devshards'][1].update(fields)
            with self.assertRaises(ValueError):
                drain.snapshot(state)

    def test_every_foreground_background_and_reserved_counter_must_be_zero(self):
        for field in ('active_requests', 'pending_race_cleanup', 'reserved_tokens'):
            for value in (1, -1, False, '0', None):
                state = self.state()
                state['devshards'][0]['runtime'][field] = value
                with self.assertRaises(ValueError):
                    drain.snapshot(state)
            state = self.state()
            del state['devshards'][0]['runtime'][field]
            with self.assertRaises(ValueError):
                drain.snapshot(state)

    def test_admission_rotation_and_settlement_fences_are_required(self):
        for path in (('disabled', 'enabled'), ('escrow_rotation', 'enabled'),
                     ('escrow_rotation', 'settlement_enabled')):
            state = self.state()
            state['settings'][path[0]][path[1]] = not state['settings'][path[0]][path[1]]
            with self.assertRaises(ValueError):
                drain.snapshot(state)

    def test_unknown_runtime_empty_inventory_duplicate_and_secrets_are_refused(self):
        for mutation in (
            lambda s: s.update(devshards=[]),
            lambda s: s['devshards'].append(copy.deepcopy(s['devshards'][0])),
            lambda s: s['devshards'][0].pop('runtime'),
            lambda s: s['devshards'][0].update(private_key_hex='synthetic-secret'),
            lambda s: s['devshards'][0].update(private_key='synthetic-secret'),
            lambda s: s['devshards'][0].update(settlement_pending=True),
            lambda s: s['devshards'][0]['runtime'].update(id='43'),
        ):
            state = self.state()
            mutation(state)
            with self.assertRaises(ValueError):
                drain.snapshot(state)

    def test_nonce_balance_protocol_and_unknown_persisted_fields_cannot_drift(self):
        for mutation in (
            lambda s: s['devshards'][0]['runtime'].update(nonce=24),
            lambda s: s['devshards'][0]['runtime'].update(balance=999),
            lambda s: s['devshards'][0]['runtime'].update(session_version='/devshard/v4'),
            lambda s: s['settings']['unknown_preserved'].update(value=8),
            lambda s: s['devshards'][0].update(model='other-model'),
        ):
            before, after = self.state(), self.state()
            mutation(after)
            with self.assertRaises(ValueError):
                drain.confirm_drained(before, after)
            with self.assertRaises(ValueError):
                drain.confirm_preserved(drain.snapshot(before), after)

    def test_absent_or_untyped_accounting_is_not_zero(self):
        for field in ('nonce', 'balance', 'session_version'):
            state = self.state()
            state['devshards'][0]['runtime'].pop(field)
            with self.assertRaises(ValueError):
                drain.snapshot(state)

    def test_fence_preserves_all_other_fields_and_original(self):
        original = self.state()['settings']
        original['disabled'].update(enabled=False, message='retained-message', new_url='retained-url')
        original['escrow_rotation'].update(enabled=True, settlement_enabled=True, extra={'keep': True})
        saved = copy.deepcopy(original)
        actual = drain.fenced_settings(original)
        self.assertTrue(actual['disabled']['enabled'])
        self.assertFalse(actual['escrow_rotation']['enabled'])
        self.assertFalse(actual['escrow_rotation']['settlement_enabled'])
        actual['disabled']['enabled'] = False
        actual['escrow_rotation']['enabled'] = True
        actual['escrow_rotation']['settlement_enabled'] = True
        self.assertEqual(actual, saved)
        self.assertEqual(original, saved)

    def waiter(self, samples, deadline=5):
        elapsed = [0.0]
        calls = []
        def read():
            calls.append(True)
            value = samples.pop(0)
            if isinstance(value, Exception):
                raise value
            return value
        def wait(seconds):
            elapsed[0] += seconds
        return drain.wait_drained(read, deadline, clock=lambda: elapsed[0], wait=wait), calls

    def test_busy_background_work_requires_two_subsequent_quiet_samples(self):
        busy = self.state()
        busy['devshards'][0]['runtime']['pending_race_cleanup'] = 1
        result, calls = self.waiter([self.state(), busy, self.state(), self.state()])
        self.assertEqual(result, drain.snapshot(self.state()))
        self.assertEqual(len(calls), 4)

    def test_invalid_sample_or_transport_error_aborts_without_retry(self):
        invalid = self.state()
        invalid['devshards'][0]['runtime'].pop('pending_race_cleanup')
        for value in (invalid, OSError('synthetic read failure')):
            samples = [value, self.state()]
            with self.assertRaises((ValueError, OSError)):
                self.waiter(samples)
            self.assertEqual(len(samples), 1)

    def test_busy_counter_does_not_hide_missing_background_telemetry(self):
        invalid = self.state()
        invalid['devshards'][0]['runtime']['active_requests'] = 1
        invalid['devshards'][0]['runtime'].pop('pending_race_cleanup')
        samples = [invalid, self.state()]
        with self.assertRaisesRegex(ValueError, 'telemetry'):
            self.waiter(samples)
        self.assertEqual(len(samples), 1)

    def test_deadline_and_quiet_drift_refuse_restart(self):
        busy = self.state()
        busy['devshards'][0]['runtime']['active_requests'] = 1
        with self.assertRaisesRegex(ValueError, 'deadline'):
            self.waiter([busy, busy], deadline=0.75)
        drifted = self.state()
        drifted['devshards'][0]['runtime']['nonce'] += 1
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.waiter([self.state(), drifted])

    def test_late_successful_read_or_qualification_never_returns_a_quiet_checkpoint(self):
        for stage in ('read', 'qualify'):
            elapsed = [0.0]
            calls = [0]
            def read():
                calls[0] += 1
                if stage == 'read' and calls[0] == 2:
                    elapsed[0] += 2
                return self.state()
            def qualify(checkpoint):
                if stage == 'qualify' and calls[0] == 2:
                    elapsed[0] += 2
            def wait(seconds):
                elapsed[0] += seconds
            with self.assertRaisesRegex(ValueError, 'deadline'):
                drain.wait_drained(read, 1, clock=lambda: elapsed[0], wait=wait, qualify=qualify)
            self.assertEqual(calls[0], 2)


if __name__ == '__main__':
    unittest.main()
