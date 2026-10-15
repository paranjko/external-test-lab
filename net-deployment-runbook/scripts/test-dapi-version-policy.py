#!/usr/bin/env python3
"""Exercise the stand's pinned policy renderer without network or host ports."""
import json
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prepare', root / 'scripts/prepare-dapi-version-policy.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
with tempfile.TemporaryDirectory() as directory:
    for layout in ('flat', 'legacy/gdc-node1'):
        for names in (['proxy'], ['proxy-policy', 'proxy-policy2']):
            destination = Path(directory) / layout / names[0]
            destination.mkdir(parents=True)
            path = destination / 'compose.yaml'
            original = {'services': {name: {'environment': {'GONKA_API_EXEMPT_ROUTES': prepare.OLD,
                                                          'UNRELATED': 'retained'}} for name in names}}
            path.write_text(json.dumps(original, indent=2))
            path.chmod(0o640)
            before = path.read_bytes()
            backup = destination / 'before.json'
            prepare.prepare(path, backup)
            assert backup.read_bytes() == before
            assert backup.stat().st_mode & 0o777 == 0o600
            assert path.stat().st_mode & 0o777 == 0o640
            expected = json.loads(before)
            for name in names:
                expected['services'][name]['environment']['GONKA_API_EXEMPT_ROUTES'] = prepare.NEW
            assert json.loads(path.read_bytes()) == expected
            try:
                prepare.prepare(path, destination / 'retry.json')
                raise AssertionError('unexpected retry accepted')
            except ValueError:
                assert not (destination / 'retry.json').exists()
print('PASS flat/legacy single/replicated preparation, preimages and drift refusal')
with tempfile.TemporaryDirectory() as directory:
    for layout in ('flat', 'legacy/gdc-node4'):
        destination = Path(directory) / layout
        destination.mkdir(parents=True)
        path = destination / 'compose.yaml'
        text = ('services:\n  proxy-policy: &proxy-policy\n    image: nginx:alpine\n'
                '    environment:\n      GONKA_API_EXEMPT_ROUTES: ' + prepare.OLD + '\n'
                '      UNRELATED: keep\n\n  proxy-policy2:\n    <<: *proxy-policy\n')
        path.write_text(text)
        prepare.prepare(path, destination / 'before.yaml')
        result = subprocess.run(['docker', 'compose', '-f', str(path), 'config', '--format', 'json'],
                                capture_output=True, text=True, check=True)
        services = json.loads(result.stdout)['services']
        for name in ('proxy-policy', 'proxy-policy2'):
            assert services[name]['environment'] == {'GONKA_API_EXEMPT_ROUTES': prepare.NEW, 'UNRELATED': 'keep'}
        assert (destination / 'before.yaml').read_text() == text
        path.write_text(text + '    environment:\n      UNRELATED: override\n')
        try:
            prepare.prepare(path, destination / 'invalid.yaml')
            raise AssertionError('replica override accepted')
        except ValueError:
            assert not (destination / 'invalid.yaml').exists()
print('PASS anchored YAML layouts: real Compose replica inheritance and override refusal')
document = json.loads((root.parent / 'bootstrap/gonka-devnet-community.json').read_text())
image = document['software']['components']['proxy-policy']['image']
assert '@sha256:' in image, 'immutable policy image required'
source = (root / '02-node/compose.yaml').read_text()
routes = re.findall(r'^\s+GONKA_API_EXEMPT_ROUTES: (.+)$', source, re.M)
assert len(routes) == 1
assert 'versions' in routes[0].split()

for enabled in (False, True):
    selected = routes[0] if enabled else ' '.join(x for x in routes[0].split() if x != 'versions')
    command = ['docker', 'run', '--rm', '--network', 'none']
    for value in ('NGINX_MODE=http', 'SERVER_NAME=fixture.invalid',
                  'API_SERVICE_NAME=127.0.0.1', 'NODE_SERVICE_NAME=127.0.0.1',
                  'DISABLE_VALIDATOR_WHITELIST=true', 'DISABLE_FAIL2BAN=true',
                  'DISABLE_GONKA_API=false', 'GONKA_API_EXEMPT_ROUTES=' + selected):
        command.extend(['-e', value])
    result = subprocess.run(command + [image, 'nginx', '-T'], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    config = result.stdout
    assert 'zone=api_zone:10m rate=10r/m;' in config
    assert 'zone=exempt_zone:10m rate=500r/s;' in config
    for prefix in ('/v1/', '/api/v1/', '/v2/', '/api/v2/'):
        match = re.search(r'location ' + re.escape(prefix + 'versions') + r' \{([^}]+)\}', config)
        assert bool(match) == enabled, prefix
        if match:
            assert 'limit_req zone=exempt_zone' in match[1]
            assert 'limit_conn conn_exempt' in match[1]
            assert 'proxy_pass http://api_backend/' in match[1]
    print('PASS pinned versions policy ' + ('bounded control-plane route' if enabled else 'baseline omission'))
