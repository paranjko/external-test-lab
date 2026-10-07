#!/usr/bin/env python3
"""Existing native configuration preview never reads credentials or applies."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("cache_policy", Path(__file__).resolve().parents[1] / "04-ops/devshard-cache-policy.py")
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)


class CachePolicyContracts(unittest.TestCase):
    def document(self, identity):
        return {"name": "gdc-ds502-" + identity.lower(), "unknown": {"preserve": [True, "é"]},
                "services": {"gateway": {"image": p.instances.IMAGE, "platform": "linux/amd64",
                    "labels": {"org.gonka.test-lab.scope": "two-gateways", "org.gonka.test-lab.instance": identity},
                    "volumes": ["state:/root/.devshardctl"], "env_file": ["/private/gateway.env"],
                    "environment": {"DEVSHARD_CHAIN_ID": "gonka-devnet-community", "DEVSHARD_ROUTE_PREFIX": "/devshard/v5",
                                    "unrelated": "preserve", "DEVSHARD_ESCROW_ROTATION_ENABLED": "true"}}},
                "volumes": {"state": {"name": "gdc-ds502-" + identity.lower() + "-data"}}}

    def preview(self, document, identity="A", expected=None):
        raw = json.dumps(document, separators=(",", ":")).encode()
        return p.preview(raw, identity, expected or hashlib.sha256(raw).hexdigest())

    def test_only_cache_field_changes_in_both_native_instances(self):
        for identity in ("A", "B"):
            source = self.document(identity)
            saved = copy.deepcopy(source)
            receipt, raw = self.preview(source, identity)
            actual = json.loads(raw)
            self.assertEqual(actual["services"]["gateway"]["environment"].pop(p.instances.CHAT_CACHE_KEY), "1")
            self.assertEqual(actual, source)
            self.assertEqual(source, saved)
            self.assertFalse(receipt["applied"])
            self.assertTrue(receipt["requires_drain_restart"])
            self.assertEqual(receipt["desired_sha256"], hashlib.sha256(raw).hexdigest())

    def test_noop_retains_original_bytes_and_requires_no_restart(self):
        document = self.document("A")
        document["services"]["gateway"]["environment"][p.instances.CHAT_CACHE_KEY] = "1"
        original = json.dumps(document, separators=(",", ":")).encode()
        receipt, raw = self.preview(document)
        self.assertEqual(raw, original)
        self.assertEqual(receipt["before_sha256"], receipt["desired_sha256"])
        self.assertEqual(receipt["delta"], [])
        self.assertFalse(receipt["requires_drain_restart"])

    def test_stale_or_ambiguous_json_is_refused(self):
        with self.assertRaisesRegex(ValueError, "stale"):
            self.preview(self.document("A"), expected="0" * 64)
        raw = b'{"services":{},"services":{}}'
        with self.assertRaisesRegex(ValueError, "duplicate"):
            p.preview(raw, "A", hashlib.sha256(raw).hexdigest())

    def test_unknown_layout_image_identity_state_and_inline_secrets_are_refused(self):
        mutations = [
            lambda d: d["services"].update(other={}),
            lambda d: d["services"]["gateway"].update(image="unqualified:image"),
            lambda d: d["services"]["gateway"]["labels"].update({"org.gonka.test-lab.instance": "B"}),
            lambda d: d["volumes"]["state"].update(name="other-volume"),
            lambda d: d["services"]["gateway"].update(command="alternate-process"),
            lambda d: d["services"]["gateway"]["environment"].update(DEVSHARD_PRIVATE_KEY="synthetic-secret"),
            lambda d: d["services"]["gateway"]["environment"].update(DEVSHARD_ROUTE_PREFIX="/devshard/v4"),
        ]
        for mutation in mutations:
            document = self.document("A")
            mutation(document)
            with self.assertRaises(ValueError):
                self.preview(document)


class LauncherContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.source = Path(__file__).resolve().parents[1]
        self.phase = scripts / "phase-gateway-settings.sh"
        shutil.copyfile(self.source / "scripts/phase-gateway-settings.sh", self.phase)
        (scripts / "lib.sh").write_text('load_project() { ROOT="$GDC_TEST_ROOT"; }\n'
            'topology_contains_node() { [[ "$1" == gdc-node0 || "$1" == gdc-node4 ]]; }\n'
            'die() { printf "%s\\n" "$*" >&2; exit 2; }\n')
        self.log = self.root / "calls.jsonl"
        wrapper = '''#!/usr/bin/env python3
import json, os, re, shlex, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["GDC_TEST_LOG"], "a") as stream:
    stream.write(json.dumps([name, args]) + "\\n")
stage = "/srv/dai/ops/gdc-gateway-settings-test"
if name == "scp":
    root = os.environ["GDC_TEST_ROOT"]
    allowed = []
    for node in ("gdc-node0", "gdc-node4"):
        allowed.extend([
            ["-q", root + "/04-ops/devshard-settings.py", root + "/04-ops/devshard-instances.py", node + ":" + stage + "/04-ops/"],
            ["-q", root + "/scripts/devshard-preview.py", node + ":" + stage + "/scripts/"],
            ["-q", root + "/04-ops/devshard-cache-policy.py", node + ":" + stage + "/04-ops/"],
        ])
    if args not in allowed:
        sys.exit(99)
elif name == "ssh" and len(args) == 3 and args[:2] in (["-n", "gdc-node0"], ["-n", "gdc-node4"]):
    command = args[2]
    identity = "A" if args[1] == "gdc-node4" else "B"
    path = "/srv/dai/broker-tests/ds502-" + identity.lower() + "/compose.json"
    install = "install -d -m 0700 '" + stage + "/04-ops' '" + stage + "/scripts'"
    chmod = "chmod 0700 '" + stage + "/04-ops/'*.py '" + stage + "/scripts/'*.py"
    digest = "test ! -L '" + path + "' && test \\\"$(readlink -f '" + path + "')\\\" = '" + path + "' && sha256sum '" + path + "'"
    if command in (install, chmod):
        pass
    elif command == digest:
        print("a" * 64 + "  " + path)
    elif shlex.split(command) == ["python3", stage + "/04-ops/devshard-cache-policy.py", "--compose", path,
                                  "--id", identity, "--expected-sha256", "a" * 64]:
        words = shlex.split(command)
        identity = words[words.index("--id") + 1]
        path = words[words.index("--compose") + 1]
        expected = words[words.index("--expected-sha256") + 1]
        if identity not in ("A", "B") or path != "/srv/dai/broker-tests/ds502-" + identity.lower() + "/compose.json" or expected != "a" * 64:
            sys.exit(99)
        print(json.dumps({"schema":"gdc-devshard-cache-policy/1", "id":identity, "applied":False,
            "before_sha256":("0" if os.environ.get("GDC_TEST_STALE") else "a") * 64,
            "desired_sha256":"b" * 64, "delta":[{"field":"DEVSHARD_CHAT_CACHE_MAX_BYTES", "after":"1"}]}))
    else:
        sys.exit(99)
else:
    sys.exit(99)
'''
        for name in ("ssh", "scp", "curl"):
            file = self.bin / name
            file.write_text(wrapper)
            file.chmod(0o755)
        self.targets = [{"id":identity, "node":node, "port":port,
                         "secret_file":"/srv/dai/broker-tests/ds502-" + identity.lower() + "/gateway.env"}
                        for identity, node, port in (("A", "gdc-node4", 18087), ("B", "gdc-node0", 18088))]

    def run_phase(self, action="preview", **extra):
        env = {"PATH":str(self.bin) + ":" + os.environ["PATH"], "HOME":str(self.root),
               "GDC_TEST_ROOT":str(self.source), "GDC_TEST_LOG":str(self.log),
               "GDC_HOME":str(self.root / "gdc"), "GDC_RUN_ID":"test",
               "GDC_GATEWAY_SETTINGS_POLICY":"fresh-inference",
               "GDC_GATEWAY_SETTINGS_TARGETS":json.dumps(self.targets)}
        env.update(extra)
        return subprocess.run(["bash", str(self.phase), action], env=env, text=True, capture_output=True)

    def test_both_native_previews_retain_private_receipts_without_admin_or_apply(self):
        result = self.run_phase()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipts = list((self.root / "gdc/runs/test/gateway-cache-preview").glob("*.json"))
        self.assertEqual(len(receipts), 2)
        self.assertTrue(all(file.stat().st_mode & 0o777 == 0o600 for file in receipts))
        calls = self.log.read_text()
        self.assertNotIn("/v1/admin", calls)
        self.assertNotIn("docker", calls)
        self.assertNotIn("curl", calls)

    def test_apply_or_unknown_policy_refuses_before_transport(self):
        for action, extra in (("apply", {}), ("preview", {"GDC_GATEWAY_SETTINGS_POLICY":"unknown"})):
            self.assertNotEqual(self.run_phase(action, **extra).returncode, 0)
            self.assertFalse(self.log.exists())

    def test_new_scope_is_refused_before_transport(self):
        self.targets[0]["id"] = "S"
        self.assertNotEqual(self.run_phase().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_stale_preview_receipt_is_refused_without_apply(self):
        result = self.run_phase(GDC_TEST_STALE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("receipt is invalid", result.stderr)
        self.assertNotIn("docker", self.log.read_text())

    def test_unexpected_remote_operation_is_rejected(self):
        source = self.phase.read_text()
        anchor = "install -d -m 0700 '$stage/04-ops' '$stage/scripts'"
        self.assertEqual(source.count(anchor), 1)
        self.phase.write_text(source.replace(anchor, anchor + "; unexpected-operation"))
        self.assertEqual(self.run_phase().returncode, 99)


if __name__ == "__main__":
    unittest.main()
