#!/usr/bin/env python3
"""Behavioral capability checks, with no network or remote Host operations."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')
PREFIX = (ROOT / 'gdc.sh').read_text().split('\nLAUNCHER_SOURCE=', 1)[0]


class Preflight(unittest.TestCase):
    def run_probe(self, prefix=PREFIX, setup='', missing=None, broken=None):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory) / 'bin'
            bin_dir.mkdir()
            commands = ('bash python3 jq curl ssh rsync git flock realpath stat sha256sum '
                        'date base64 find tar unzip openssl sed gzip true mktemp rm cut mkdir cmp od tr').split()
            for name in commands:
                if name != missing:
                    target = shutil.which(name)
                    self.assertIsNotNone(target, name)
                    (bin_dir / name).symlink_to(target)
            if broken:
                name, body = broken
                (bin_dir / name).unlink()
                (bin_dir / name).write_text('#!/bin/sh\n' + body + '\n')
                (bin_dir / name).chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir))
            return subprocess.run([BASH, '-c', setup + '\n' + prefix + '\necho PREFLIGHT_PASSED'],
                                  env=env, capture_output=True, text=True, timeout=30)

    def assert_rejected(self, result, diagnostic):
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn('PREFLIGHT_PASSED', result.stdout)
        self.assertIn(diagnostic, result.stderr)
        self.assertIn('make cleanroom cmd=bash', result.stderr)

    def test_version_boundary(self):
        # Only the readonly input is renamed in this isolated executable copy.
        prefix = PREFIX.replace('(( BASH_VERSINFO[0] >= 4 )) ||', '(( TEST_BASH_VERSINFO[0] >= 4 )) ||', 1)
        for major in (3, 4, 5):
            result = self.run_probe(prefix, f'TEST_BASH_VERSINFO=({major})')
            if major == 3:
                self.assert_rejected(result, 'requires Bash 4')
            else:
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_platform_and_commands(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PREFLIGHT_PASSED', result.stdout)

    def test_kernel_does_not_replace_capabilities(self):
        for platform in ('Darwin', 'Linux'):
            result = self.run_probe(setup=f'uname() {{ echo {platform}; }}')
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_commands(self):
        for tool in ('flock', 'realpath', 'sha256sum', 'python3', 'openssl'):
            with self.subTest(tool=tool):
                self.assert_rejected(self.run_probe(missing=tool), 'missing operator commands: ' + tool)

    def test_incompatible_commands(self):
        for tool, diagnostic in [('realpath', 'realpath -e'), ('stat', 'stat -c'),
                                 ('date', 'date -d'), ('openssl', 'Ed25519'),
                                 ('tar', 'tar archive'), ('base64', 'base64 -d')]:
            with self.subTest(tool=tool):
                self.assert_rejected(self.run_probe(broken=(tool, 'exit 1')), diagnostic)

    def test_realpath_missing_m(self):
        real = shutil.which('realpath')
        self.assert_rejected(self.run_probe(broken=('realpath',
            f'[ "$1" != -m ] || exit 1\nexec "{real}" "$@"')), 'realpath -m')

    def test_lock_noop_is_rejected(self):
        self.assert_rejected(self.run_probe(broken=('flock', 'exit 0')), 'lock contention')

    def test_child_bash_must_be_modern(self):
        self.assert_rejected(self.run_probe(broken=('bash', 'exit 1')), 'bash on PATH')

    def test_actual_bash3_when_available(self):
        old = subprocess.run(['/bin/bash', '-c', 'echo ${BASH_VERSINFO[0]}'], capture_output=True, text=True)
        if old.stdout.strip() != '3':
            self.skipTest('/bin/bash is not Bash 3')
        result = subprocess.run(['/bin/bash', str(ROOT / 'gdc.sh'), '--help'], capture_output=True, text=True)
        self.assert_rejected(result, 'requires Bash 4')


if __name__ == '__main__':
    unittest.main()
