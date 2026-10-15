#!/usr/bin/env python3
"""Field-scoped, reversible v6 gateway timeout experiment; read-only by default."""
import argparse
import copy
import json
import os
from pathlib import Path
import urllib.request


FIELD = 'first_token_timeout_floor_ms'


def change(api, expected, target, backup=None):
    if type(target) is not int or not 1000 <= target <= 30000:
        raise ValueError('target must be 1000..30000 ms')
    before = api(None)
    old = before['redundancy'][FIELD]
    if old != expected:
        raise ValueError('current value differs from expected value')
    if backup is None:
        return {'applied': False, 'before_ms': old, 'proposed_ms': target}
    # Persist a private receipt before changing anything. Never overwrite one.
    with open(backup, 'x', opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        json.dump({'before': before, 'target_ms': target}, stream)
        stream.flush()
        os.fsync(stream.fileno())
    api({'redundancy': {FIELD: target}})
    after = api(None)
    wanted = copy.deepcopy(before)
    wanted['redundancy'][FIELD] = target
    if after != wanted:
        raise ValueError('readback mismatch; inspect receipt, do not overwrite concurrent changes')
    return {'applied': True, 'before_ms': old, 'after_ms': target,
            'other_settings_unchanged': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('instance', choices=['a', 'b'])
    parser.add_argument('--expected-ms', required=True, type=int)
    parser.add_argument('--target-ms', type=int, default=20000)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    if args.apply != (args.receipt is not None):
        parser.error('--apply requires a new --receipt path; omit both for read-only')
    env = dict(line.split('=', 1) for line in Path(
        '/srv/dai/broker-tests/ds502-' + args.instance + '/gateway.env').read_text().splitlines()
        if line and not line.startswith('#'))
    url = 'http://127.0.0.1:' + ('18187' if args.instance == 'a' else '18188') + '/v1/admin/settings'
    # Loopback only, no redirects or inherited proxy configuration.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **kw):
            raise ValueError('redirect forbidden')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    def api(payload):
        req = urllib.request.Request(url, data=None if payload is None else json.dumps(payload).encode(),
            headers={'Authorization': 'Bearer ' + env['DEVSHARD_ADMIN_API_KEY'],
                     'Content-Type': 'application/json'})
        with opener.open(req, timeout=15) as response:
            return json.load(response)
    print(json.dumps(change(api, args.expected_ms, args.target_ms, args.receipt)))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # HTTP bodies and transport exceptions may contain sensitive information.
        print(json.dumps({'result': 'FAIL', 'error_type': type(error).__name__}))
        raise SystemExit(1)
