#!/usr/bin/env python3
"""Real lock/journal contracts, fake adapter is not official runtime acceptance."""

import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


root = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, root / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


apply = module('apply', '04-ops/devshard-cache-apply.py')
fixtures = module('fixtures', 'scripts/test-devshard-cache-lifecycle.py')


class ApplyContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.directory.chmod(0o700)
        self.adapter = fixtures.Adapter()
        self.adapter.identity = 'A'
        self.adapter.port = 18087
        self.adapter.directory = self.directory
        self.evidence = self.directory / 'attempt'

    def execute(self, **changes):
        arguments = {'expected_compose': hashlib.sha256(self.adapter.compose).hexdigest(),
                     'expected_settings': apply.lifecycle.digest(self.adapter.settings)}
        arguments.update(changes)
        return apply.apply_locked(self.adapter, self.evidence, **arguments)

    def test_changed_apply_holds_shared_lock_and_durable_private_journal(self):
        original = self.adapter.replace_settings
        def write(before, desired):
            with (self.directory / '.settings.lock').open('r+') as other:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            original(before, desired)
        self.adapter.replace_settings = write
        self.assertEqual(self.execute()['outcome'], 'PASS')
        self.assertEqual(self.adapter.calls, ['fence', 'compose', 'recreate', 'restore'])
        self.assertEqual(self.evidence.stat().st_mode & 0o777, 0o700)
        entries = sorted(self.evidence.iterdir())
        self.assertEqual(len(entries), 7)
        self.assertTrue(all(file.stat().st_mode & 0o777 == 0o600 for file in entries))
        self.assertEqual(json.loads(entries[-1].read_text())['outcome'], 'PASS')

    def test_existing_settings_lock_blocks_before_reads_or_evidence(self):
        with (self.directory / '.settings.lock').open('w') as owner:
            os.chmod(owner.name, 0o600)
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.adapter.read_compose = lambda: self.fail('read before lock admission')
            with self.assertRaises(BlockingIOError):
                self.execute(expected_compose='a' * 64)
        self.assertFalse(self.evidence.exists())
        self.assertEqual(self.adapter.calls, [])

    def test_stale_preimages_refuse_before_journal_or_mutation(self):
        for changes in ({'expected_compose': 'a' * 64}, {'expected_settings': 'a' * 64},
                        {'expected_compose': 'invalid'}):
            with self.assertRaises(ValueError):
                self.execute(**changes)
            self.assertEqual(self.adapter.calls, [])
            self.assertFalse(self.evidence.exists())

    def test_noop_checks_running_binding_without_journal_or_service_write(self):
        document = json.loads(self.adapter.compose)
        document['services']['gateway']['environment']['DEVSHARD_CHAT_CACHE_MAX_BYTES'] = '1'
        self.adapter.compose = json.dumps(document).encode()
        receipt = self.execute()
        self.assertEqual(receipt['outcome'], 'NO_CHANGE')
        self.assertFalse(receipt['applied'])
        self.assertEqual(self.adapter.calls, [])
        self.assertFalse(self.evidence.exists())
        self.adapter.failure = 'binding'
        with self.assertRaises(ValueError):
            self.execute()

    def test_symlink_hardlink_or_public_lock_refuses(self):
        lock = self.directory / '.settings.lock'
        target = self.directory / 'retained'
        target.write_text('retained bytes')
        target.chmod(0o600)
        lock.symlink_to(target)
        with self.assertRaises(OSError):
            self.execute()
        lock.unlink()
        os.link(target, lock)
        with self.assertRaises(ValueError):
            self.execute()
        lock.unlink()
        lock.touch(mode=0o644)
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(target.read_text(), 'retained bytes')
        self.assertFalse(self.evidence.exists())

    def test_unsafe_directory_or_existing_attempt_refuses_without_fence(self):
        self.directory.chmod(0o755)
        with self.assertRaises(ValueError):
            self.execute()
        self.directory.chmod(0o700)
        self.evidence.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(self.adapter.calls, [])

    def test_uncertain_dispatch_retains_journal_and_fence_without_retry(self):
        self.adapter.failure = 'recreate'
        with self.assertRaises(OSError):
            self.execute()
        self.assertEqual(self.adapter.calls, ['fence', 'compose', 'recreate'])
        self.assertTrue(self.adapter.settings['disabled']['enabled'])
        terminal = json.loads(sorted(self.evidence.iterdir())[-1].read_text())
        self.assertEqual(terminal['outcome'], 'INCONCLUSIVE')
        self.assertFalse(terminal['automatic_retry'])
        self.assertFalse(terminal['automatic_restore'])

    def test_complete_settings_are_restored_not_replaced_by_defaults(self):
        original = copy.deepcopy(self.adapter.settings)
        self.execute()
        self.assertEqual(self.adapter.settings, original)

    def test_lifecycle_preview_binds_complete_settings_without_journal_or_service_write(self):
        digest = hashlib.sha256(self.adapter.compose).hexdigest()
        receipt = apply.preview_locked(self.adapter, digest)
        self.assertEqual(receipt['schema'], 'gdc-devshard-cache-lifecycle-preview/1')
        self.assertEqual(receipt['port'], 18087)
        self.assertEqual(receipt['settings_before_sha256'],
                         apply.lifecycle.digest(self.adapter.settings))
        self.assertTrue(receipt['qualified_storage'])
        self.assertFalse(receipt['applied'])
        self.assertFalse(self.evidence.exists())
        self.assertEqual(self.adapter.calls, [])

    def test_lifecycle_preview_refuses_unqualified_runtime_storage_or_stale_compose(self):
        digest = hashlib.sha256(self.adapter.compose).hexdigest()
        for failure in ('binding', 'storage'):
            self.adapter.failure = failure
            with self.assertRaises(ValueError):
                apply.preview_locked(self.adapter, digest)
        self.adapter.failure = None
        with self.assertRaises(ValueError):
            apply.preview_locked(self.adapter, 'f' * 64)
        self.assertEqual(self.adapter.calls, [])


if __name__ == '__main__':
    unittest.main()
