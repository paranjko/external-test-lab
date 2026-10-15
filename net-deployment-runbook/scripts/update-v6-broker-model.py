#!/usr/bin/env python3
"""Update future broker issuance model in existing files, retaining private preimages."""
import argparse
import os
from pathlib import Path
import re
import stat
import tempfile


def update(root, expected, model, evidence):
    if not all(re.fullmatch(r'[A-Za-z0-9_.\-/]+', value) for value in (expected, model)):
        raise ValueError('invalid model identifier')
    targets = [root / 'srv/dai/ops/bifrost.env', root / 'srv/dai/ops/bifrost/broker-binding.env']
    prepared = []
    for path in targets:
        if path.is_symlink() or not path.is_file():
            raise ValueError('existing regular binding required')
        before = path.read_bytes()
        lines = before.decode().splitlines(keepends=True)
        matches = [index for index, line in enumerate(lines) if line.startswith('BIFROST_GONKA_MODEL=')]
        if len(matches) != 1 or lines[matches[0]].strip() != 'BIFROST_GONKA_MODEL=' + expected:
            raise ValueError('model binding drift')
        lines[matches[0]] = 'BIFROST_GONKA_MODEL=' + model + '\n'
        prepared.append((path, before, ''.join(lines).encode(), path.stat()))
    evidence.mkdir(mode=0o700, exist_ok=False)
    for path, before, _, _ in prepared:
        fd = os.open(evidence / path.name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'wb') as output:
            output.write(before)
            output.flush()
            os.fsync(output.fileno())
    for path, before, after, info in prepared:
        if path.is_symlink() or path.read_bytes() != before:
            raise ValueError('binding drift before replacement; inspect preimages')
        fd, temporary = tempfile.mkstemp(prefix='.model-', dir=path.parent)
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
    print('future broker model binding updated; recreate only bifrost-broker to reload')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-model', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    try:
        update(Path('/'), args.expected_model, args.model, args.evidence)
    except (ValueError, OSError):
        raise SystemExit('model binding update refused or partial; inspect private preimages; no automatic retry')
