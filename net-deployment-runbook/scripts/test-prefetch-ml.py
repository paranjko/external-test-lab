#!/usr/bin/env python3
"""Execute the downloader with a Docker transport double and a local Hub stub."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
REVISION = 'a' * 40


class PrefetchTest(unittest.TestCase):
    def run_prefetch(self, token=None, fail=False, deployed=False):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            docker = path / 'docker'
            docker.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
a = sys.argv[1:]
if a[0] == 'ps':
    if os.environ.get('DEPLOYED_CACHE'):
        print('fixture-container')
    sys.exit(0)
if a[0] == 'inspect':
    print(json.dumps([{'Mounts':[{'Type':'bind','Destination':'/root/.cache','Source':os.environ['DEPLOYED_CACHE']}]}]))
    sys.exit(0)
if a[:2] == ['image', 'inspect']:
    sys.exit(0)
assert a[0] == 'run', a
assert '--gpus' not in a
if os.environ.get('DEPLOYED_CACHE'):
    assert a[a.index('--volume')+1] == os.environ['DEPLOYED_CACHE'] + ':/root/.cache'
env = os.environ.copy()
for i, arg in enumerate(a):
    if arg == '--env':
        key, value = a[i+1].split('=', 1)
        env[key] = value
start = a.index('--entrypoint') + 3
sys.exit(subprocess.run([sys.executable] + a[start:], env=env,
    stdin=None if '-i' in a else subprocess.DEVNULL).returncode)
''')
            docker.chmod(0o755)
            (path / 'huggingface_hub.py').write_text('''import os
def snapshot_download(repo_id, revision):
    assert repo_id == 'Qwen/fixture'
    assert revision == 'a' * 40
    assert os.environ.get('HF_TOKEN') == os.environ.get('EXPECTED_TOKEN')
    if os.environ.get('FAIL_DOWNLOAD') == '1':
        raise RuntimeError('fixture download failure')
    return '/root/.cache/hub/models--Qwen--fixture/snapshots/' + revision
''')
            env = dict(os.environ, PATH=str(path) + os.pathsep + os.environ['PATH'],
                       PYTHONPATH=str(path), FAIL_DOWNLOAD='1' if fail else '0')
            env.pop('HF_TOKEN', None)
            env.pop('EXPECTED_TOKEN', None)
            if deployed:
                (path / 'existing-cache').mkdir()
                env['DEPLOYED_CACHE'] = str(path / 'existing-cache')
            args = ['bash', str(ROOT / 'prefetch-ml-remote.sh'), str(path / 'cache'),
                    'fixture-image', 'Qwen/fixture', REVISION]
            if token is not None:
                args.append(token)
                env['EXPECTED_TOKEN'] = token
            return subprocess.run(args, env=env, text=True, capture_output=True)

    def test_public_snapshot(self):
        result = self.run_prefetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt['revision'], REVISION)
        self.assertEqual(receipt['model'], 'Qwen/fixture')
        self.assertTrue(receipt['snapshot'].endswith(REVISION))

    def test_authenticated_snapshot(self):
        result = self.run_prefetch('hf_fixture')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['revision'], REVISION)
        self.assertNotIn('hf_fixture', result.stdout)

    def test_download_failure_propagates(self):
        result = self.run_prefetch(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_reuses_deployed_cache_instead_of_default(self):
        result = self.run_prefetch(deployed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['revision'], REVISION)


if __name__ == '__main__':
    unittest.main()
