#!/usr/bin/env python3
"""Reader artifact-set selection is explicit and never relaxes running pins."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("reader", Path(__file__).with_name("devshard-502-reader.py"))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ReaderContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.cli = self.root / "inferenced"
        self.cli.write_bytes(b"synthetic-cli-not-runtime-proof")
        self.config = "chain_id: " + r.CHAIN + "\n    next_poc_start_block_height: 100000\nparticipants:\n    - address: gonka1abc\n"
        for name, body in (("config.yaml", self.config), ("compose.json", "{}"),
                           ("compose-a.json", "{}"), ("compose-b.json", "{}")):
            (self.root / name).write_text(body)

    def prepare(self, profile="original"):
        def digest(name):
            return hashlib.sha256((self.root / name).read_bytes()).hexdigest()
        self.prepared = {"two_gateways": True, "initial_version": "5.0.2"}
        self.prepared.update(source="eddae498572a43408232b22f2da25e64d30b9669",
            project="ds502-fixture-aaaaaaaaaaaa", config_sha256=digest("config.yaml"),
            compose_sha256=digest("compose.json"),
            gateway_compose_sha256={name: digest("compose-" + name + ".json") for name in ("a", "b")},
            helpers={name.replace("-", ""): value for name, value in r.HELPER_ARTIFACT_SETS[profile].items()})
        return self.bind()

    def bind(self):
        raw = json.dumps(self.prepared).encode()
        (self.root / "prepared.json").write_bytes(raw)
        digest = hashlib.sha256(raw).hexdigest()
        (self.root / "started.json").write_text(json.dumps({"prepared_sha256": digest}))
        return digest

    def reader(self, digest, **kwargs):
        with patch.object(r, "CLI_HASH", hashlib.sha256(self.cli.read_bytes()).hexdigest()):
            return r.Reader(self.root, digest, self.cli, lambda *args, **fields: None, **kwargs)

    def test_original_default_is_preserved(self):
        reader = self.reader(self.prepare())
        self.assertEqual(reader.helper_artifact_set, "original")
        self.assertEqual(reader.helpers, r.HELPERS)

    def test_new_helper_set_requires_explicit_selection(self):
        digest = self.prepare("eddae498-go1.27.1")
        with self.assertRaisesRegex(ValueError, "artifact set differs"):
            self.reader(digest)
        reader = self.reader(digest, helper_artifact_set="eddae498-go1.27.1")
        self.assertEqual(reader.helpers, r.HELPER_ARTIFACT_SETS["eddae498-go1.27.1"])

    def test_unknown_profile_and_forged_preparation_are_rejected(self):
        digest = self.prepare()
        with self.assertRaisesRegex(ValueError, "unknown qualified"):
            self.reader(digest, helper_artifact_set="accept-any")
        self.prepared["helpers"]["mockchain"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "artifact set differs"):
            self.reader(self.bind())

    def test_selected_helpers_still_require_exact_running_digest(self):
        for profile in r.HELPER_ARTIFACT_SETS:
            reader = self.reader(self.prepare(profile), helper_artifact_set=profile)
            def docker(args, deadline):
                if args[0] == "inspect":
                    return json.dumps({"running": True, "image": "fixture", "owner": reader.project,
                        "scope": "ds502-fixture", "networks": {reader.network: {"IPAddress": "172.18.0.2"}}})
                return "0" * 64 + " /proc/1/exe"
            with patch.object(reader, "docker", docker), self.assertRaisesRegex(ValueError, "running helper differs"):
                reader.inspect("mock-chain", 100)

    def test_started_and_source_binding_cannot_drift(self):
        digest = self.prepare()
        (self.root / "started.json").write_text(json.dumps({"prepared_sha256": "0" * 64}))
        with self.assertRaisesRegex(ValueError, "started fixture binding"):
            self.reader(digest)
        self.prepared["source"] = "0" * 40
        with self.assertRaisesRegex(ValueError, "official-source"):
            self.reader(self.bind())

    def cli_root(self, chain):
        root = self.root / "ds502-fixture-cli"
        root.mkdir()
        campaign = root / "workload-campaign"
        campaign.mkdir()
        bindings = {"chain_id": chain, "creators": {"A": "a", "B": "b"},
                    "spend_caps": {"A": 5000000000, "B": 5000000000}}
        (campaign / "events.jsonl").write_text(json.dumps({"kind": "campaign", "bindings": bindings}) + "\n")
        (root / "prepared.json").write_text(json.dumps({"fresh_inference": True}))
        return root, bindings

    def cli_args(self, root):
        return ["reader", "--root", str(root), "--receipt-sha256", "a" * 64,
                "--inferenced", str(self.cli), "--run", "2"]

    def test_cli_refuses_live_campaign_before_any_runtime_operation(self):
        root, _ = self.cli_root("gonka-devnet-community")
        with patch("sys.argv", self.cli_args(root)), patch.object(r, "Reader") as reader, \
             redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
            self.assertEqual(r.main(), 2)
        reader.assert_not_called()

    def test_cli_keeps_original_campaign_locks_and_runs_once(self):
        root, bindings = self.cli_root(r.CHAIN)
        with patch("sys.argv", self.cli_args(root)), patch.object(r.w, "Campaign") as campaign, \
             patch.object(r, "Reader") as reader, patch.object(r.o, "Collector"), \
             patch.object(r.w, "Runner") as runner, redirect_stdout(io.StringIO()):
            runner.return_value.run.return_value = {"automated_outcome": "PASS"}
            self.assertEqual(r.main(), 0)
            campaign.assert_called_once_with(root / "workload-campaign", bindings,
                [root / "operator-a/.workload.lock", root / "operator-b/.workload.lock"])
            runner.return_value.run.assert_called_once_with(2)
            self.assertEqual(reader.call_args.kwargs["helper_artifact_set"], "original")

    def test_cli_preserves_uncertain_outcome_without_second_run(self):
        root, _ = self.cli_root(r.CHAIN)
        with patch("sys.argv", self.cli_args(root)), patch.object(r.w, "Campaign"), \
             patch.object(r, "Reader"), patch.object(r.o, "Collector"), \
             patch.object(r.w, "Runner") as runner, redirect_stdout(io.StringIO()):
            runner.return_value.run.return_value = {"automated_outcome": "INCONCLUSIVE"}
            self.assertEqual(r.main(), 3)
            runner.return_value.run.assert_called_once_with(2)

    def test_cli_refuses_known_cached_fixture_before_campaign_dispatch(self):
        root, _ = self.cli_root(r.CHAIN)
        (root / "prepared.json").write_text("{}")
        with patch("sys.argv", self.cli_args(root)), patch.object(r.w, "Runner") as runner, \
             redirect_stderr(io.StringIO()):
            self.assertEqual(r.main(), 2)
        runner.assert_not_called()

    def test_fresh_policy_requires_running_container_readback(self):
        reader = self.reader(self.prepare())
        reader.prepared["fresh_inference"] = True
        def docker(args, deadline):
            return json.dumps({"running": True, "image": "fixture", "owner": reader.project + "-a",
                "scope": "ds502-fixture", "networks": {reader.network: {"IPAddress": "172.18.0.2"}}})
        with patch.object(reader, "docker", docker), self.assertRaisesRegex(ValueError, "policy differs"):
            reader.inspect("a-gateway", 100)


if __name__ == "__main__":
    unittest.main()
