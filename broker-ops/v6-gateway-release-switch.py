#!/usr/bin/env python3
"""Exclusive A/B gateway image switch. Dry-run unless --apply is supplied."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import time
import urllib.request


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def wait_for(predicate, timeout=120):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise TimeoutError('phase deadline exceeded; inspect private preimage')
        time.sleep(5)


def ledger(campaign, instance):
    with sqlite3.connect((campaign / 'ledger.sqlite').as_uri() + '?mode=ro', uri=True) as db:
        require(db.execute('SELECT * FROM binding').fetchall() == [(instance, 5000)],
                'unexpected budget binding')
        return list(db.iterdump())


def switch(root, campaign, instance, old, new, api, backup=None, run=command):
    """Only the independent single-volume A/B layout is supported."""
    pattern = r'ghcr\.io/paranjko/external-test-lab/devshard-gateway@sha256:[0-9a-f]{64}'
    require(instance in ('a', 'b'), 'invalid instance')
    require(re.fullmatch(pattern, old) and re.fullmatch(pattern, new) and old != new,
            'distinct immutable gateway digests required')
    require(campaign.parent == root and campaign.is_dir(), 'campaign must belong to instance')
    container = 'gdc-v6-' + instance + '-gateway-1'
    unit = 'gdc-v6-budget-' + instance
    compose = root / 'compose.yaml'
    original = compose.read_text()
    require(original.count(old) == 1 and new not in original, 'stale compose image')
    image = json.loads(run('docker', 'image', 'inspect', new))[0]
    require(image['Architecture'] == 'amd64' and image['Os'] == 'linux'
            and new in image['RepoDigests'], 'target image identity/platform mismatch')
    before = json.loads(run('docker', 'inspect', container))[0]
    require(before['State']['Running'] and before['Config']['Image'] == old,
            'stale or stopped gateway')
    mounts = before['Mounts']
    require(len(mounts) == 1 and mounts[0]['Type'] == 'volume'
            and mounts[0]['Name'] == 'gdc-v6-' + instance + '-data'
            and mounts[0]['Destination'] == '/root/.devshardctl', 'unsupported storage layout')
    require(run('docker', 'ps', '--filter', 'volume=' + mounts[0]['Name'],
                '--format', '{{.Names}}').splitlines() == [container], 'other volume writer')
    settings = api('/v1/admin/settings')
    require(settings['escrow_rotation']['enabled'] is False, 'native rotation must be disabled')
    timer = run('systemctl', 'show', unit + '.timer', '--property=ActiveState', '--value')
    require(timer in ('active', 'inactive'), 'unknown timer state')
    ledger(campaign, instance)
    if backup is None:
        return {'applied': False, 'instance': instance, 'old': old, 'new': new}
    require(backup.parent == root and not backup.exists(), 'new instance-local backup required')
    backup.mkdir(mode=0o700)
    shutil.copy2(compose, backup / 'compose.yaml')
    shutil.copy2(root / 'operator.env', backup / 'operator.env')
    def save(name, value):
        with (backup / name).open('x') as stream:
            json.dump(value, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
    save('settings.json', settings)
    save('container.json', before)
    save('timer.json', timer)
    # Failures from this point intentionally retain paused rotation for inspection.
    run('systemctl', 'stop', unit + '.timer')
    wait_for(lambda: run('systemctl', 'show', unit + '.service', '--property=ActiveState',
                         '--value') in ('inactive', 'failed'))
    with (campaign / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require(compose.read_text() == original, 'concurrent compose update')
        require(api('/v1/admin/settings') == settings, 'concurrent settings update')
        ledger_before = ledger(campaign, instance)
        shutil.copytree(campaign, backup / 'campaign')
        state = api('/v1/admin/state')
        active = [str(row['id']) for row in state['devshards'] if row['active']]
        save('state.json', state)
        save('active.json', active)
        for identity in active:
            require(identity.isdecimal(), 'invalid escrow identity')
            require(api('/v1/admin/devshards/' + identity + '/deactivate', True)['active'] is False,
                    'deactivation failed')
        def drained():
            state = api('/v1/admin/state')
            return state['limiter']['in_flight_requests'] == 0 and all(
                not row['active'] for row in state['devshards'])
        wait_for(drained)
        run('docker', 'stop', '--time', '120', container)
        stopped = json.loads(run('docker', 'inspect', container))[0]
        require(stopped['State']['Running'] is False, 'writer still running')
        shutil.copytree(Path(mounts[0]['Source']), backup / 'gateway-state')
        require(ledger(campaign, instance) == ledger_before, 'ledger changed')
        require(compose.read_text() == original, 'concurrent compose update')
        temporary = compose.with_name('compose.release-switch.tmp')
        with temporary.open('x') as stream:
            stream.write(original.replace(old, new))
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, compose.stat().st_mode & 0o777)
        os.replace(temporary, compose)
        run('docker', 'compose', '--env-file', str(root / 'operator.env'), '-f', str(compose),
            'up', '-d', '--no-deps', 'gateway')
        def ready():
            try:
                api('/v1/admin/state')
                return True
            except (OSError, ValueError):
                return False
        wait_for(ready)
        current = json.loads(run('docker', 'inspect', container))[0]
        require(current['State']['Running'] and current['Config']['Image'] == new
                and current['Image'] == image['Id'], 'new runtime image mismatch')
        require(current['Mounts'] == mounts, 'storage changed')
        require(api('/v1/admin/settings') == settings, 'settings changed')
        for identity in active:
            require(api('/v1/admin/devshards/' + identity + '/activate', True)['active'] is True,
                    'activation failed')
        require(ledger(campaign, instance) == ledger_before, 'ledger changed')
        receipt = {'applied': True, 'instance': instance, 'old': old, 'new': new,
                   'ledger_unchanged': True, 'settings_unchanged': True, 'volume_preserved': True,
                   'active_restored': active, 'timer_before': timer, 'backup': str(backup)}
        save('switched.json', receipt)
    if timer == 'active':
        run('systemctl', 'start', unit + '.timer')
    receipt['timer_after'] = run('systemctl', 'show', unit + '.timer',
                                '--property=ActiveState', '--value')
    require(receipt['timer_after'] == timer, 'timer restoration failed')
    save('receipt.json', receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('instance', choices=['a', 'b'])
    parser.add_argument('--expected-image', required=True)
    parser.add_argument('--target-image', required=True)
    parser.add_argument('--campaign', required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--backup', type=Path)
    args = parser.parse_args()
    require(args.apply == (args.backup is not None), '--apply requires --backup')
    require(re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]*', args.campaign), 'invalid campaign')
    os.umask(0o077)
    root = Path('/srv/dai/broker-tests/v6-' + args.instance)
    envfile = Path('/srv/dai/broker-tests/ds502-' + args.instance + '/gateway.env')
    env = dict(line.split('=', 1) for line in envfile.read_text().splitlines()
               if line and not line.startswith('#'))
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **kw):
            raise ValueError('redirect forbidden')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    port = '18187' if args.instance == 'a' else '18188'
    def api(route, post=False):
        req = urllib.request.Request('http://127.0.0.1:' + port + route,
            data=b'{}' if post else None, headers={
                'Authorization': 'Bearer ' + env['DEVSHARD_ADMIN_API_KEY'],
                'Content-Type': 'application/json'})
        with opener.open(req, timeout=30) as response:
            return json.load(response)
    print(json.dumps(switch(root, root / args.campaign, args.instance,
                            args.expected_image, args.target_image, api, args.backup)))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'result': 'FAIL', 'error_type': type(error).__name__,
                          'action': 'inspect private preimage; do not blindly retry'}))
        raise SystemExit(1)
