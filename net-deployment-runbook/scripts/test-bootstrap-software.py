#!/usr/bin/env python3
"""Exercise both bootstrap readers against the same data, without live services."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE = ROOT.parent / "bootstrap/examples/software-v1.json"


class SoftwareContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.doc = json.loads(EXAMPLE.read_text())
        self.path = self.root / "bootstrap.json"
        self.env = dict(os.environ)
        poison = self.root / "bin"
        poison.mkdir()
        for name in ("ssh", "scp", "curl", "wget", "docker", "inferenced"):
            executable = poison / name
            executable.write_text("#!/bin/sh\necho unexpected external call >&2\nexit 97\n")
            executable.chmod(0o755)
        self.env["PATH"] = str(poison) + os.pathsep + self.env["PATH"]
        self.env["HOME"] = str(self.root)

    def readers(self, command, doc):
        self.path.write_text(json.dumps(doc))
        for interpreter, script in (("bash", "network-bootstrap.sh"), ("python3", "network-bootstrap.py")):
            with self.subTest(reader=script, command=command):
                yield subprocess.run(
                    [interpreter, str(ROOT / "scripts" / script), command, str(self.path)],
                    capture_output=True, text=True, env=self.env, timeout=15)

    def test_exact_round_trip(self):
        for result in self.readers("software", self.doc):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), self.doc["software"])
        self.doc["software"]["components"]["postgres"] = {
            "version": "17.4", "image": "postgres:17.4@sha256:" + "c" * 64}
        self.doc["software"]["components"]["node"].pop("upgrade")
        for result in self.readers("software", self.doc):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), self.doc["software"])

    def test_legacy_absence_and_endpoint_projection(self):
        legacy = copy.deepcopy(self.doc)
        legacy.pop("software")
        for result in self.readers("verify", legacy):
            self.assertEqual(result.returncode, 0, result.stderr)
        for result in self.readers("software", legacy):
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("not declared", result.stderr)
        before = [r.stdout for r in self.readers("env", legacy)]
        after = [r.stdout for r in self.readers("env", self.doc)]
        self.assertEqual(before, after)

    def test_local_publication_preserves_complete_descriptor(self):
        self.path.write_text(json.dumps(self.doc))
        rendered = subprocess.run(
            ["python3", str(ROOT / "scripts/network-bootstrap.py"), "env", str(self.path)],
            capture_output=True, text=True, env=self.env, check=True, timeout=15)
        env_file = self.root / "bootstrap.env"
        env_file.write_text(rendered.stdout)
        public = self.root / "public"
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/publish-network-bootstrap-pair.sh"),
             "--json", str(self.path), "--env", str(env_file),
             "--published-root", str(public)],
            capture_output=True, text=True, env=self.env, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((public / self.doc["chain_id"] / "bootstrap.json").read_bytes(),
                         self.path.read_bytes())

    def test_rejects_incomplete_unsafe_or_ambiguous_software(self):
        mutations = [
            ("software", None), ("software", {}), ("software.schema_version", 2),
            ("software.schema_version", True),
            ("software.extra", True), ("software.platform", "auto"),
            ("software.accelerator", "any"),
            ("software.deployment.commit", "main"),
            ("software.deployment.repository", "http://example.com/repo"),
            ("software.deployment.repository", "https://user:pass@example.com/repo"),
            ("software.deployment.repository", "https://example.com:70000/repo"),
            ("software.deployment.compose_files", []),
            ("software.deployment.compose_files.0.path", "../compose.yml"),
            ("software.deployment.compose_files.0.path", "/compose.yml"),
            ("software.deployment.compose_files.0.sha256", "a" * 63),
            ("software.components.node.image", "registry.example/node:latest"),
            ("software.components.api.image", "registry.example/api@sha256:bad"),
            ("software.components.node.upgrade.name", "../escape"),
            ("software.components.node.upgrade.artifact.executable", "../../inferenced"),
            ("software.components.node.upgrade.artifact.format", "shell"),
            ("software.components.api.upgrade.artifact.url", "https://example.com/x?mutable=1"),
            ("software.components.api.upgrade.artifact.sha256", "A" * 64),
            ("software.components.tmkms.upgrade", {}),
            ("software.operator_cli.version", "different"),
            ("software.model.revision", "main"),
            ("software.model.context_length", 0),
            ("software.model.context_length", True),
            ("software.model.max_num_seqs", 1.5),
            ("software.model.gpu_memory_utilization", 1.1),
            ("software.model.gpu_memory_utilization", 0),
            ("software.model.dtype", "magic"),
            ("software.model.tensor_parallel_size", 0),
        ]
        invalid = []
        for field, value in mutations:
            doc = copy.deepcopy(self.doc)
            target = doc
            keys = field.split(".")
            for key in keys[:-1]:
                target = target[int(key)] if isinstance(target, list) else target[key]
            target[keys[-1]] = value
            invalid.append((field, doc))
        for required in self.doc["software"]:
            doc = copy.deepcopy(self.doc)
            doc["software"].pop(required)
            invalid.append(("missing " + required, doc))
        for name in ("node", "api", "tmkms", "mlnode"):
            doc = copy.deepcopy(self.doc)
            doc["software"]["components"].pop(name)
            invalid.append(("missing " + name, doc))
        doc = copy.deepcopy(self.doc)
        doc["software"]["deployment"]["compose_files"].append({
            "path": doc["software"]["deployment"]["compose_files"][0]["path"],
            "sha256": "f" * 64})
        invalid.append(("duplicate path with different digest", doc))
        for name, doc in invalid:
            with self.subTest(case=name):
                for result in self.readers("software", doc):
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(result.stdout, "")
                    self.assertIn("software", result.stderr)

    def test_fetch_preserves_software_without_python(self):
        mock = self.root / "bin" / "curl"
        mock.write_text(
            "#!/bin/sh\nwhile [ $# -gt 0 ]; do\n"
            '  if [ "$1" = -o ]; then out=$2; shift; fi\n  shift\ndone\n'
            'cp "$FIXTURE" "$out"\nprintf 200\n')
        python = self.root / "bin" / "python3"
        python.write_text("#!/bin/sh\nexit 97\n")
        python.chmod(0o755)
        self.path.write_text(json.dumps(self.doc))
        self.env["FIXTURE"] = str(self.path)
        output = self.root / "fetched.json"
        command = ["bash", str(ROOT / "scripts/fetch-network-bootstrap.sh"),
                   "--url", "https://example.com/bootstrap.json", "--output", str(output)]
        result = subprocess.run(command, capture_output=True, text=True, env=self.env, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), self.path.read_bytes())
        previous = output.read_bytes()
        self.doc["software"] = {}
        self.path.write_text(json.dumps(self.doc))
        result = subprocess.run(command, capture_output=True, text=True, env=self.env, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()
