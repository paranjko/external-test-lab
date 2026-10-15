#!/usr/bin/env python3
"""Rebind only the existing gonka-s provider, retaining keys and a private preimage."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location('provision', Path(__file__).with_name('bifrost-provision.py'))
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)


def rebind(client, expected, upstream, evidence):
    allowed = {'http://127.0.0.1:18100', 'http://127.0.0.1:18083'}
    if expected not in allowed or upstream not in allowed or expected == upstream:
        raise ValueError('explicit route/admission cutover required')
    def current():
        value = provision.find_provider(provision.expect(client, 'GET', '/api/providers'), 'gonka-s')
        if not isinstance(value, dict) or not provision.retries_disabled(value.get('network_config', {}).get('max_retries')):
            raise ValueError('existing provider with integer retries0 required')
        return value
    before = current()
    if before['network_config'].get('base_url') != expected:
        raise ValueError('provider binding drift')
    keys = provision.expect(client, 'GET', '/api/providers/gonka-s/keys')
    fields = ('network_config', 'concurrency_and_buffer_size', 'custom_provider_config', 'proxy_config')
    old = {name: before[name] for name in fields if name in before}
    desired = copy.deepcopy(old)
    desired['network_config']['base_url'] = upstream
    evidence.mkdir(mode=0o700, exist_ok=False)
    for name, value in [('provider-before.json', old), ('provider-after.json', desired)]:
        fd = os.open(evidence / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
    if current() != before:
        raise ValueError('provider changed before dispatch')
    provision.expect(client, 'PUT', '/api/providers/gonka-s', desired)
    actual = current()
    if any(actual.get(name) != value for name, value in desired.items()):
        raise ValueError('provider readback mismatch; inspect private preimage before recovery')
    if provision.expect(client, 'GET', '/api/providers/gonka-s/keys') != keys:
        raise ValueError('provider key metadata changed; stop and inspect')
    print('provider rebound; retries0 and key metadata preserved')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-base-url', required=True)
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    client = provision.Client(provision.loopback_url('BIFROST_MANAGEMENT_URL'),
                              provision.required('BIFROST_ADMIN_USERNAME'),
                              provision.required('BIFROST_ADMIN_PASSWORD'))
    rebind(client, args.expected_base_url, args.upstream, args.evidence)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, provision.ProvisionError):
        raise SystemExit('provider cutover refused or uncertain; inspect retained private preimage; no automatic retry')
