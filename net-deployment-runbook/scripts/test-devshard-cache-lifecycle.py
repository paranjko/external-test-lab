#!/usr/bin/env python3
"""Lifecycle ordering contracts only, no mocked result is runtime acceptance."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lifecycle', root / '04-ops/devshard-cache-lifecycle.py')
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
fixture_spec = importlib.util.spec_from_file_location('policy_tests', root / 'scripts/test-devshard-cache-policy.py')
fixture = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(fixture)


class Journal:
    def __init__(self):
        self.events = []
        self.fail = None

    def record(self, kind, value):
        if kind == self.fail:
            raise OSError('synthetic journal failure')
        self.events.append((kind, copy.deepcopy(value)))


class Adapter:
    def __init__(self):
        self.compose = json.dumps(fixture.CachePolicyContracts().document('A')).encode()
        self.settings = {'disabled': {'enabled': False, 'message': 'preserve'},
                         'escrow_rotation': {'enabled': True, 'settlement_enabled': False},
                         'unknown': {'preserve': 7}}
        self.calls = []
        self.restarted = False
        self.failure = None
        self.omit_runtime_endpoint = False

    def read_compose(self):
        return self.compose

    def read_settings(self):
        return copy.deepcopy(self.settings)

    def read_state(self):
        nonce = 24 if self.restarted and self.failure == 'preservation' else 23
        if self.restarted and self.failure == 'cadence':
            nonce = 25
        balance = 998 if self.restarted and self.failure == 'cadence' else 1000
        persisted = copy.deepcopy(self.settings)
        if self.omit_runtime_endpoint:
            persisted.pop('chain_grpc', None)
        if self.failure == 'persisted' and self.calls:
            persisted['unknown']['preserve'] = 8
        return {'settings': persisted, 'devshards': [
            {'id': '42', 'active': True, 'model': 'synthetic-model',
             'runtime': {'id': '42', 'active': True, 'active_requests': 0,
                         'pending_race_cleanup': 0, 'reserved_tokens': 0,
                         'nonce': nonce, 'balance': balance, 'session_version': 'v5'}}]}

    def qualify_storage(self, state):
        if self.failure == 'storage':
            raise ValueError('synthetic unsupported storage layout')

    def read_ledgers(self, checkpoint):
        result = {}
        for identity, row in checkpoint['escrows'].items():
            nonce = row['session']['nonce']
            result[identity] = {'schema': 'gdc-devshard-session-ledger/1', 'escrow_id': identity,
                'version': 'v5', 'epoch': 1, 'latest_nonce': nonce, 'fee_per_nonce': 1,
                'open_inferences': [],
                'metadata_sha256': 'a' * 64, 'sealed_inferences_sha256': 'b' * 64,
                'diffs': [{'nonce': number, 'content_sha256': 'c' * 64,
                           'attestations_sha256': 'd' * 64, 'host_attestation_count': 1,
                           'tx_kinds': [10]} for number in range(1, nonce + 1)]}
        return result

    def verify_runtime(self, identity, image, volume):
        if self.failure == 'binding':
            raise ValueError('synthetic runtime binding differs')
        assert identity == 'A' and image == lifecycle.policy.instances.IMAGE
        assert volume == 'gdc-ds502-a-data'

    def replace_settings(self, before, desired):
        assert self.settings == before
        self.calls.append('restore' if self.restarted else 'fence')
        if self.failure == 'settings':
            raise OSError('synthetic uncertain settings POST')
        self.settings = copy.deepcopy(desired)

    def replace_compose(self, before, desired):
        assert self.compose == before
        self.calls.append('compose')
        self.compose = desired
        if self.failure == 'compose':
            raise OSError('synthetic uncertain Compose write')

    def recreate(self, identity):
        self.calls.append('recreate')
        if self.failure == 'recreate':
            raise OSError('synthetic uncertain recreation')
        self.restarted = True


class LifecycleContracts(unittest.TestCase):
    def setUp(self):
        self.adapter = Adapter()
        self.journal = Journal()
        self.original = copy.deepcopy(self.adapter.settings)

    def perform(self, **changes):
        arguments = {'expected_compose': hashlib.sha256(self.adapter.compose).hexdigest(),
                     'expected_settings': lifecycle.digest(self.adapter.settings)}
        arguments.update(changes)
        return lifecycle.perform(self.adapter, self.journal, 'A', **arguments,
                                 clock=lambda: 0, wait=lambda seconds: None)

    def test_complete_order_preserves_settings_and_writes_only_cap(self):
        original = json.loads(self.adapter.compose)
        receipt = self.perform()
        self.assertEqual(self.adapter.calls, ['fence', 'compose', 'recreate', 'restore'])
        self.assertEqual(self.adapter.settings, self.original)
        result = json.loads(self.adapter.compose)
        self.assertEqual(result['services']['gateway']['environment'].pop('DEVSHARD_CHAT_CACHE_MAX_BYTES'), '1')
        self.assertEqual(result, original)
        self.assertEqual(receipt['outcome'], 'PASS')
        self.assertEqual([event[0] for event in self.journal.events],
                         ['prepared', 'fence-dispatch', 'drained', 'compose-dispatch',
                          'recreate-dispatch', 'restore-dispatch', 'terminal'])

    def test_stale_compose_or_settings_cannot_fence(self):
        for arguments in ({'expected_compose': '0' * 64}, {'expected_settings': '0' * 64}):
            with self.assertRaises(ValueError):
                self.perform(**arguments)
            self.assertEqual(self.adapter.calls, [])

    def test_noop_refuses_without_settings_or_restart(self):
        document = json.loads(self.adapter.compose)
        document['services']['gateway']['environment']['DEVSHARD_CHAT_CACHE_MAX_BYTES'] = '1'
        self.adapter.compose = json.dumps(document).encode()
        with self.assertRaisesRegex(ValueError, 'unchanged'):
            self.perform()
        self.assertEqual(self.adapter.calls, [])

    def test_unqualified_runtime_refuses_before_mutation(self):
        self.adapter.failure = 'binding'
        with self.assertRaises(ValueError):
            self.perform()
        self.assertEqual(self.adapter.calls, [])

    def test_journal_failure_prevents_dispatch(self):
        self.journal.fail = 'fence-dispatch'
        with self.assertRaises(OSError):
            self.perform()
        self.assertEqual(self.adapter.calls, [])

    def test_uncertain_settings_compose_or_recreate_never_retries_or_restores(self):
        for failure, calls in (('settings', ['fence']), ('compose', ['fence', 'compose']),
                               ('recreate', ['fence', 'compose', 'recreate'])):
            self.adapter = Adapter()
            self.journal = Journal()
            self.adapter.failure = failure
            with self.assertRaises(OSError):
                self.perform()
            self.assertEqual(self.adapter.calls, calls)
            self.assertEqual(self.journal.events[-1][1]['outcome'], 'INCONCLUSIVE')
            self.assertFalse(self.journal.events[-1][1]['automatic_retry'])
            self.assertFalse(self.journal.events[-1][1]['automatic_restore'])

    def test_restart_session_drift_keeps_admission_fenced(self):
        self.adapter.failure = 'preservation'
        with self.assertRaisesRegex(ValueError, 'balance movement'):
            self.perform()
        self.assertEqual(self.adapter.calls, ['fence', 'compose', 'recreate'])
        self.assertTrue(self.adapter.settings['disabled']['enabled'])
        self.assertFalse(self.adapter.settings['escrow_rotation']['enabled'])

    def test_official_effective_endpoint_is_not_silently_added_to_persisted_state(self):
        self.adapter.settings['chain_grpc'] = 'mock-chain:9090'
        self.adapter.omit_runtime_endpoint = True
        original = copy.deepcopy(self.adapter.settings)
        receipt = self.perform()
        self.assertEqual(receipt['outcome'], 'PASS')
        self.assertEqual(self.adapter.settings, original)
        prepared = self.journal.events[0][1]
        self.assertEqual(prepared['original_settings'], original)
        self.assertNotIn('chain_grpc', prepared['original_persisted_settings'])
        self.assertEqual(lifecycle.digest(prepared['original_settings']), prepared['settings_before'])

    def test_any_other_view_mismatch_refuses_before_mutation(self):
        for effective, persisted in (
            ({'chain_grpc': ''}, {}),
            ({'chain_grpc': 'one'}, {'chain_grpc': 'two'}),
            ({'chain_grpc': 'one', 'unknown': 7}, {'unknown': 8}),
            ({'chain_grpc': 'one', 'unknown': 7}, {}),
        ):
            with self.assertRaisesRegex(ValueError, 'differ'):
                lifecycle.settings_views(effective, persisted)
        self.adapter.failure = 'persisted'
        with self.assertRaisesRegex(ValueError, 'persisted settings drift'):
            self.perform()
        self.assertEqual(self.adapter.calls, ['fence'])

    def test_effective_endpoint_drift_is_not_ignored_after_restart(self):
        self.adapter.settings['chain_grpc'] = 'mock-chain:9090'
        self.adapter.omit_runtime_endpoint = True
        original_recreate = self.adapter.recreate
        def recreate(identity):
            original_recreate(identity)
            self.adapter.settings['chain_grpc'] = 'changed-chain:9090'
        self.adapter.recreate = recreate
        with self.assertRaisesRegex(ValueError, 'effective settings drift'):
            self.perform()
        self.assertEqual(self.adapter.calls, ['fence', 'compose', 'recreate'])
        self.assertTrue(self.adapter.settings['disabled']['enabled'])

    def test_qualified_cadence_extensions_preserve_prefix_and_exact_fees(self):
        self.adapter.failure = 'cadence'
        receipt = self.perform()
        self.assertEqual(receipt['ledger_preservation']['extensions']['42']['fee'], 2)
        self.assertEqual(receipt['ledger_preservation']['extensions']['42']['nonce_after'], 25)
        self.assertEqual(self.adapter.calls, ['fence', 'compose', 'recreate', 'restore'])
        self.assertEqual(self.adapter.settings, self.original)
        drained = next(value for kind, value in self.journal.events if kind == 'drained')
        self.assertEqual(drained['checkpoint']['escrows']['42']['session']['nonce'], 23)
        self.assertEqual(len(drained['ledgers']['42']['diffs']), 23)

    def test_unsupported_storage_refuses_before_fencing_or_journal(self):
        self.adapter.failure = 'storage'
        with self.assertRaisesRegex(ValueError, 'unsupported storage'):
            self.perform()
        self.assertEqual(self.adapter.calls, [])
        self.assertEqual(self.journal.events, [])

    def test_ledger_prefix_rewrite_keeps_admission_fenced(self):
        original = self.adapter.read_ledgers
        def ledgers(checkpoint):
            result = original(checkpoint)
            if self.adapter.restarted:
                result['42']['diffs'][0]['content_sha256'] = 'f' * 64
            return result
        self.adapter.read_ledgers = ledgers
        with self.assertRaisesRegex(ValueError, 'prefix'):
            self.perform()
        self.assertEqual(self.adapter.calls, ['fence', 'compose', 'recreate'])
        self.assertTrue(self.adapter.settings['disabled']['enabled'])

    def test_ledger_pending_closure_blocks_compose_until_two_closed_samples(self):
        original = self.adapter.read_ledgers
        samples = [True, False, True, False, False, False, False, False, False]
        observed = []
        def ledgers(checkpoint):
            result = original(checkpoint)
            pending = samples.pop(0) if samples else False
            observed.append(pending)
            result['42']['open_inferences'] = [23] if pending else []
            if pending:
                self.assertEqual(self.adapter.calls, ['fence'])
            return result
        self.adapter.read_ledgers = ledgers
        self.assertEqual(self.perform()['outcome'], 'PASS')
        self.assertEqual(observed[:5], [True, False, True, False, False])
        self.assertEqual(self.adapter.calls, ['fence', 'compose', 'recreate', 'restore'])

    def test_late_second_fenced_state_read_cannot_write_compose_or_recreate(self):
        elapsed = [0.0]
        reads = [0]
        original = self.adapter.read_state
        compose = self.adapter.compose
        def late():
            state = original()
            if self.adapter.calls == ['fence']:
                reads[0] += 1
                if reads[0] == 2:
                    elapsed[0] += 2
            return state
        self.adapter.read_state = late
        with self.assertRaisesRegex(ValueError, 'deadline'):
            lifecycle.perform(self.adapter, self.journal, 'A',
                hashlib.sha256(compose).hexdigest(), lifecycle.digest(self.adapter.settings),
                timeout=1, clock=lambda: elapsed[0], wait=lambda seconds: None)
        self.assertEqual(self.adapter.calls, ['fence'])
        self.assertEqual(self.adapter.compose, compose)
        self.assertFalse(self.adapter.restarted)
        self.assertTrue(self.adapter.settings['disabled']['enabled'])
        self.assertEqual(self.journal.events[-1][1]['outcome'], 'INCONCLUSIVE')

    def test_late_checkpoint_collection_cannot_advance_to_compose_dispatch(self):
        elapsed = [0.0]
        reads = [0]
        original = self.adapter.read_ledgers
        compose = self.adapter.compose
        def late(checkpoint):
            value = original(checkpoint)
            reads[0] += 1
            if reads[0] == 3:
                elapsed[0] += 2
            return value
        self.adapter.read_ledgers = late
        with self.assertRaisesRegex(ValueError, 'deadline'):
            lifecycle.perform(self.adapter, self.journal, 'A',
                hashlib.sha256(compose).hexdigest(), lifecycle.digest(self.adapter.settings),
                timeout=1, clock=lambda: elapsed[0], wait=lambda seconds: None)
        self.assertEqual(self.adapter.calls, ['fence'])
        self.assertEqual(self.adapter.compose, compose)
        self.assertFalse(self.adapter.restarted)


if __name__ == '__main__':
    unittest.main()
