#!/usr/bin/env python3
"""Narrow native-adapter transport/file contracts, not live acceptance."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('runtime', Path(__file__).resolve().parents[1]
                                            / '04-ops/devshard-cache-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.adapter = object.__new__(runtime.Native)
        self.adapter.identity = 'A'
        self.adapter.directory = Path(self.temp.name)
        self.adapter.compose = self.adapter.directory / 'compose.json'
        self.adapter.secret_file = self.adapter.directory / 'gateway.env'
        self.adapter.project = 'gdc-ds502-a'
        self.adapter.port = 18087
        self.adapter.secret_file.write_text('DEVSHARD_ADMIN_API_KEY=synthetic-private-admin\n')
        self.adapter.secret_file.chmod(0o600)
        self.document = {'name': self.adapter.project, 'services': {'gateway': {
            'environment': {}, 'env_file': [{'path': str(self.adapter.secret_file), 'format': 'raw'}]}}}
        self.adapter.compose.write_bytes(json.dumps(self.document).encode())
        self.adapter.compose.chmod(0o640)
        self.calls = []

    def metadata(self):
        return {'image': runtime.settings.instances.IMAGE, 'running': True,
                'labels': {'com.docker.compose.project': 'gdc-ds502-a',
                           'com.docker.compose.service': 'gateway', 'org.gonka.test-lab.instance': 'A'},
                'mounts': [{'Type': 'volume', 'Name': 'gdc-ds502-a-data',
                            'Destination': '/root/.devshardctl', 'RW': True}],
                'ports': {'8080/tcp': [{'HostIp': '127.0.0.1', 'HostPort': '18087'}]},
                'environment': ['selected', 'DEVSHARD_CHAIN_ID=gonka-devnet-community',
                                'DEVSHARD_ROUTE_PREFIX=/devshard/v5']}

    def verify(self, metadata):
        def command(arguments, **kwargs):
            self.calls.append(arguments)
            expected = self.adapter.compose_command('ps', '--all', '--quiet', 'gateway')
            if arguments == expected:
                return 'a' * 64 + '\n'
            if arguments[:3] == ['docker', 'inspect', '--format'] and arguments[-1] == 'a' * 64:
                self.assertEqual(len(arguments), 5)
                self.assertNotIn('{{json .Config.Env}}', arguments[3])
                return json.dumps(metadata)
            raise AssertionError('unexpected native operation')
        with patch.object(self.adapter, 'command', side_effect=command):
            self.adapter.verify_runtime('A', runtime.settings.instances.IMAGE, 'gdc-ds502-a-data')

    def test_exact_runtime_binding_checks_selected_metadata_only(self):
        self.verify(self.metadata())
        self.assertEqual(len(self.calls), 2)

    def test_unknown_volume_image_public_listener_protocol_and_cap_refuse(self):
        for mutation in (
            lambda s: s.update(image='unqualified:image'),
            lambda s: s.update(running=False),
            lambda s: s['mounts'][0].update(Name='other-state'),
            lambda s: s['mounts'].append(copy.deepcopy(s['mounts'][0])),
            lambda s: s['ports']['8080/tcp'][0].update(HostIp='0.0.0.0'),
            lambda s: s['environment'].remove('DEVSHARD_ROUTE_PREFIX=/devshard/v5'),
            lambda s: s['environment'].append('DEVSHARD_CHAT_CACHE_MAX_BYTES=1'),
        ):
            state = self.metadata()
            mutation(state)
            with self.assertRaises(ValueError):
                self.verify(state)

    def test_atomic_compose_replace_retains_owner_group_mode_and_no_temp_artifacts(self):
        before = self.adapter.read_compose()
        stat_before = self.adapter.compose.stat()
        desired = before + b'\n'
        self.adapter.replace_compose(before, desired)
        stat_after = self.adapter.compose.stat()
        self.assertEqual(self.adapter.read_compose(), desired)
        self.assertEqual((stat_before.st_uid, stat_before.st_gid, stat_before.st_mode),
                         (stat_after.st_uid, stat_after.st_gid, stat_after.st_mode))
        self.assertEqual(list(self.adapter.directory.glob('.cache-policy-*')), [])

    def test_stale_file_and_symlink_are_refused(self):
        before = self.adapter.read_compose()
        with self.assertRaises(ValueError):
            self.adapter.replace_compose(b'old', before)
        self.assertEqual(self.adapter.read_compose(), before)
        backing = self.adapter.directory / 'preserved.json'
        self.adapter.compose.rename(backing)
        self.adapter.compose.symlink_to(backing)
        with self.assertRaises(ValueError):
            self.adapter.replace_compose(before, before + b'\n')
        self.assertEqual(backing.read_bytes(), before)

    def test_authentication_uses_stdin_and_only_private_admin_paths(self):
        def command(arguments, **kwargs):
            self.assertNotIn('synthetic-private-admin', ' '.join(arguments))
            self.assertIn('synthetic-private-admin', kwargs['input'])
            self.assertIn('http://127.0.0.1:18087/v1/admin/state', arguments)
            return '{"synthetic": true}'
        with patch.object(self.adapter, 'command', side_effect=command) as operation:
            self.assertEqual(self.adapter.read_state(), {'synthetic': True})
            with self.assertRaises(ValueError):
                self.adapter.request('GET', '/v1/chat/completions')
            self.assertEqual(operation.call_count, 1)

    def test_timeout_or_nonzero_transport_is_uncertain_and_not_retried(self):
        for response in (subprocess.TimeoutExpired(['synthetic'], 1),
                         subprocess.CompletedProcess(['synthetic'], 1, 'private-output', 'private-error')):
            with patch.object(runtime.subprocess, 'run', side_effect=response if isinstance(response, Exception) else None,
                              return_value=response) as operation:
                with self.assertRaises(ValueError) as failure:
                    self.adapter.command(['synthetic'])
                self.assertEqual(operation.call_count, 1)
                self.assertNotIn('private-', str(failure.exception))

    def test_recreate_uses_only_named_service_without_dependencies_or_volume_deletion(self):
        with patch.object(self.adapter, 'command') as operation, patch.object(self.adapter, 'wait_ready') as ready:
            self.adapter.recreate('A')
            operation.assert_called_once_with(self.adapter.compose_command(
                'up', '--detach', '--no-deps', '--force-recreate', 'gateway'), timeout=120)
            ready.assert_called_once_with()
            with self.assertRaises(ValueError):
                self.adapter.recreate('B')

    def test_readiness_retries_only_proven_listener_unavailability(self):
        elapsed = [0.0]
        def wait(seconds):
            elapsed[0] += seconds
        with patch.object(self.adapter, 'read_settings', side_effect=[runtime.ListenerUnavailable('offline'), {}]) as read:
            self.adapter.wait_ready(clock=lambda: elapsed[0], wait=wait)
            self.assertEqual(read.call_count, 2)
            self.assertEqual(elapsed[0], 0.5)
        for failure in (ValueError('authentication refused'), ValueError('invalid JSON'),
                        ValueError('operation deadline exceeded')):
            with patch.object(self.adapter, 'read_settings', side_effect=failure) as read:
                with self.assertRaises(ValueError):
                    self.adapter.wait_ready(clock=lambda: elapsed[0], wait=wait)
                self.assertEqual(read.call_count, 1)

    def test_readiness_deadline_does_not_repeat_mutations(self):
        elapsed = [0.0]
        def wait(seconds):
            elapsed[0] += seconds
        with patch.object(self.adapter, 'read_settings', side_effect=runtime.ListenerUnavailable('offline')) as read:
            with self.assertRaisesRegex(ValueError, 'deadline'):
                self.adapter.wait_ready(timeout=1, clock=lambda: elapsed[0], wait=wait)
            self.assertEqual(read.call_count, 2)

    def test_late_successful_read_is_rejected_and_budget_is_restored(self):
        elapsed = [0.0]
        def late():
            elapsed[0] += 2
            return {}
        with patch.object(self.adapter, 'read_settings', side_effect=late) as read:
            with self.assertRaisesRegex(ValueError, 'deadline'):
                self.adapter.wait_ready(timeout=1, clock=lambda: elapsed[0])
            self.assertEqual(read.call_count, 1)
        self.assertIsNone(self.adapter._read_deadline)

    def test_readiness_transport_uses_only_remaining_deadline_budget(self):
        def command(arguments, **kwargs):
            self.assertEqual(arguments[arguments.index('--max-time') + 1], '1.0')
            self.assertEqual(arguments[arguments.index('--connect-timeout') + 1], '1.0')
            self.assertEqual(kwargs['timeout'], 1)
            return '{}'
        with patch.object(self.adapter, 'command', side_effect=command) as operation:
            self.adapter.wait_ready(timeout=1, clock=lambda: 0.0)
            self.assertEqual(operation.call_count, 1)
        self.assertIsNone(self.adapter._read_deadline)

    def test_only_curl_listener_errors_are_retryable(self):
        for executable, code in (('curl', 7), ('curl', 52), ('curl', 56), ('curl', 22), ('docker', 7)):
            result = subprocess.CompletedProcess([executable], code, '', 'private-details')
            expected = runtime.ListenerUnavailable if executable == 'curl' and code in (7, 52, 56) else ValueError
            with patch.object(runtime.subprocess, 'run', return_value=result):
                with self.assertRaises(expected) as failure:
                    self.adapter.command([executable])
                if expected is ValueError:
                    self.assertNotIsInstance(failure.exception, runtime.ListenerUnavailable)
                self.assertNotIn('private-details', str(failure.exception))

    def test_ledger_collection_binds_exact_local_volume_and_canonical_escrow_path(self):
        checkpoint = {'escrows': {'42': {'persisted': {'storage_path': '/root/.devshardctl/escrow-42'},
                                        'session': {'nonce': 2, 'balance': 1000, 'session_version': 'v5'}}}}
        volume = {'Name': 'gdc-ds502-a-data', 'Driver': 'local', 'Options': None,
                  'Mountpoint': str(self.adapter.directory)}
        with patch.object(self.adapter, 'verify_runtime') as verify, \
                patch.object(self.adapter, 'command', return_value=json.dumps(volume)) as operation, \
                patch.object(runtime.ledger, 'collect', return_value={'qualified': True}) as collect:
            self.assertEqual(self.adapter.read_ledgers(checkpoint), {'42': {'qualified': True}})
            verify.assert_called_once_with('A', runtime.settings.instances.IMAGE, 'gdc-ds502-a-data')
            operation.assert_called_once_with(['docker', 'volume', 'inspect', '--format', '{{json .}}',
                                                'gdc-ds502-a-data'])
            collect.assert_called_once_with(self.adapter.directory / 'escrow-42', '42',
                                           checkpoint['escrows']['42']['session'])
            checkpoint['escrows']['42']['persisted']['storage_path'] = '/outside/escrow-42'
            with self.assertRaises(ValueError):
                self.adapter.read_ledgers(checkpoint)
            self.assertEqual(collect.call_count, 1)

    def test_volume_driver_options_and_symlink_scope_refuse_before_database_reads(self):
        for changes in ({'Name': 'other'}, {'Driver': 'foreign'}, {'Options': {'device': '/outside'}},
                        {'Mountpoint': 'relative'}):
            volume = {'Name': 'gdc-ds502-a-data', 'Driver': 'local', 'Options': None,
                      'Mountpoint': str(self.adapter.directory), **changes}
            with patch.object(self.adapter, 'verify_runtime'), \
                    patch.object(self.adapter, 'command', return_value=json.dumps(volume)), \
                    patch.object(runtime.ledger, 'collect') as collect:
                with self.assertRaises(ValueError):
                    self.adapter.read_ledgers({'escrows': {}})
                collect.assert_not_called()

    def test_storage_preflight_requires_redacted_unique_bound_v5_sessions(self):
        row = {'id': '42', 'storage_path': '/root/.devshardctl/escrow-42',
               'runtime': {'id': '42', 'nonce': 2, 'balance': 1000, 'session_version': 'v5'}}
        with patch.object(self.adapter, 'read_ledgers') as collect:
            self.adapter.qualify_storage({'devshards': [row]})
            self.assertEqual(collect.call_count, 1)
            for mutation in (
                lambda s: s.update(devshards=[]),
                lambda s: s['devshards'].append(copy.deepcopy(s['devshards'][0])),
                lambda s: s['devshards'][0].update(private_key='must-not-read'),
                lambda s: s['devshards'][0]['runtime'].update(id='43'),
                lambda s: s['devshards'][0]['runtime'].update(session_version='v4'),
                lambda s: s['devshards'][0]['runtime'].update(nonce=True),
            ):
                state = {'devshards': [copy.deepcopy(row)]}
                mutation(state)
                with self.assertRaises(ValueError):
                    self.adapter.qualify_storage(state)
            self.assertEqual(collect.call_count, 1)

    def test_journal_syncs_parent_and_each_private_entry_before_returning(self):
        directory = self.adapter.directory / 'new-journal'
        with patch.object(runtime.Journal, 'sync_directory', wraps=runtime.Journal.sync_directory) as sync:
            journal = runtime.Journal(directory)
            receipt = journal.record('prepared', {'synthetic': True})
            self.assertEqual(sync.call_args_list[0].args, (directory.parent,))
            self.assertEqual(sync.call_args_list[1].args, (directory,))
        self.assertEqual(len(receipt), 64)
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((directory / '001-prepared.json').stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            runtime.Journal(directory)

    def test_failed_journal_directory_sync_is_not_a_dispatch_success(self):
        journal = runtime.Journal(self.adapter.directory / 'uncertain-journal')
        with patch.object(journal, 'sync_directory', side_effect=OSError('synthetic fsync failure')):
            with self.assertRaises(OSError):
                journal.record('fence-dispatch', {'synthetic': True})
        self.assertTrue((journal.directory / '001-fence-dispatch.json').exists())


if __name__ == '__main__':
    unittest.main()
