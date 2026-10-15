#!/usr/bin/env python3
"""Update an existing budget campaign without resetting its ledger or starting it."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile


def install(root, instance, amount, model, run=subprocess.run, *,
            settle_after_replacement=False, expected_dropin_sha256=None):
    if instance not in ('a', 'b') or type(amount) is not int or amount <= 0:
        raise ValueError('invalid campaign or amount')
    if not re.fullmatch(r'[A-Za-z0-9_.\-/]+', model):
        raise ValueError('invalid model identifier')
    if expected_dropin_sha256 is not None and not re.fullmatch(r'[0-9a-f]{64}', expected_dropin_sha256):
        raise ValueError('invalid expected drop-in SHA256')
    campaign = root / 'srv/dai/broker-tests' / ('v6-' + instance)
    ledger = campaign / 'rotation-10000gnk-20261013/ledger.sqlite'
    with sqlite3.connect(ledger.as_uri() + '?mode=ro', uri=True) as db:
        if db.execute('SELECT * FROM binding').fetchall() != [(instance, 5000)]:
            raise ValueError('existing campaign binding required')
    name = 'gdc-v6-budget-' + instance
    units = root / 'etc/systemd/system'
    for suffix in ('.service', '.timer'):
        if not (units / (name + suffix)).is_file():
            raise ValueError('existing campaign units required')
    # Never interrupt an in-flight transaction. Stop only the scheduler.
    run(['systemctl', 'disable', '--now', name + '.timer'], check=True)
    state = run(['systemctl', 'show', name + '.service', '--property=ActiveState', '--value'],
                check=True, capture_output=True, text=True).stdout.strip()
    if state not in ('inactive', 'failed'):
        raise ValueError('campaign service is still active; retry after it finishes')
    source = Path(__file__).with_name('v6-budget-rotation.py').read_bytes()
    # Content-addressed installation avoids replacing a script used by an
    # already-loaded unit; old source and ledger remain recoverable.
    digest = hashlib.sha256(source).hexdigest()
    destination = campaign / ('budget-' + digest + '.py')
    if destination.exists():
        if destination.is_symlink() or destination.read_bytes() != source:
            raise ValueError('source destination conflict')
    else:
        with destination.open('xb') as stream:
            os.chmod(destination, 0o700)
            stream.write(source)
            stream.flush()
            os.fsync(stream.fileno())
    dropin = units / (name + '.service.d')
    if dropin.is_symlink():
        raise ValueError('drop-in directory must not be a symlink')
    dropin.mkdir(exist_ok=True)
    target = dropin / '90-explicit-model.conf'
    body = ('[Service]\nExecStart=\nExecStart=/usr/bin/python3 ' +
            '/' + str(destination.relative_to(root)) + ' ' + instance +
            ' --amount ' + str(amount) + ' --model ' + model +
            (' --settle-after-replacement' if settle_after_replacement else '') + '\n')
    replace = not target.exists()
    if target.is_symlink():
        raise ValueError('drop-in must not be a symlink')
    if target.exists():
        previous = target.read_bytes()
        if previous != body.encode():
            old_digest = hashlib.sha256(previous).hexdigest()
            if old_digest != expected_dropin_sha256:
                raise ValueError('existing drop-in differs; review it before replacement')
            # A non-.conf preimage is ignored by systemd and kept for rollback.
            backup = dropin / ('90-explicit-model.conf.preimage-' + old_digest)
            if backup.is_symlink():
                raise ValueError('drop-in preimage conflict')
            if backup.exists():
                if backup.read_bytes() != previous:
                    raise ValueError('drop-in preimage conflict')
            else:
                with backup.open('xb') as stream:
                    os.fchmod(stream.fileno(), 0o600)
                    stream.write(previous)
                    stream.flush()
                    os.fsync(stream.fileno())
            if target.is_symlink() or target.read_bytes() != previous:
                raise ValueError('drop-in changed during replacement')
            replace = True
    elif expected_dropin_sha256 is not None:
        raise ValueError('expected drop-in is missing')
    if replace:
        fd, temporary = tempfile.mkstemp(prefix='.budget-', dir=dropin)
        try:
            with os.fdopen(fd, 'w') as stream:
                os.fchmod(stream.fileno(), 0o644)
                stream.write(body)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    run(['systemctl', 'daemon-reload'], check=True)
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('instance', choices=['a', 'b'])
    parser.add_argument('--amount', required=True, type=int)
    parser.add_argument('--model', required=True)
    parser.add_argument('--settle-after-replacement', action='store_true')
    parser.add_argument('--expected-dropin-sha256', help='Reviewed current drop-in digest; preserve a preimage before replacement')
    args = parser.parse_args()
    os.umask(0o077)
    digest = install(Path('/'), args.instance, args.amount, args.model,
                     settle_after_replacement=args.settle_after_replacement,
                     expected_dropin_sha256=args.expected_dropin_sha256)
    print('installed sha256=' + digest + '; timer disabled; verify before explicit enable')


if __name__ == '__main__':
    main()
