#!/usr/bin/env python3
"""B readiness identity and replay-safe file reconciliation contracts."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


manager = load("readiness_manager", ROOT / "04-ops/gateway-readiness.py")
proxy = load("readiness_proxy", ROOT / "04-ops/edge-node/gateway-admission-proxy.py")


class Readiness(unittest.TestCase):
    def test_phase_preview_approval_staleness_and_unexpected_ssh(self):
        """Mock every reachable SSH/SCP operation and reject other targets."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "phase-gateway-readiness.sh").write_bytes((ROOT / "scripts/phase-gateway-readiness.sh").read_bytes())
            (scripts / "lib.sh").write_text('load_project() { ROOT="$FIXTURE_ROOT"; GDC_NODES=(fixture-B); }\n'
                'topology_contains_node() { [[ "$1" == fixture-B ]]; }\n'
                'die() { echo "$*" >&2; exit 1; }\n')
            bin_dir = root / "bin"
            bin_dir.mkdir()
            mock = '''import json, os, pathlib, sys
args = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name
log = pathlib.Path(os.environ["FIXTURE_ROOT"]) / "calls.jsonl"
with log.open("a") as output: output.write(json.dumps([name, args]) + "\\n")
if name == "scp":
    if len(args) != 4 or args[0] != "-q" or args[-1] != "fixture-B:/srv/dai/ops/gdc-gateway-readiness-fixture/": sys.exit(91)
    sys.exit(0)
if len(args) != 3 or args[:2] != ["-n", "fixture-B"]: sys.exit(92)
command = args[2]
if command == "install -d -m 0700 '/srv/dai/ops/gdc-gateway-readiness-fixture'": sys.exit(0)
prefix = "sudo python3 '/srv/dai/ops/gdc-gateway-readiness-fixture/gateway-readiness.py' "
if not command.startswith(prefix) or "--source /srv/dai/ops/gdc-gateway-readiness-fixture/gateway-admission-proxy.py" not in command: sys.exit(93)
if "--port 18086" not in command or "--native-port 18088" not in command or "--model model" not in command: sys.exit(94)
applied = "--apply" in command
if applied and "--expected-sha256 '" + "a" * 64 + "'" not in command: sys.exit(95)
before = "c" * 64 if os.environ.get("FIXTURE_STALE") else "a" * 64
print(json.dumps(dict(schema="gdc-gateway-readiness/1", gateway="B", applied=applied, before_sha256=before, desired_sha256="b" * 64, delta=["private-service-env"], outcome="PASS")))
'''
            for name in ("ssh", "scp"):
                executable = bin_dir / name
                executable.write_text("#!" + sys.executable + "\n" + mock)
                executable.chmod(0o700)
            environment = {"PATH": str(bin_dir) + os.pathsep + os.defpath, "HOME": str(root / "empty-home"),
                "FIXTURE_ROOT": str(root), "GDC_HOME": str(root / "gdc"), "GDC_RUN_ID": "fixture",
                "GDC_GATEWAY_SETTINGS_TARGETS": json.dumps([{"id": "B", "node": "fixture-B", "port": 18088, "secret_file": "/srv/dai/broker-tests/ds502-b/gateway.env"}]),
                "MODEL_ID": "model", "DEVSHARD_V5_URL": "https://example.invalid/v5.zip", "DEVSHARD_V5_SHA256": "d" * 64}
            def phase(action, **extra):
                return subprocess.run(["bash", str(scripts / "phase-gateway-readiness.sh"), action], env={**environment, **extra}, text=True, capture_output=True)
            preview = phase("preview")
            self.assertEqual(preview.returncode, 0, preview.stderr)
            self.assertNotEqual(phase("preview", GDC_GATEWAY_READINESS_BINARY_SHA256="d" * 64).returncode, 0)
            receipt = root / "gdc/runs/fixture/gateway-readiness/preview.json"
            approval = hashlib.sha256(receipt.read_bytes()).hexdigest()
            denied = phase("apply")
            self.assertNotEqual(denied.returncode, 0)
            self.assertIn("exact preview", denied.stderr)
            stale = phase("apply", GDC_GATEWAY_READINESS_APPROVED_PREVIEW_SHA256=approval, FIXTURE_STALE="1")
            self.assertNotEqual(stale.returncode, 0)
            self.assertIn("changed after preview", stale.stderr)
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            self.assertFalse(any("--apply" in call[-1][-1] for call in calls))
            accepted = phase("apply", GDC_GATEWAY_READINESS_APPROVED_PREVIEW_SHA256=approval)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertTrue(json.loads((receipt.parent / "apply.json").read_text())["applied"])

    def test_model_protocol_freshness_and_recovery(self):
        proxy.READINESS_ONLY = True
        proxy.READINESS_MODEL = "selected-model"
        proxy.SELECTED_GATEWAY_VERSION = "v5"
        contract = {"binary": "https://example.invalid/v5.zip", "sha256": "a" * 64}
        proxy.PROTOCOL_CONTRACTS = {"v5": contract}
        status = {"capacity": {"models": {"selected-model": {"current_weight": 296, "routable": True}, "other": {"current_weight": 100}}},
                  "limiter": {"models": {"selected-model": {"effective_max_concurrent_requests": 1}, "other": {"effective_max_concurrent_requests": 10}}},
                  "devshards": [{"id": "B-owned", "model": "selected-model", "active": True, "phase": "active", "chain_phase": "Inference", "requests_blocked": False, "session_version": "v5"}]}
        sync = {"latest_block_height": "50", "latest_block_time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "catching_up": False}
        params = {"params": {"epoch_params": {"epoch_length": 100, "poc_stage_duration": 2, "poc_exchange_duration": 2, "poc_validation_delay": 2, "poc_validation_duration": 2, "set_new_validators_delay": 2}, "devshard_escrow_params": {"approved_versions": [dict(name="v5", **contract)]}}}
        def get(url, *_):
            return {proxy.STATUS_URL: status, proxy.EPOCH_URL: {"epoch_group_data": {"epoch_index": 7}},
                    proxy.CHAIN_STATUS_URL: {"result": {"sync_info": sync}}, proxy.EPOCH_INFO_URL: {"latest_epoch": {"poc_start_block_height": 0}}, proxy.CHAIN_PARAMS_URL: params}[url]
        with patch.object(proxy, "get_json", get):
            self.assertIsNone(proxy.safe_generation()[1])
            status["limiter"]["models"]["selected-model"]["effective_max_concurrent_requests"] = 0
            self.assertEqual(proxy.safe_generation()[1], "runtime_unavailable")
            status["limiter"]["models"]["selected-model"]["effective_max_concurrent_requests"] = 1
            status["devshards"][0]["session_version"] = "v3"
            self.assertEqual(proxy.safe_generation()[1], "runtime_protocol_mismatch")
            status["devshards"][0]["session_version"] = "v5"
            status["devshards"][0]["requests_blocked"] = True
            self.assertEqual(proxy.safe_generation()[1], "runtime_unavailable")
            status["devshards"][0]["requests_blocked"] = False
            sync["latest_block_time"] = "2000-01-01T00:00:00Z"
            self.assertEqual(proxy.safe_generation()[1], "chain_state_stale")
            sync["latest_block_time"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            sync["latest_block_height"] = "99"
            self.assertEqual(proxy.safe_generation()[1], "poc_fence")
            sync["latest_block_height"] = "50"
            self.assertIsNone(proxy.safe_generation()[1])

    def test_preview_apply_noop_and_stale_fence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            secret = root / "srv/dai/broker-tests/ds502-b/gateway.env"
            secret.parent.mkdir(parents=True)
            secret.write_text("DEVSHARD_ADMIN_API_KEY=private-admin\nDEVSHARD_API_KEYS=devnet_fixture\n")
            files = manager.desired_files(root, ROOT / "04-ops/edge-node/gateway-admission-proxy.py", 18086, 18088, "model", "https://example.invalid/v5.zip", "a" * 64)
            preview = manager.reconcile(root, files)
            self.assertFalse((root / manager.UNIT).exists())
            self.assertNotIn("private-admin", json.dumps(preview))
            with self.assertRaisesRegex(ValueError, "changed after preview"):
                manager.reconcile(root, files, True, "wrong")
            with patch.object(manager.subprocess, "run") as systemctl:
                receipt = manager.reconcile(root, files, True, preview["before_sha256"])
                self.assertTrue(receipt["applied"])
                self.assertEqual(systemctl.call_count, 4)
                systemctl.reset_mock()
                fresh = manager.reconcile(root, files)
                self.assertEqual(fresh["delta"], [])
                self.assertEqual(manager.reconcile(root, files, True, fresh["before_sha256"])["outcome"], "no-change")
                systemctl.assert_not_called()
            self.assertEqual(manager.read_env(root / manager.SCOPE / "admission.env")["GDC_GATEWAY_READINESS_ID"], "B")
            self.assertEqual((root / manager.SCOPE / "admission.env").stat().st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(ValueError, "conflicts"):
                manager.desired_files(root, ROOT / "04-ops/edge-node/gateway-admission-proxy.py", 18083, 18088, "model", "https://example.invalid/v5.zip", "a" * 64)

    def test_symlink_parent_refused_without_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real = root / "retained"
            real.mkdir()
            (root / "srv").symlink_to(real, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                manager.current_state(root, {manager.SCOPE / "admission.env": (b"secret", 0o600)})
            self.assertEqual(list(real.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
