#!/usr/bin/env python3
"""Add versions to existing policy replicas without rewriting other Compose fields."""
import argparse
import json
import os
import re
from pathlib import Path
import stat
import tempfile

OLD = 'chat inference poc/proofs subnet devshard participants'
NEW = OLD + ' versions'


def prepare(path, backup):
    if path.is_symlink() or not path.is_file():
        raise ValueError('regular existing Compose required')
    before = path.read_bytes()
    info = path.stat()
    if before.lstrip().startswith(b'{'):
        document = json.loads(before)
        services = document['services']
        targets = ['proxy-policy', 'proxy-policy2'] if 'proxy-policy' in services else ['proxy']
        for name in targets:
            if services[name]['environment'].get('GONKA_API_EXEMPT_ROUTES') != OLD:
                raise ValueError('unexpected policy preimage')
        needle = json.dumps(OLD).encode()
        if before.count(needle) != len(targets):
            raise ValueError('ambiguous policy occurrences')
        after = before.replace(needle, json.dumps(NEW).encode())
        expected = json.loads(before)
        for name in targets:
            expected['services'][name]['environment']['GONKA_API_EXEMPT_ROUTES'] = NEW
        if json.loads(after) != expected:
            raise ValueError('unrelated configuration change')
    else:
        # Support only the observed anchored layout, not arbitrary YAML.
        # The second replica must inherit everything without overrides.
        text = before.decode()
        primary = re.search(r'^  proxy-policy: &proxy-policy\n((?:[ \t].*\n|\n)*?)(?=^  \S|\Z)', text, re.M)
        secondary = re.search(r'^  proxy-policy2:\n((?:[ \t].*\n|\n)*?)(?=^  \S|\Z)', text, re.M)
        needle = '      GONKA_API_EXEMPT_ROUTES: ' + OLD + '\n'
        if (not primary or not secondary or secondary[1].strip() != '<<: *proxy-policy'
                or text.count(needle) != 1 or needle not in primary[1]
                or text.count('GONKA_API_EXEMPT_ROUTES:') != 1):
            raise ValueError('unsupported YAML policy layout or drift')
        after = text.replace(needle, '      GONKA_API_EXEMPT_ROUTES: ' + NEW + '\n').encode()
        targets = ['proxy-policy', 'proxy-policy2']
    fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(before)
        output.flush()
        os.fsync(output.fileno())
    if path.is_symlink() or path.read_bytes() != before:
        raise ValueError('Compose drift; no replacement')
    fd, temporary = tempfile.mkstemp(prefix='.versions-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            os.fchmod(output.fileno(), stat.S_IMODE(info.st_mode))
            os.fchown(output.fileno(), info.st_uid, info.st_gid)
            output.write(after)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print('Prepared policy only: ' + ' '.join(targets))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compose', type=Path, required=True)
    parser.add_argument('--backup', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.compose, args.backup)
