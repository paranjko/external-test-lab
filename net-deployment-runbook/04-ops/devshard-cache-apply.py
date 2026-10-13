#!/usr/bin/env python3
"""Explicit native cache apply under the existing instance settings lock.

This helper is not a GDC rollout approval, the caller must bind its preview
"""

import argparse
from contextlib import contextmanager
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


runtime = module('apply_runtime', 'devshard-cache-runtime.py')
lifecycle = module('apply_lifecycle', 'devshard-cache-lifecycle.py')
require = lifecycle.require


@contextmanager
def settings_lock(directory):
    directory = Path(directory)
    require(directory.is_dir() and directory.resolve(strict=True) == directory
            and directory.stat().st_uid == os.getuid()
            and stat.S_IMODE(directory.stat().st_mode) == 0o700,
            'exact private instance directory required')
    descriptor = os.open(directory / '.settings.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
                and metadata.st_nlink == 1 and stat.S_IMODE(metadata.st_mode) == 0o600,
                'private owned settings lock required')
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(descriptor)


def apply_locked(adapter, evidence, expected_compose, expected_settings, timeout=120):
    require(all(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value)
                for value in (expected_compose, expected_settings)), 'exact approved preimages required')
    with settings_lock(adapter.directory):
        before = adapter.read_compose()
        preview, _ = lifecycle.policy.preview(before, adapter.identity, expected_compose)
        original = adapter.read_settings()
        require(lifecycle.digest(original) == expected_settings, 'settings preview changed')
        if not preview['delta']:
            adapter.verify_runtime(adapter.identity, preview['image'], preview['state_volume'])
            require(adapter.read_compose() == before and adapter.read_settings() == original,
                    'no-op runtime preimage changed')
            return {**preview, 'outcome': 'NO_CHANGE', 'settings_sha256': expected_settings}
        evidence = Path(evidence)
        parent = evidence.parent
        require(parent.is_dir() and parent.resolve(strict=True) == parent
                and parent.stat().st_uid == os.getuid()
                and stat.S_IMODE(parent.stat().st_mode) == 0o700,
                'existing private owned journal parent required')
        require(not evidence.exists() and not evidence.is_symlink(), 'new journal attempt required')
        return lifecycle.perform(adapter, runtime.Journal(evidence), adapter.identity,
                                 expected_compose, expected_settings, timeout=timeout)


def preview_locked(adapter, expected_compose):
    """Separate lifecycle preview, the original Compose-only preview is unchanged."""
    require(isinstance(expected_compose, str) and re.fullmatch('[0-9a-f]{64}', expected_compose),
            'exact Compose preimage required')
    with settings_lock(adapter.directory):
        before = adapter.read_compose()
        receipt, _ = lifecycle.policy.preview(before, adapter.identity, expected_compose)
        adapter.verify_runtime(adapter.identity, receipt['image'], receipt['state_volume'])
        settings = adapter.read_settings()
        state = adapter.read_state()
        require(isinstance(state, dict), 'complete preview admin state required')
        lifecycle.settings_views(settings, state.get('settings'))
        adapter.qualify_storage(state)
        require(adapter.read_compose() == before and adapter.read_settings() == settings,
                'lifecycle preview preimage changed')
        return {**receipt, 'schema': 'gdc-devshard-cache-lifecycle-preview/1',
                'port': adapter.port, 'settings_before_sha256': lifecycle.digest(settings),
                'qualified_storage': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--id', choices=('A', 'B'), required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--expected-compose-sha256', required=True)
    parser.add_argument('--expected-settings-sha256')
    parser.add_argument('--evidence', type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--apply', action='store_true')
    action.add_argument('--preview', action='store_true')
    args = parser.parse_args()
    try:
        adapter = runtime.Native(args.id, args.port)
        if args.preview:
            require(args.evidence is None and args.expected_settings_sha256 is None,
                    'preview does not accept apply inputs')
            receipt = preview_locked(adapter, args.expected_compose_sha256)
        else:
            require(args.evidence is not None and args.expected_settings_sha256 is not None,
                    'apply requires complete approved inputs')
            receipt = apply_locked(adapter, args.evidence, args.expected_compose_sha256,
                                   args.expected_settings_sha256)
        print(json.dumps(receipt, sort_keys=True))
    except (ValueError, OSError, TypeError, KeyError, AttributeError):
        print('Native cache apply refused or inconclusive, retain private journal, no automatic retry',
              file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
