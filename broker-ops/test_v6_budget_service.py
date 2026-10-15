import importlib.util
import hashlib
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-v6-budget-service.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ServiceTest(unittest.TestCase):
    def test_existing_campaign_preserved_for_both_instances(self):
        for instance in ('a', 'b'):
            with self.subTest(instance=instance), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                campaign = root / 'srv/dai/broker-tests' / ('v6-' + instance)
                ledger = campaign / 'rotation-10000gnk-20261013/ledger.sqlite'
                ledger.parent.mkdir(parents=True)
                with sqlite3.connect(ledger) as db:
                    db.execute('CREATE TABLE binding(instance TEXT, cap INTEGER)')
                    db.execute('INSERT INTO binding VALUES (?,5000)', (instance,))
                before = ledger.read_bytes()
                units = root / 'etc/systemd/system'
                units.mkdir(parents=True)
                name = 'gdc-v6-budget-' + instance
                for suffix in ('.service', '.timer'):
                    (units / (name + suffix)).write_text('original unit')
                calls = []
                def run(argv, **kwargs):
                    calls.append(argv)
                    self.assertEqual(argv[0], 'systemctl')
                    self.assertIn(argv[1], ('disable', 'show', 'daemon-reload'))
                    return subprocess.CompletedProcess(argv, 0, stdout='inactive\n')
                digest = installer.install(root, instance, 5000000000, 'Qwen/4B', run)
                self.assertEqual(ledger.read_bytes(), before)
                self.assertEqual((units / (name + '.service')).read_text(), 'original unit')
                dropin = units / (name + '.service.d/90-explicit-model.conf')
                self.assertIn('--amount 5000000000 --model Qwen/4B', dropin.read_text())
                self.assertIn('/srv/dai/broker-tests/v6-' + instance + '/budget-' + digest, dropin.read_text())
                self.assertNotIn('--settle-after-replacement', dropin.read_text())
                self.assertEqual(calls[0], ['systemctl', 'disable', '--now', name + '.timer'])
                self.assertEqual(installer.install(root, instance, 5000000000, 'Qwen/4B', run), digest)
                with self.assertRaisesRegex(ValueError, 'differs'):
                    installer.install(root, instance, 6000000000, 'Qwen/4B', run)
                def active(argv, **kwargs):
                    return subprocess.CompletedProcess(argv, 0, stdout='activating\n')
                with self.assertRaisesRegex(ValueError, 'still active'):
                    installer.install(root, instance, 5000000000, 'Qwen/4B', active)

                old = dropin.read_bytes()
                old_digest = hashlib.sha256(old).hexdigest()
                for expected in (None, '0' * 64):
                    with self.assertRaisesRegex(ValueError, 'differs'):
                        installer.install(root, instance, 5000000000, 'Qwen/4B', run,
                                          settle_after_replacement=True, expected_dropin_sha256=expected)
                    self.assertEqual(dropin.read_bytes(), old)
                backup = dropin.with_name(dropin.name + '.preimage-' + old_digest)
                backup.write_bytes(b'conflicting preimage')
                with self.assertRaisesRegex(ValueError, 'preimage conflict'):
                    installer.install(root, instance, 5000000000, 'Qwen/4B', run,
                                      settle_after_replacement=True, expected_dropin_sha256=old_digest)
                self.assertEqual(dropin.read_bytes(), old)
                backup.unlink()
                installer.install(root, instance, 5000000000, 'Qwen/4B', run,
                                  settle_after_replacement=True, expected_dropin_sha256=old_digest)
                self.assertIn('--settle-after-replacement', dropin.read_text())
                self.assertEqual(backup.read_bytes(), old)
                self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
                self.assertEqual(ledger.read_bytes(), before)
                installer.install(root, instance, 5000000000, 'Qwen/4B', run,
                                  settle_after_replacement=True, expected_dropin_sha256=old_digest)
                self.assertEqual(backup.read_bytes(), old)
                self.assertFalse(any(c[1] in ('start', 'enable', 'restart') for c in calls))
                dropin.unlink()
                with self.assertRaisesRegex(ValueError, 'expected drop-in is missing'):
                    installer.install(root, instance, 5000000000, 'Qwen/4B', run,
                                      settle_after_replacement=True, expected_dropin_sha256=old_digest)
                self.assertFalse(dropin.exists())
                dropin.symlink_to(backup)
                with self.assertRaisesRegex(ValueError, 'must not be a symlink'):
                    installer.install(root, instance, 5000000000, 'Qwen/4B', run,
                                      settle_after_replacement=True, expected_dropin_sha256=old_digest)
                self.assertEqual(backup.read_bytes(), old)

    def test_invalid_or_missing_campaign_never_invokes_systemctl(self):
        def unexpected(*args, **kwargs):
            self.fail('unexpected external operation')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                installer.install(root, 'a', 5, 'bad%model', unexpected)
            with self.assertRaisesRegex(ValueError, 'invalid expected'):
                installer.install(root, 'a', 5, 'model', unexpected, expected_dropin_sha256='bad')
            with self.assertRaises(sqlite3.OperationalError):
                installer.install(root, 'a', 5, 'model', unexpected)


if __name__ == '__main__':
    unittest.main()
