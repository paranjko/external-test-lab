import importlib.util
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys

spec = importlib.util.spec_from_file_location('migration', Path(__file__).with_name('update-serving-observation-model.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpdateTest(unittest.TestCase):
    def test_quoted_admission_binding_preserves_other_values(self):
        for layout in ('srv/dai/edge', 'srv/dai/deploy/edge'):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                env = root / layout / 'admission.env'
                env.parent.mkdir(parents=True)
                before = b'TOKEN="fixture"\nGDC_GATEWAY_READINESS_MODEL="old"\nPROTOCOL=v6\n'
                env.write_bytes(before)
                env.chmod(0o600)
                subprocess.run([sys.executable, str(Path(module.__file__)), '--bot-env', str(env),
                                '--env-key', 'GDC_GATEWAY_READINESS_MODEL', '--expected-model', 'old',
                                '--model', 'new', '--evidence', str(root / 'proof')], check=True)
                self.assertEqual(env.read_bytes(), before.replace(b'"old"', b'"new"'))
                self.assertEqual(env.stat().st_mode & 0o777, 0o600)

    def test_clean_supported_layouts_and_preservation(self):
        for layout in ('srv/dai/edge/site', 'srv/dai/deploy/edge/site'):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bot = root / 'bot.env'
                site = root / layout / 'config.js'
                site.parent.mkdir(parents=True)
                before = b'TOKEN=fixture-secret\nMODEL=old\nOTHER=keep\n'
                config = b'window.GDC_CONFIG = {"model": "old", "apiBase":"https://fixture.invalid/v1"};\n'
                bot.write_bytes(before)
                bot.chmod(0o600)
                site.write_bytes(config)
                site.chmod(0o644)
                proof = root / 'proof'
                subprocess.run([sys.executable, str(Path(module.__file__)), '--bot-env', str(bot),
                                '--site-config', str(site), '--expected-model', 'old', '--model', 'new',
                                '--evidence', str(proof)], check=True)
                self.assertEqual(bot.read_bytes(), before.replace(b'MODEL=old', b'MODEL=new'))
                self.assertEqual(site.read_bytes(), config.replace(b'"old"', b'"new"'))
                self.assertEqual(bot.stat().st_mode & 0o777, 0o600)
                self.assertEqual(site.stat().st_mode & 0o777, 0o644)
                self.assertEqual((proof / '0.before').read_bytes(), before)
                self.assertEqual((proof / '1.before').read_bytes(), config)
                self.assertEqual((proof / '0.before').stat().st_mode & 0o777, 0o600)

    def test_drift_duplicate_and_symlink_refuse_without_partial_write(self):
        for defect in ('drift', 'duplicate', 'symlink'):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bot, site = root / 'bot.env', root / 'config.js'
                bot.write_text('MODEL=old\n')
                site.write_text('window.GDC_CONFIG = {"model":"wrong"};' if defect == 'drift'
                                else 'window.GDC_CONFIG = {"model":"old"};')
                sites = [site, site] if defect == 'duplicate' else [site]
                if defect == 'symlink':
                    link = root / 'link.js'
                    link.symlink_to(site)
                    sites = [link]
                with self.assertRaises(ValueError):
                    module.update(bot, sites, 'old', 'new', root / 'proof')
                self.assertEqual(bot.read_text(), 'MODEL=old\n')
                self.assertFalse((root / 'proof').exists())


if __name__ == '__main__':
    unittest.main()
