#!/usr/bin/env python3
"""Focused conformance tests for the offline network bootstrap contract."""

from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import tempfile
import unittest
import stat
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "scripts" / "network-bootstrap.py"
SCHEMA = ROOT / "bootstrap" / "v1.bootstrap.schema.json"
STAGER = ROOT / "scripts" / "stage-network-bootstrap.sh"
PUBLISHER = ROOT / "scripts" / "publish-network-bootstrap.sh"
SET_PUBLISHER = ROOT / "scripts" / "publish-network-bootstrap-set.sh"
ATTESTATION_WORKFLOW = ROOT.parent / ".github" / "workflows" / "network-bootstrap-attestation.yml"


def document(host: str = "seed.example.net", credential: str | None = "public-demo-token") -> dict:
    genesis = b'{"chain_id":"gonka-fixture"}\n'
    inference = [{"url": "https://inference.example.net/v1"}]
    if credential is not None:
        inference[0]["authentication"] = {"scheme": "bearer", "credential": credential}
    return {
        "$schema": "https://gonka-dev.net/v1.bootstrap.schema.json",
        "chain_id": "gonka-fixture",
        "genesis": {"encoding": "base64", "sha256": hashlib.sha256(genesis).hexdigest(), "data": base64.b64encode(genesis).decode()},
        "seeds": [{"node_id": "0123456789abcdef0123456789abcdef01234567", "host": host, "port": 5000}],
        "services": {"rpc": ["https://rpc.example.net"], "api": ["https://api.example.net/v1"], "inference": inference},
    }


class BootstrapTests(unittest.TestCase):
    def write(self, directory: Path, name: str, value: object) -> Path:
        path = directory / name
        if isinstance(value, bytes):
            path.write_bytes(value)
        else:
            path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def run_tool(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["python3", str(TOOL), *arguments], text=True, capture_output=True, check=False)

    def test_schema_meta_validates(self) -> None:
        Draft202012Validator.check_schema(json.loads(SCHEMA.read_text(encoding="utf-8")))

    def test_valid_dns_ipv4_ipv6_and_unauthenticated_services(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for name, host, credential in (("dns.json", "seed.example.net", "public-demo-token"), ("ipv4.json", "8.8.8.8", None), ("ipv6.json", "2606:4700:4700::1111", None)):
                result = self.run_tool("verify", str(self.write(directory, name, document(host, credential))))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Repository attestation was not checked", result.stdout)

    def test_render_is_deterministic_and_ends_in_one_newline(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            source = self.write(directory, "source.json", document())
            first, second = directory / "first.json", directory / "second.json"
            self.assertEqual(self.run_tool("render", str(source), str(first)).returncode, 0)
            self.assertEqual(self.run_tool("render", str(source), str(second)).returncode, 0)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertTrue(first.read_bytes().endswith(b"\n"))

    def test_stage_preserves_exact_genesis_and_keeps_credential_private(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            source = self.write(directory, "source.json", document())
            stage = directory / "stage"
            result = self.run_tool("stage", str(source), str(stage))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("public-demo-token", result.stdout)
            self.assertEqual(json.loads(stage.joinpath("genesis.json").read_text())["chain_id"], "gonka-fixture")
            self.assertEqual(stage.joinpath("genesis-seeds.txt").read_text(), "0123456789abcdef0123456789abcdef01234567@seed.example.net:5000\n")
            self.assertEqual(stage.joinpath("gateway.join-client-key").read_text(), "public-demo-token")
            self.assertEqual(stat.S_IMODE(stage.joinpath("gateway.join-client-key").stat().st_mode), 0o600)

    def test_shell_stager_writes_exact_genesis_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            source = self.write(directory, "source.json", document())
            genesis, state, secrets = directory / "genesis", directory / "state", directory / "secrets"
            result = subprocess.run([str(STAGER), "--bootstrap-file", str(source), "--genesis-dir", str(genesis), "--state-dir", str(state), "--secrets-dir", str(secrets)], text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("public-demo-token", result.stdout)
            self.assertEqual(genesis.joinpath("genesis.json").read_bytes(), b'{"chain_id":"gonka-fixture"}\n')
            self.assertIn("bootstrap_schema=https://gonka-dev.net/v1.bootstrap.schema.json", state.joinpath("network-bootstrap.env").read_text())
            self.assertEqual(stat.S_IMODE(secrets.joinpath("gateway.join-client-key").stat().st_mode), 0o600)

    def test_publisher_replaces_only_valid_complete_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            good = self.write(directory, "good.json", document())
            published = directory / "public" / "gonka-devnet-community.json"
            first = subprocess.run([str(PUBLISHER), "--artifact", str(good), "--published", str(published)], text=True, capture_output=True, check=False)
            self.assertEqual(first.returncode, 0, first.stderr)
            original = published.read_bytes()
            bad = self.write(directory, "bad.json", {"chain_id": "unsafe"})
            second = subprocess.run([str(PUBLISHER), "--artifact", str(bad), "--published", str(published)], text=True, capture_output=True, check=False)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(published.read_bytes(), original)

    def test_set_publisher_requires_each_named_network_document(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            artifacts = directory / "artifacts"
            artifacts.mkdir()
            artifacts.joinpath("v1.bootstrap.schema.json").write_bytes(SCHEMA.read_bytes())
            for name in ("gonka-mainnet.json", "gonka-testnet.json", "gonka-devnet-community.json"):
                self.write(artifacts, name, document())
            published = directory / "published"
            result = subprocess.run([str(SET_PUBLISHER), "--artifacts", str(artifacts), "--published", str(published)], text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(published.joinpath("current").is_symlink())
            self.assertEqual(published.joinpath("current", "v1.bootstrap.schema.json").read_bytes(), SCHEMA.read_bytes())
            first_target = published.joinpath("current").readlink()
            replacement = document()
            replacement_genesis = b'{"chain_id":"gonka-replacement"}\n'
            replacement["chain_id"] = "gonka-replacement"
            replacement["genesis"] = {"encoding": "base64", "sha256": hashlib.sha256(replacement_genesis).hexdigest(), "data": base64.b64encode(replacement_genesis).decode()}
            for name in ("gonka-mainnet.json", "gonka-testnet.json", "gonka-devnet-community.json"):
                self.write(artifacts, name, replacement)
            replacement_result = subprocess.run([str(SET_PUBLISHER), "--artifacts", str(artifacts), "--published", str(published)], text=True, capture_output=True, check=False)
            self.assertEqual(replacement_result.returncode, 0, replacement_result.stderr)
            self.assertNotEqual(published.joinpath("current").readlink(), first_target)
            preserved_target = published.joinpath("current").readlink()
            artifacts.joinpath("gonka-testnet.json").unlink()
            rejected = subprocess.run([str(SET_PUBLISHER), "--artifacts", str(artifacts), "--published", str(published)], text=True, capture_output=True, check=False)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("gonka-testnet.json", rejected.stderr)
            self.assertEqual(published.joinpath("current").readlink(), preserved_target)

    def test_rejects_duplicate_keys_and_invalid_utf8(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            duplicate = self.write(directory, "duplicate.json", b'{"$schema":"x","$schema":"y"}')
            invalid = self.write(directory, "invalid.json", b'\xff')
            for path, expected in ((duplicate, "duplicate key"), (invalid, "invalid UTF-8")):
                result = self.run_tool("verify", str(path))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_schema_and_verifier_reject_unknown_fields_malformed_base64_and_size(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            cases = []
            unknown = document()
            unknown["publisher"] = "not-allowed"
            cases.append(("unknown.json", unknown, "Additional properties"))
            malformed = document()
            malformed["genesis"]["data"] = "not-base64!"
            cases.append(("base64.json", malformed, "genesis.data"))
            oversized = document()
            oversized["genesis"]["data"] = base64.b64encode(b"x" * (1024 * 1024 + 1)).decode()
            oversized["genesis"]["sha256"] = hashlib.sha256(b"x" * (1024 * 1024 + 1)).hexdigest()
            cases.append(("oversized.json", oversized, "genesis.data"))
            for name, value, expected in cases:
                result = self.run_tool("verify", str(self.write(directory, name, value)))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_attestation_workflow_targets_only_the_exact_release_files(self) -> None:
        workflow = ATTESTATION_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("attestations: write", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertNotIn("signer-workflow", workflow)
        for name in ("v1.bootstrap.schema.json", "gonka-mainnet.json", "gonka-testnet.json", "gonka-devnet-community.json"):
            self.assertIn(f"subject-path: net-deployment-runbook/bootstrap/release/{name}", workflow)

    def test_rejects_semantic_hazards_without_echoing_credential(self) -> None:
        cases = [
            ("hash.json", lambda value: value["genesis"].update(sha256="0" * 64), "genesis.sha256"),
            ("chain.json", lambda value: value.update(chain_id="other-chain"), "chain_id"),
            ("host.json", lambda value: value["seeds"][0].update(host="https://bad.example"), "seeds[0].host"),
            ("private-host.json", lambda value: value["seeds"][0].update(host="192.168.1.10"), "seeds[0].host"),
            ("service.json", lambda value: value["services"]["api"].__setitem__(0, "http://bad.example"), "services.api[0]"),
            ("credential.json", lambda value: value["services"]["inference"][0]["authentication"].update(credential="sk-secret-canary"), "credential"),
        ]
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for name, mutate, field in cases:
                value = document()
                mutate(value)
                result = self.run_tool("verify", str(self.write(directory, name, value)))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(field, result.stderr)
                self.assertNotIn("sk-secret-canary", result.stderr)

    def test_rejects_duplicate_node_id_even_with_a_different_endpoint(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            value = document()
            value["seeds"].append({"node_id": value["seeds"][0]["node_id"], "host": "other.example.net", "port": 5001})
            result = self.run_tool("verify", str(self.write(directory, "duplicate-seed.json", value)))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate seed", result.stderr)


if __name__ == "__main__":
    unittest.main()
