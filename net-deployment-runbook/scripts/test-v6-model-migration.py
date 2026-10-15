import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('migration', Path(__file__).resolve().parents[1] / '04-ops/migrate-bifrost-model.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)
binding_spec = importlib.util.spec_from_file_location('binding', Path(__file__).with_name('update-v6-broker-model.py'))
binding = importlib.util.module_from_spec(binding_spec)
binding_spec.loader.exec_module(binding)


class MigrationTest(unittest.TestCase):
    def test_future_binding_preserves_files_and_private_preimages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = [root / 'srv/dai/ops/bifrost.env', root / 'srv/dai/ops/bifrost/broker-binding.env']
            before = b'OTHER=keep\nBIFROST_GONKA_MODEL=old\nSECRET=fixture\n'
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(before)
                path.chmod(0o640)
            evidence = root / 'proof'
            binding.update(root, 'old', 'new', evidence)
            for path in paths:
                self.assertEqual(path.read_bytes(), before.replace(b'MODEL=old', b'MODEL=new'))
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)
                self.assertEqual((evidence / path.name).read_bytes(), before)
                self.assertEqual((evidence / path.name).stat().st_mode & 0o777, 0o600)
            self.assertEqual(evidence.stat().st_mode & 0o777, 0o700)

    def test_future_binding_drift_refuses_both_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / 'srv/dai/ops/bifrost.env'
            second = root / 'srv/dai/ops/bifrost/broker-binding.env'
            second.parent.mkdir(parents=True)
            first.write_text('BIFROST_GONKA_MODEL=old\n')
            second.write_text('BIFROST_GONKA_MODEL=other\n')
            with self.assertRaisesRegex(ValueError, 'drift'):
                binding.update(root, 'old', 'new', root / 'proof')
            self.assertEqual(first.read_text(), 'BIFROST_GONKA_MODEL=old\n')
            self.assertFalse((root / 'proof').exists())

    def test_additive_and_wildcard_models(self):
        self.assertEqual(migration.extended(['old'], 'new'), ['old', 'new'])
        self.assertEqual(migration.extended(['*'], 'new'), ['*'])
        self.assertEqual(migration.extended(['old', 'new'], 'new'), ['old', 'new'])

    def test_provider_policy_preserved_or_refused(self):
        config = {'id': 1, 'provider': 'gonka-s', 'weight': 1, 'allowed_models': ['old'],
                  'blacklisted_models': ['denied'], 'allow_all_keys': False,
                  'keys': [{'id': 7, 'key_id': 'key-id', 'value': 'private'}], 'virtual_key_id': 'vk'}
        payload = migration.config_payload(config)
        self.assertEqual(payload['key_ids'], ['key-id'])
        self.assertEqual(payload['blacklisted_models'], ['denied'])
        self.assertNotIn('private', str(payload))
        with self.assertRaises(ValueError):
            migration.config_payload(dict(config, budget={'max_limit': 2}))

    def test_incomplete_inventory_refuses_before_mutation(self):
        class Client:
            def request(self, method, path, payload=None, authenticated=True):
                if method != 'GET':
                    raise AssertionError('unexpected mutation')
                if path == '/api/providers/gonka-s/keys':
                    return 200, {'keys': [{'id': 'key', 'enabled': True, 'models': ['old']}]}
                return 200, {'total_count': 2, 'virtual_keys': []}
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / 'proof'
            with self.assertRaisesRegex(ValueError, 'complete bounded'):
                migration.migrate(Client(), 'new', evidence, True)
            self.assertFalse(evidence.exists())


if __name__ == '__main__':
    unittest.main()
