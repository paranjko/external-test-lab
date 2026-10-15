#!/usr/bin/env python3
"""Add an admitted model to existing provider/virtual keys without rotating values."""
import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
from urllib.parse import quote

spec = importlib.util.spec_from_file_location('provision', Path(__file__).with_name('bifrost-provision.py'))
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)


def extended(models, model):
    if not isinstance(models, list) or not all(isinstance(item, str) for item in models):
        raise ValueError('explicit model list required')
    return models if model in models or '*' in models else models + [model]


def config_payload(config):
    supported = {'id', 'provider', 'weight', 'allowed_models', 'blacklisted_models',
                 'allow_all_keys', 'keys', 'virtual_key_id'}
    if set(config) - supported:
        raise ValueError('unsupported provider policy; preserve it for explicit migration')
    result = {key: copy.deepcopy(value) for key, value in config.items()
              if key not in ('keys', 'virtual_key_id')}
    # Governance embeds DBKey rows: id is an integer database primary key,
    # while key_id is the UUID used by provider-key management and updates.
    result['key_ids'] = [key['key_id'] for key in config.get('keys', [])]
    if not all(isinstance(value, str) and value for value in result['key_ids']):
        raise ValueError('provider key UUID required')
    return result


def migrate(client, model, evidence, apply=False):
    if not isinstance(model, str) or not model or any(char.isspace() for char in model):
        raise ValueError('explicit model required')
    key_path = '/api/providers/gonka-s/keys'
    provider_keys = provision.expect(client, 'GET', key_path).get('keys')
    if not isinstance(provider_keys, list) or len(provider_keys) != 1:
        raise ValueError('one managed provider key required')
    provider_key = provider_keys[0]
    if provider_key.get('enabled') is not True:
        raise ValueError('enabled provider key required')
    virtual = provision.expect(client, 'GET', '/api/governance/virtual-keys?limit=100&offset=0')
    rows = virtual.get('virtual_keys')
    if not isinstance(rows, list) or virtual.get('total_count') != len(rows):
        raise ValueError('complete bounded virtual-key inventory required')
    changes = []
    models = extended(provider_key['models'], model)
    if models != provider_key['models']:
        changes.append((key_path + '/' + quote(provider_key['id'], safe=''),
                        {'models': provider_key['models']}, {'models': models}))
    expected = {}
    for row in rows:
        configs = row.get('provider_configs', [])
        selected = [entry for entry in configs if entry.get('provider') == 'gonka-s']
        if not selected or row.get('is_active') is not True:
            continue
        if len(selected) != 1:
            raise ValueError('ambiguous virtual-key provider binding')
        payloads = [config_payload(config) for config in configs]
        desired = copy.deepcopy(payloads)
        for config in desired:
            if config['provider'] == 'gonka-s':
                if config['key_ids'] != [provider_key['id']] or config.get('allow_all_keys') is not False:
                    raise ValueError('virtual key binding mismatch: key_count=' + str(len(config['key_ids']))
                                     + ', matching=' + str(config['key_ids'] == [provider_key['id']])
                                     + ', allow_all_keys=' + str(config.get('allow_all_keys')))
                config['allowed_models'] = extended(config['allowed_models'], model)
        if desired != payloads:
            changes.append(('/api/governance/virtual-keys/' + quote(row['id'], safe=''),
                            {'provider_configs': payloads}, {'provider_configs': desired}))
        expected[row['id']] = (row, desired)
    evidence.mkdir(mode=0o700, exist_ok=False)
    fd = os.open(evidence / 'changes.json', os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as output:
        # Payloads contain policy and IDs only, never credential values.
        json.dump(changes, output)
        output.flush()
        os.fsync(output.fileno())
    if not apply:
        print('preview model policy changes=' + str(len(changes)))
        return
    if provision.expect(client, 'GET', key_path).get('keys') != provider_keys:
        raise ValueError('provider keys changed before dispatch')
    if provision.expect(client, 'GET', '/api/governance/virtual-keys?limit=100&offset=0') != virtual:
        raise ValueError('virtual-key inventory changed before dispatch')
    for path, _, payload in changes:
        if path.startswith(key_path + '/'):
            # The pinned adapter rejects a models-only key update. Preserve
            # its existing key fields in memory; never persist credential
            # values in the policy-only evidence above.
            payload = copy.deepcopy(provider_key)
            payload.pop('status', None)
            payload['models'] = models
        provision.expect(client, 'PUT', path, payload)
    after_keys = provision.expect(client, 'GET', key_path).get('keys')
    wanted_key = copy.deepcopy(provider_key)
    wanted_key['models'] = models
    if after_keys != [wanted_key]:
        raise ValueError('provider key readback changed unrelated fields')
    after = provision.expect(client, 'GET', '/api/governance/virtual-keys?limit=100&offset=0')
    after_rows = after.get('virtual_keys', [])
    if after.get('total_count') != len(rows) or len(after_rows) != len(rows):
        raise ValueError('virtual key inventory changed')
    by_id = {row['id']: row for row in after_rows}
    for original in rows:
        actual = by_id[original['id']]
        for key, value in original.items():
            if key not in ('updated_at', 'config_hash', 'provider_configs') and actual.get(key) != value:
                raise ValueError('virtual key identity or unrelated policy changed')
        wanted = expected.get(original['id'])
        if wanted and [config_payload(config) for config in actual['provider_configs']] != wanted[1]:
            raise ValueError('virtual-key model policy readback mismatch')
    print('model permissions updated; credential values and unrelated policy preserved')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        client = provision.Client(provision.loopback_url('BIFROST_MANAGEMENT_URL'),
            provision.required('BIFROST_ADMIN_USERNAME'), provision.required('BIFROST_ADMIN_PASSWORD'))
        migrate(client, args.model, args.evidence, args.apply)
    except (ValueError, KeyError, OSError, provision.ProvisionError) as error:
        # ProvisionError contains method/path/status, never the response body or
        # credentials. Retain that diagnostic to distinguish rejected APIs.
        reason = str(error) if isinstance(error, (ValueError, provision.ProvisionError)) else type(error).__name__
        raise SystemExit('model permission migration refused or uncertain: ' + reason + '; no retry')
