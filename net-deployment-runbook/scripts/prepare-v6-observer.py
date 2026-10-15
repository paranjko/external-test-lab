#!/usr/bin/env python3
"""Prepare private observer binding and rollback preimage; never restart services."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import stat


def read_private(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        mode = os.fstat(stream.fileno()).st_mode
        if not stat.S_ISREG(mode) or mode & 0o077:
            raise ValueError('private regular file required')
        return stream.read()


def parse(text):
    result = {}
    for line in text.splitlines():
        if not line or line.startswith('#'):
            continue
        key, value = line.split('=', 1)
        if key in result:
            raise ValueError('duplicate environment field')
        result[key] = value
    return result


def binding(observer, gateway, port):
    values, credentials = parse(observer), parse(gateway)
    if port not in (18187, 18188):
        raise ValueError('expected native A/B gateway port')
    key = credentials['DEVSHARD_ADMIN_API_KEY']
    token = values['GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN']
    if key == token or not all(re.fullmatch(r'[A-Za-z0-9._:-]{16,256}', item) for item in (key, token)):
        raise ValueError('distinct valid admin and observer credentials required')
    values['DEVSHARD_ADMIN_API_KEY'] = key
    values['GDC_GATEWAY_ADMIN_STATE_URL'] = f'http://127.0.0.1:{port}/v1/admin/devshards'
    return ''.join(f'{key}={value}\n' for key, value in values.items()), token


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--observer-env', required=True, type=Path)
    parser.add_argument('--gateway-env', required=True, type=Path)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    before = read_private(args.observer_env)
    after, token = binding(before, read_private(args.gateway_env), args.port)
    args.output_dir.mkdir(mode=0o700, exist_ok=False)
    for name, body in [('observer-before.env', before), ('observer-after.env', after),
                       ('observer-token', token)]:
        fd = os.open(args.output_dir / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(body)
            output.flush()
            os.fsync(output.fileno())
    print('observer_before_sha256=' + hashlib.sha256(before.encode()).hexdigest())
    print('observer_after_sha256=' + hashlib.sha256(after.encode()).hexdigest())


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError):
        raise SystemExit('observer preparation refused; inspect private inputs locally')
