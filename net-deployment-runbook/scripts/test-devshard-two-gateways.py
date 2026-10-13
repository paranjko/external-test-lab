#!/usr/bin/env python3
"""Offline contracts; artifact/runtime acceptance is a separate target."""

import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("preview", ROOT / "scripts/devshard-preview.py")
preview = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preview)
INSTANCE_SPEC = importlib.util.spec_from_file_location("instances", ROOT / "04-ops/devshard-instances.py")
instances = importlib.util.module_from_spec(INSTANCE_SPEC)
INSTANCE_SPEC.loader.exec_module(instances)


def synthetic_address(seed):
    charset = preview.CHARSET
    words = [seed] * 32
    hrp = "gonka"
    values = [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp] + words + [0] * 6
    chk = 1
    for value in values:
        top = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ value
        for i, gen in enumerate((0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)):
            if (top >> i) & 1:
                chk ^= gen
    chk ^= 1
    return hrp + "1" + "".join(charset[v] for v in words + [(chk >> (5 * (5 - i))) & 31 for i in range(6)])


class GovernanceTests(unittest.TestCase):
    def setUp(self):
        self.creators = [synthetic_address(i) for i in range(3)]
        self.before = {"unknown": {"unicode": "é", "bool": False, "list": [3, 2, 1]},
                       "devshard_escrow_params": {
                           "max_escrow_amount": "100000000000", "future": {"keep": True},
                           "allowed_creator_addresses": self.creators[:1],
                           "approved_versions": [{"name": name, "binary": "https://example.invalid/old.zip",
                                                  "sha256": "a" * 64, "future": {"keep": name}}
                                                 for name in ("v3", "v4", "v5", "v6")]}}
        self.sha = preview.digest(self.before)

    def test_activation_preserves_whole_document(self):
        saved = copy.deepcopy(self.before)
        result = preview.preview({"params": self.before}, self.sha, "activate", self.creators[1:])
        after = result["desired_params"]
        self.assertEqual(saved, self.before)
        self.assertEqual(after["unknown"], saved["unknown"])
        old = saved["devshard_escrow_params"]
        new = after["devshard_escrow_params"]
        self.assertEqual(new["allowed_creator_addresses"], self.creators)
        self.assertEqual(new["approved_versions"][:2], old["approved_versions"][:2])
        self.assertEqual(new["approved_versions"][3], old["approved_versions"][3])
        self.assertEqual(new["approved_versions"][2]["future"], {"keep": "v5"})
        self.assertEqual(result["messages"][0]["params"], after)
        self.assertFalse(result["submission_enabled"])
        again = preview.preview(after, preview.digest(after), "activate", self.creators[1:])
        self.assertEqual(again["delta"], [])

    def test_recovery_and_retirement_preserve_unknowns_and_creators(self):
        for action in ("recover", "retire"):
            with self.subTest(action=action):
                result = preview.preview(self.before, self.sha, action)
                before = copy.deepcopy(self.before)
                after = copy.deepcopy(result["desired_params"])
                old_versions = before["devshard_escrow_params"].pop("approved_versions")
                new_versions = after["devshard_escrow_params"].pop("approved_versions")
                self.assertEqual(before, after)
                if action == "retire":
                    self.assertEqual(new_versions, old_versions[2:])
                else:
                    self.assertEqual(new_versions[2]["sha256"], preview.ARTIFACTS["recover"][1])
                    for i in (0, 1, 3):
                        self.assertEqual(new_versions[i], old_versions[i])

    def test_drift_missing_duplicate_invalid_bindings(self):
        for creators in ([], self.creators[:1], [self.creators[1]] * 2,
                         ["gonka1invalid", self.creators[1]],
                         [self.creators[1].upper(), self.creators[2]],
                         [self.creators[1][:-1] + "x", self.creators[2]]):
            with self.subTest(creators=creators), self.assertRaises(ValueError):
                preview.preview(self.before, self.sha, "activate", creators)
        with self.assertRaisesRegex(ValueError, "stale"):
            preview.preview(self.before, "b" * 64, "recover")
        changed = copy.deepcopy(self.before)
        changed["unknown"]["bool"] = True
        with self.assertRaisesRegex(ValueError, "stale"):
            preview.preview(changed, self.sha, "retire")
        for key in ("approved_versions", "allowed_creator_addresses"):
            bad = copy.deepcopy(self.before)
            bad["devshard_escrow_params"][key] *= 2
            with self.assertRaisesRegex(ValueError, "duplicate"):
                preview.preview(bad, preview.digest(bad), "recover")
        bad = copy.deepcopy(self.before)
        bad["devshard_escrow_params"]["allowed_creator_addresses"] = []
        with self.assertRaisesRegex(ValueError, "permissionless"):
            preview.preview(bad, preview.digest(bad), "activate", self.creators[1:])

    def test_existing_snapshot_verifier_compatibility(self):
        result = preview.preview(self.before, self.sha, "activate", self.creators[1:])
        proposal = {"messages": result["messages"], "metadata":
                    f"gdc-devshard-v1:mutable=v5;before-sha256={self.sha};message-sha256={result['messages_sha256']}"}
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "proposal.json").write_text(json.dumps(proposal))
            for mode, value in (("before", self.before), ("after", result["desired_params"])):
                (directory / "params.json").write_text(json.dumps({"params": value}))
                process = subprocess.run(["bash", str(ROOT / "scripts/verify-devshard-governance-snapshot.sh"),
                                          mode, str(directory / "proposal.json"), str(directory / "params.json"), "v5"],
                                         capture_output=True, text=True)
                self.assertEqual(process.returncode, 0, process.stderr)

    def test_cli_has_no_apply_and_rejects_duplicate_json(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "params.json"
            source.write_text(json.dumps(self.before))
            command = ["python3", str(ROOT / "scripts/devshard-preview.py"), "retire",
                       "--params", str(source), "--expected-sha256", self.sha]
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["action"], "retire")
            self.assertNotEqual(subprocess.run(command + ["--apply"], capture_output=True).returncode, 0)
            source.write_text('{"params": {}, "params": {}}')
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("duplicate JSON", result.stderr)


class InstanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.directory.chmod(0o700)
        self.files = {identity: self.directory / f"{identity}.env" for identity in ("A", "B")}
        for i, identity in enumerate(self.files, 1):
            self.files[identity].write_text(
                f"DEVSHARD_PRIVATE_KEY={i:064x}\nDEVSHARD_ADMIN_API_KEY=synthetic-admin-{identity}-0123456789\n"
                f"DEVSHARD_API_KEYS=synthetic-client-{identity}-0123456789\n")
            self.files[identity].chmod(0o600)
        self.design = {"gateway_image": instances.IMAGE, "platform": "linux/amd64",
                       "gateway_common_env": copy.deepcopy(instances.ENV), "gateways": []}
        for i, identity in enumerate(("A", "B")):
            slug = identity.lower()
            self.design["gateways"].append({
                "id": identity, "project": f"gdc-ds502-{slug}", "volume": f"gdc-ds502-{slug}-data",
                "directory": f"/srv/dai/broker-tests/ds502-{slug}", "service": "gateway",
                "creator_address": synthetic_address(i + 1), "external_network": f"synthetic-host-{slug}",
                "api_bind": f"127.0.0.1:{18087 + i}:8080", "accounting_bind": f"127.0.0.1:{19091 + i}:9091"})

    def test_actual_compose_models(self):
        rendered = instances.render(self.design, self.files)
        for identity, model in rendered.items():
            path = self.directory / f"{identity}.compose.json"
            path.write_text(json.dumps(model))
            process = subprocess.run(["docker", "compose", "-f", str(path), "config", "--format", "json"],
                                     capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            composed = json.loads(process.stdout)
            self.assertEqual(set(composed["services"]), {"gateway"})
            service = composed["services"]["gateway"]
            self.assertEqual(service["image"], instances.IMAGE)
            self.assertNotIn("network_mode", service)
            self.assertIsNone(service.get("command"))
            self.assertIsNone(service.get("entrypoint"))
            self.assertEqual(service["volumes"][0]["type"], "volume")
            self.assertEqual(service["volumes"][0]["target"], "/root/.devshardctl")
            self.assertTrue(all(binding["host_ip"] == "127.0.0.1" for binding in service["ports"]))
            for key in ("DEVSHARD_ESCROW_ROTATION_ENABLED", "DEVSHARD_ESCROW_ROTATION_SETTLEMENT_ENABLED"):
                self.assertEqual(service["environment"][key], "false")
            self.assertEqual(service["environment"][instances.CHAT_CACHE_KEY], "1")
            for value in instances.secrets(self.files[identity]):
                self.assertNotIn(value, json.dumps(model))

    def test_duplicate_resources_and_public_ports(self):
        for key in ("project", "volume", "directory", "creator_address", "api_bind", "accounting_bind"):
            bad = copy.deepcopy(self.design)
            bad["gateways"][1][key] = bad["gateways"][0][key]
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "duplicate"):
                instances.render(bad, self.files)
        for key in ("api_bind", "accounting_bind"):
            for host in ("0.0.0.0", "192.0.2.1", "[::]"):
                bad = copy.deepcopy(self.design)
                bad["gateways"][0][key] = bad["gateways"][0][key].replace("127.0.0.1", host)
                with self.subTest(key=key, host=host), self.assertRaises(ValueError):
                    instances.render(bad, self.files)

    def test_fresh_cache_policy_preserves_input_and_explicit_design(self):
        saved = copy.deepcopy(self.design)
        implicit = instances.render(self.design, self.files)
        self.assertEqual(self.design, saved)
        self.design["gateway_common_env"][instances.CHAT_CACHE_KEY] = "1"
        self.assertEqual(instances.render(self.design, self.files), implicit)
        for identity in ("A", "B"):
            environment = copy.deepcopy(implicit[identity]["services"]["gateway"]["environment"])
            self.assertEqual(environment.pop(instances.CHAT_CACHE_KEY), "1")
            self.assertEqual(environment, saved["gateway_common_env"])

    def test_cache_default_restoration_or_unqualified_override_is_refused(self):
        for value in ("0", "-1", "256000000", "true", 1, None):
            bad = copy.deepcopy(self.design)
            bad["gateway_common_env"][instances.CHAT_CACHE_KEY] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "fresh inference"):
                instances.render(bad, self.files)

    def test_duplicate_secrets_and_file_permissions(self):
        self.files["B"].write_text(self.files["A"].read_text())
        with self.assertRaisesRegex(ValueError, "duplicate A/B key"):
            instances.render(self.design, self.files)
        self.files["A"].chmod(0o644)
        with self.assertRaisesRegex(ValueError, "0600"):
            instances.render(self.design, self.files)
        self.files["A"].chmod(0o600)
        self.directory.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "0700"):
            instances.render(self.design, self.files)

    def test_mainnet_and_inherited_state_rejected(self):
        for key, value in (("DEVSHARD_CHAIN_ID", "gonka-mainnet"),
                           ("DEVSHARD_CHAIN_RPC", "https://node3.gonka.ai:26657"),
                           ("DEVSHARD_PUBLIC_API", "http://node3.gonka.ai:9000"),
                           ("DEVSHARDS_JSON", '[{"escrow_id":"123"}]'),
                           ("DEVSHARD_STORAGE_DIR", "/old/database"),
                           ("DEVSHARD_ESCROW_ROTATION_ENABLED", "true")):
            bad = copy.deepcopy(self.design)
            bad["gateway_common_env"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                instances.render(bad, self.files)
        bad = copy.deepcopy(self.design)
        bad["gateways"][0]["database"] = "/old/data.db"
        with self.assertRaisesRegex(ValueError, "inherited"):
            instances.render(bad, self.files)

    def test_full_settings_preserved_model_selected_by_id(self):
        original = {"default_model": "old", "unknown": {"preserve": [True, 3]},
                    "request_max_tokens_cap": 4000, "max_concurrent_requests": 17,
                    "escrow_rotation": {"enabled": True, "settlement_enabled": True, "future": 42},
                    "participant_throttle": {"request_burst": 600, "recovery_per_minute": 10, "future": 4},
                    "model_limits": [{"model_id": "other", "access_mode": "public", "future": 4},
                                     {"model_id": "Qwen/Qwen3-0.6B", "access_mode": "public", "limit": 19}]}
        saved = copy.deepcopy(original)
        wanted = instances.settings(original, "Qwen/Qwen3-0.6B", ["Qwen/Qwen3-0.6B"])
        expected = copy.deepcopy(original)
        expected["default_model"] = "Qwen/Qwen3-0.6B"
        expected["model_limits"][1]["access_mode"] = "api_key"
        expected["participant_throttle"].update(
            request_burst=instances.TEST_STAND_PARTICIPANT_BUDGET,
            recovery_per_minute=instances.TEST_STAND_PARTICIPANT_BUDGET,
        )
        self.assertEqual(wanted, expected)
        self.assertEqual(original, saved)
        with self.assertRaisesRegex(ValueError, "catalog"):
            instances.settings(original, "Qwen/Qwen3-0.6B", [])
        original["model_limits"].append(copy.deepcopy(original["model_limits"][1]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            instances.settings(original, "Qwen/Qwen3-0.6B", ["Qwen/Qwen3-0.6B"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
