import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('rebind', Path(__file__).resolve().parents[1] / '04-ops/rebind-bifrost-provider.py')
rebind = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rebind)


class Client:
    def __init__(self):
        self.provider = {'name': 'gonka-s', 'network_config': {'base_url': 'http://127.0.0.1:18100',
                         'max_retries': 0, 'allow_private_network': True},
                         'custom_provider_config': {'base_provider_type': 'openai'},
                         'concurrency_and_buffer_size': {'concurrency': 8}, 'proxy_config': None}
        self.puts = []

    def request(self, method, path, payload=None, authenticated=True):
        if method == 'GET' and path == '/api/providers':
            return 200, {'providers': [copy.deepcopy(self.provider)]}
        if method == 'GET' and path == '/api/providers/gonka-s/keys':
            return 200, {'keys': [{'id': 'fixture-key', 'value': 'REDACTED'}]}
        if method == 'PUT' and path == '/api/providers/gonka-s':
            self.puts.append(copy.deepcopy(payload))
            self.provider.update(payload)
            return 200, {}
        raise AssertionError('unexpected API mutation')


class RebindTest(unittest.TestCase):
    def test_preserves_key_and_unrelated_configuration(self):
        client = Client()
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'evidence'
            rebind.rebind(client, 'http://127.0.0.1:18100', 'http://127.0.0.1:18083', evidence)
            self.assertEqual(len(client.puts), 1)
            self.assertEqual(client.provider['network_config']['max_retries'], 0)
            self.assertEqual(client.provider['concurrency_and_buffer_size'], {'concurrency': 8})
            for path in evidence.iterdir():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                rebind.rebind(client, 'http://127.0.0.1:18100', 'http://127.0.0.1:18083', Path(directory) / 'again')
            self.assertEqual(len(client.puts), 1)

    def test_retry_drift_refuses_before_write(self):
        for retries in (1, None, False, '0'):
            client = Client()
            client.provider['network_config']['max_retries'] = retries
            with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
                rebind.rebind(client, 'http://127.0.0.1:18100', 'http://127.0.0.1:18083', Path(directory) / 'evidence')
            self.assertEqual(client.puts, [])


if __name__ == '__main__':
    unittest.main()
