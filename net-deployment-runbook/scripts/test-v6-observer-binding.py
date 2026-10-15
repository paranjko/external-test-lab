import importlib.util
from pathlib import Path
import unittest
import tempfile

spec = importlib.util.spec_from_file_location('binding', Path(__file__).with_name('prepare-v6-observer.py'))
binding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binding)


class BindingTest(unittest.TestCase):
    def test_activation_scope_and_rollback(self):
        spec = importlib.util.spec_from_file_location('activation', Path(__file__).with_name('activate-v6-admission.py'))
        activation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(activation)
        for fail in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                edge, ops, prepared = root / 'srv/dai/edge', root / 'srv/dai/ops', root / 'prepared'
                for path in (edge, ops, prepared):
                    path.mkdir(parents=True)
                observer = ops / 'gateway-admission-observer.env'
                observer.write_text('old-observer')
                observer.chmod(0o600)
                for name in ('compose.yaml', 'gateway-admission.env', 'gateway-admission-proxy.py'):
                    (edge / name).write_text('old-' + name)
                for name, value in [('observer-before.env', 'old-observer'), ('observer-after.env', 'new-observer'), ('admission-after.env', 'new-admission')]:
                    (prepared / name).write_text(value)
                calls = []
                def run(argv, **kwargs):
                    calls.append(argv)
                    if argv[0] == 'bash':
                        (edge / 'gateway-admission.env').write_text('new-admission')
                    if fail and len(calls) == 3:
                        raise RuntimeError('fixture recreation failure')
                expected = activation.digest(edge / 'compose.yaml')
                if fail:
                    with self.assertRaises(RuntimeError):
                        activation.activate(root, prepared, expected, run)
                    self.assertEqual(observer.read_text(), 'old-observer')
                    self.assertEqual((edge / 'gateway-admission.env').read_text(), 'old-gateway-admission.env')
                else:
                    activation.activate(root, prepared, expected, run)
                    self.assertEqual(observer.read_text(), 'new-observer')
                self.assertEqual(activation.digest(edge / 'compose.yaml'), expected)
                self.assertTrue(all(call[-1] == 'gateway-admission' for call in calls if call[0] == 'docker'))

    def test_only_native_binding_changes(self):
        observer = ('DEVSHARD_ADMIN_API_KEY=old-admin-key-000000\n'
                    'GDC_GATEWAY_ADMISSION_OBSERVER_TOKEN=observer-token-000000\n'
                    'GDC_GATEWAY_ADMIN_STATE_URL=http://127.0.0.1:18200/v1/admin/state\n'
                    'EXTRA=preserve\n')
        for port in (18187, 18188):
            after, token = binding.binding(observer, 'DEVSHARD_ADMIN_API_KEY=new-admin-key-000000\n', port)
            expected = binding.parse(observer)
            expected.update(DEVSHARD_ADMIN_API_KEY='new-admin-key-000000',
                            GDC_GATEWAY_ADMIN_STATE_URL=f'http://127.0.0.1:{port}/v1/admin/devshards')
            self.assertEqual(binding.parse(after), expected)
            self.assertEqual(token, 'observer-token-000000')
        with self.assertRaises(ValueError):
            binding.binding(observer, 'DEVSHARD_ADMIN_API_KEY=observer-token-000000\n', 18187)
        with self.assertRaises(ValueError):
            binding.parse('A=1\nA=2\n')


if __name__ == '__main__':
    unittest.main()
