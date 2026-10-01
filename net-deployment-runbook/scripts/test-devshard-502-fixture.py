#!/usr/bin/env python3
"""Offline containment contracts; these are not runtime compatibility tests."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("devshard-502-fixture.py"))
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class FixtureContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        names = ("mock-chain", "mock-dapi", "mock-openai", "versiond-0", "versiond-router", "devshardctl")
        self.generated = {"services": {name: {
            "image": "source-built:latest", "build": {"context": "../.."},
            "restart": "unless-stopped", "networks": {"upstream": {}},
            "environment": {}, "volumes": [],
            "ports": [{"target": 8080, "published": "8080"}],
        } for name in names}}
        self.generated["services"]["versiond-0"]["environment"] = {
            "CHAIN_ID": fixture.CHAIN, "VERSIOND_FORCE": "v5", "VERSIOND_OVERRIDE_v5": "/rebuilt/devshardd"}
        self.generated["services"]["devshardctl"].update(
            depends_on={"versiond-router": {"condition": "service_started"}},
            entrypoint=["rebuilt-devshardctl"], command=["unsafe"])

    def render(self):
        return fixture.composition(copy.deepcopy(self.generated), self.root, "ds502-fixture-unit")

    def test_private_non_ha_exact_images_and_no_rebuilt_runtime(self):
        document = self.render()
        self.assertEqual(document["networks"], {"fixture": {"internal": True}})
        services = document["services"]
        self.assertNotIn("versiond-router", services)
        self.assertEqual(services["devshardctl"]["image"], fixture.GATEWAY)
        self.assertEqual(services["versiond-0"]["image"], fixture.VERSIOND)
        self.assertNotIn("entrypoint", services["devshardctl"])
        self.assertNotIn("command", services["devshardctl"])
        for service in services.values():
            self.assertNotIn("build", service)
            self.assertEqual(service["restart"], "no")
            for port in service["ports"]:
                self.assertEqual(port["host_ip"], "127.0.0.1")
            for mount in service["volumes"]:
                self.assertTrue(Path(mount["source"]).is_relative_to(self.root))
                self.assertFalse(mount["bind"]["create_host_path"])
        env = services["versiond-0"]["environment"]
        self.assertEqual(env["DEVSHARD_STORAGE_MODE"], "sqlite")
        self.assertEqual(env["GONKA_HA"], "false")
        self.assertFalse(any(key.startswith("VERSIOND_OVERRIDE_") for key in env))
        self.assertNotIn("VERSIOND_FORCE", env)

    def test_both_child_shutdown_graces_fit_supervisor_budget(self):
        env = self.render()["services"]["versiond-0"]["environment"]
        grace = max(int(env[key].removesuffix("s")) for key in
                    ("DEVSHARD_SHUTDOWN_GRACE", "VERSIOND_DRAIN_KILL_GRACE"))
        self.assertLess(grace, int(env["VERSIOND_HOST_SHUTDOWN_BUDGET"].removesuffix("s")))
        self.assertEqual(env["VERSIOND_DRAIN_ANNOUNCE"], "0s")

    def test_extra_service_or_live_chain_rejected(self):
        self.generated["services"]["live-node"] = {}
        with self.assertRaisesRegex(ValueError, "topology"):
            self.render()
        del self.generated["services"]["live-node"]
        self.generated["services"]["versiond-0"]["environment"]["CHAIN_ID"] = "gonka-mainnet"
        with self.assertRaisesRegex(ValueError, "chain"):
            self.render()

    def test_inherited_mount_outside_fixture_rejected(self):
        self.generated["services"]["mock-openai"]["volumes"] = [
            fixture.bind("/srv/dai/data", "/production", False)]
        with self.assertRaisesRegex(ValueError, "mount escaped"):
            self.render()

    def test_seed_and_artifact_identities_are_explicit(self):
        seed = fixture.seed()
        self.assertEqual(seed["chain_id"], fixture.CHAIN)
        self.assertEqual(seed["versiond"]["mode"], "single")
        self.assertEqual(seed["escrow"]["slot_url"], "http://versiond-0:8080")
        self.assertNotIn("private_key_hex", str(seed))
        self.assertEqual(set(fixture.ARTIFACTS), {"5.0.1", "5.0.2"})
        self.assertNotEqual(fixture.OLD_BINARY, fixture.ARTIFACTS["5.0.1"][1])

    def test_old_cache_starts_without_force_override_or_repacked_archive(self):
        document = fixture.composition(copy.deepcopy(self.generated), self.root, "ds502-fixture-unit", "5.0.0-cached")
        catalog = document["services"]["mock-dapi"]["environment"]
        self.assertEqual(catalog["MOCK_DAPI_VERSION_SHA256"], fixture.OLD_ARCHIVE)
        self.assertIn("missing-devshardd-5.0.0.zip", catalog["MOCK_DAPI_VERSION_BINARY"])
        env = document["services"]["versiond-0"]["environment"]
        self.assertFalse(any(key.startswith("VERSIOND_OVERRIDE_") or key == "VERSIOND_FORCE" for key in env))
        self.assertEqual(fixture.seed("5.0.0-cached")["versiond"]["binary_version"], "v5.0.0")

    def test_cache_metadata_binds_actual_executable_and_rejects_drift(self):
        (self.root / "binaries").mkdir()
        binary = self.root / "binaries/devshardd-5.0.0-cached"
        binary.write_bytes(b"offline cache fixture, not a release")
        with self.assertRaisesRegex(ValueError, "checksum"):
            fixture.install_old_cache(self.root)
        with patch.object(fixture, "OLD_BINARY", fixture.digest(binary)):
            fixture.install_old_cache(self.root)
            target = self.root / "data/bin/v5" / fixture.OLD_ARCHIVE
            metadata = json.loads((target / "install.json").read_text())
            self.assertEqual(metadata, {"archive_sha256": fixture.OLD_ARCHIVE, "binary_sha256": fixture.digest(binary)})
            self.assertEqual((target / "devshardd").read_bytes(), binary.read_bytes())
            self.assertFalse(list(self.root.rglob("*.zip")))
            with self.assertRaisesRegex(ValueError, "already exists"):
                fixture.install_old_cache(self.root)

    def test_helper_reuse_checks_source_receipt_and_all_bytes_before_copy(self):
        source = self.root / "source"
        (source / "helpers").mkdir(parents=True)
        target = self.root / "target"
        target.mkdir()
        for name in fixture.HELPERS:
            (source / "helpers" / name).write_bytes(name.encode())
        receipt = {"source": fixture.SOURCE, "source_archive_sha256": "a" * 64,
                   "helpers": {name: fixture.digest(source / "helpers" / name) for name in fixture.HELPERS}}
        fixture.write_json(source / "prepared.json", receipt)
        sha = fixture.digest(source / "prepared.json")
        with self.assertRaisesRegex(ValueError, "receipt hash"):
            fixture.reuse_helpers(source, "0" * 64, target)
        self.assertEqual(fixture.reuse_helpers(source, sha, target), "a" * 64)
        self.assertEqual(sorted(path.name for path in target.iterdir()), sorted(fixture.HELPERS))
        (source / "helpers/mockchain").write_bytes(b"drift")
        with self.assertRaisesRegex(ValueError, "helper checksum"):
            fixture.reuse_helpers(source, sha, target)

    def test_fresh_pair_has_independent_projects_keys_and_empty_storage_bindings(self):
        self.generated["services"]["devshardctl"]["environment"]["DEVSHARD_PRIVATE_KEY"] = "1" * 64
        original = self.render()
        second = copy.deepcopy(self.generated)
        second["services"]["devshardctl"]["environment"]["DEVSHARD_PRIVATE_KEY"] = "2" * 64
        pair = fixture.pair_documents(original, second, self.root, "ds502-fixture-unit")
        self.assertIn("devshardctl", original["services"])
        self.assertNotIn("devshardctl", pair["infra"]["services"])
        self.assertTrue(pair["infra"]["networks"]["fixture"]["internal"])
        self.assertEqual(len({doc["name"] for doc in pair.values()}), 3)
        for name in ("a", "b"):
            service = pair[name]["services"]["gateway"]
            self.assertNotIn("depends_on", service)
            self.assertEqual(service["image"], fixture.GATEWAY)
            self.assertEqual(service["environment"]["DEVSHARDS_JSON"], "[]")
            self.assertNotIn("DEVSHARD_ESCROW_ID", service["environment"])
            self.assertEqual(service["volumes"][0]["source"], str(self.root / ("data/gateway-" + name)))
            self.assertEqual(service["labels"]["org.gonka.test-lab.owner"], pair[name]["name"])
            self.assertEqual(pair[name]["networks"]["fixture"]["name"], pair["infra"]["networks"]["fixture"]["name"])
        for key in ("DEVSHARD_PRIVATE_KEY", "DEVSHARD_ADMIN_API_KEY", "DEVSHARD_API_KEYS"):
            self.assertNotEqual(pair["a"]["services"]["gateway"]["environment"][key],
                                pair["b"]["services"]["gateway"]["environment"][key])
        second["services"]["devshardctl"]["environment"]["DEVSHARD_PRIVATE_KEY"] = "1" * 64
        with self.assertRaisesRegex(ValueError, "identity collision"):
            fixture.pair_documents(original, second, self.root, "ds502-fixture-unit")

    def test_fresh_preparation_does_not_require_legacy_artifacts(self):
        args = SimpleNamespace(archive_502=Path("502.zip"), archive_501=None, old_500=None,
                               initial_version="5.0.2", two_gateways=True)
        self.assertEqual(fixture.preparation_inputs(args), [("5.0.2", Path("502.zip"))])
        args.initial_version = "5.0.0-cached"
        with self.assertRaisesRegex(ValueError, "exact executable"):
            fixture.preparation_inputs(args)
        args.old_500 = Path("500")
        with self.assertRaisesRegex(ValueError, "fresh 5.0.2"):
            fixture.preparation_inputs(args)
        args.two_gateways = False
        args.archive_501 = Path("501.zip")
        self.assertEqual(len(fixture.preparation_inputs(args)), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
