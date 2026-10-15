#!/usr/bin/env python3
"""Frozen v6 rendering never deploys, leaks credentials or overwrites files."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PATH = Path(__file__).with_name("render-v6-admission.py")
spec = importlib.util.spec_from_file_location("renderer", PATH)
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
TOKEN = "fixture-observer-token-1234"
BINDING = {"upstream": "http://127.0.0.1:18187", "observer": "http://127.0.0.1:18084/v1/status",
           "chain_api": "http://127.0.0.1:1317", "chain_rpc": "http://127.0.0.1:26657",
           "approved_versions": "http://127.0.0.1:1317/approved", "port": 18083}


class Render(unittest.TestCase):
    def test_exact_artifact_and_dedicated_registry(self):
        values = dict(line.split("=", 1) for line in renderer.render(BINDING, TOKEN).splitlines())
        self.assertEqual(values["GDC_GATEWAY_ADMISSION_SELECTED_VERSION"], "v6")
        contract = json.loads(values["GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON"])
        self.assertEqual(set(contract), {"v6"})
        # The reviewed release recipe can advance on main independently of this
        # renderer. Require an exact copy of both bindings, not an obsolete SHA.
        archive = json.loads(renderer.artifacts.DEFINITION.read_text())["devshard_zip"]
        self.assertEqual(contract["v6"], {"binary": archive["url"], "sha256": archive["sha256"]})
        self.assertEqual(values["GDC_GATEWAY_ADMISSION_APPROVED_VERSIONS_URL"], BINDING["approved_versions"])

    def test_reject_invalid_binding_and_mutated_artifact(self):
        for update in ({"protocol": "v7"}, {"port": True}, {"port": 80},
                       {"upstream": "http://127.0.0.1:18083"},
                       {"observer": "http://public.example/status"},
                       {"observer": "https://user:secret@example.org/status"},
                       {"observer": "https://example.org/status\nINJECT=yes"}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                renderer.render(dict(BINDING, **update), TOKEN)
        with tempfile.TemporaryDirectory() as temporary:
            definition = json.loads(renderer.artifacts.DEFINITION.read_text())
            definition["devshard_zip"]["sha256"] = "0" * 64
            path = Path(temporary) / "definition.json"
            path.write_text(json.dumps(definition))
            with self.assertRaises(ValueError):
                renderer.render(BINDING, TOKEN, path)

    def test_private_output_refuses_overwrite_and_public_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binding, token, output = (root / name for name in ("binding.json", "token", "output.env"))
            binding.write_text(json.dumps(BINDING))
            token.write_text(TOKEN)
            token.chmod(0o600)
            command = [sys.executable, str(PATH), "--binding", str(binding),
                       "--observer-token-file", str(token), "--output", str(output)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(TOKEN, result.stdout + result.stderr)
            self.assertFalse(json.loads(result.stdout)["deployed"])
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            before = output.read_bytes()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(output.read_bytes(), before)
            output.unlink()
            token.chmod(0o644)
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
