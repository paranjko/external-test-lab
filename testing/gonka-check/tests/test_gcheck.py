"""gcheck against a local fake gateway: no request leaves the machine."""

import contextlib
import hashlib
import io
import json
import os
import subprocess
import tempfile
import time
import unittest

from gonka_check import chaincheck, cli
from gonka_check.chain import Chain, epoch_offset, in_fence
from gonka_check.preflight import health_blocker, status_blocker
from gonka_check.summary import SSL_HINT, hints
from gonka_check.record import Recorder
from gonka_check.scheduler import RunLock
from gonka_check.target import ROOT, TargetRefused, check_target, check_url, load_preset
from gonka_check.checks import fence_audit, status_gate
from gonka_check.transport import Client, Reply

from tests.fake_gateway import CHAIN_API, EPOCH_LENGTH, FakeGateway


KEY = "sk-fake-" + "c" * 24


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {name: os.environ.get(name) for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME")}
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "config")
        os.environ["XDG_DATA_HOME"] = os.path.join(self.tmp.name, "data")
        self.config = os.path.join(self.tmp.name, "config", "gonka-check")
        os.makedirs(self.config)
        self.key_file = os.path.join(self.config, "fake.key")
        with open(self.key_file, "w", encoding="utf-8") as handle:
            handle.write(KEY + "\n")
        os.chmod(self.key_file, 0o600)

    def tearDown(self):
        for name, value in self.env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def gcheck(self, fake, *args, **preset_overrides):
        path = os.path.join(self.tmp.name, "preset-%d.json" % time.monotonic_ns())
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(fake.preset(**preset_overrides), handle)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["run", "--preset", path, "--wait", "2"] + list(args))
        self.stderr = err.getvalue()
        summary = None
        if code != 4 or "records" in out.getvalue():
            run_dir = out.getvalue().rsplit("records  ", 1)[1].strip()
            with open(os.path.join(run_dir, "summary.json"), encoding="utf-8") as handle:
                summary = json.load(handle)
        return code, summary

    def verdicts(self, summary):
        return {item["check"]: item["verdict"] for item in summary["verdicts"]}

    def assert_key_only_in_posts(self, fake, summary):
        for request in fake.requests:
            if request["method"] == "POST":
                self.assertEqual(request["authorization"], "Bearer " + KEY)
            else:
                self.assertIsNone(request["authorization"], request["path"])
        for folder, _dirs, files in os.walk(os.path.join(self.tmp.name, "data")):
            for name in files:
                with open(os.path.join(folder, name), encoding="utf-8") as handle:
                    self.assertNotIn(KEY, handle.read(), name)
        with open(os.path.join(summary["run_dir"], "manifest.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
        self.assertEqual(manifest["key_sha256_prefix"], hashlib.sha256(KEY.encode()).hexdigest()[:12])

    def assert_no_forbidden_paths(self, fake):
        for request in fake.requests:
            self.assertFalse(request["path"].startswith(("/status/gateway/", "/v1/admission-status", "/elsewhere")),
                             request["path"])


class DryRun(Harness):
    def test_ready_sends_no_completion(self):
        with FakeGateway() as fake:
            code, summary = self.gcheck(fake, "--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual(summary["overall"], "READY")
        self.assertEqual(fake.posts, [])
        self.assert_no_forbidden_paths(fake)
        self.assert_key_only_in_posts(fake, summary)

    def test_poc_fence_health_is_blocked(self):
        with FakeGateway(health="poc_fence") as fake:
            code, summary = self.gcheck(fake, "--dry-run", "--wait", "0")
        self.assertEqual(code, 3)
        self.assertIn("poc_fence", " ".join(summary["readiness"]["reasons"]))
        self.assertEqual(fake.posts, [])

    def test_confirmation_poc_is_blocked(self):
        with FakeGateway(status="confirmation") as fake:
            code, summary = self.gcheck(fake, "--dry-run", "--wait", "0")
        self.assertEqual(code, 3)
        self.assertIn("CONFIRMATION_POC_GENERATION", " ".join(summary["readiness"]["reasons"]))

    def test_open_key_file_is_blocked(self):
        os.chmod(self.key_file, 0o644)
        with FakeGateway() as fake:
            code, summary = self.gcheck(fake, "--dry-run")
        self.assertEqual(code, 3)
        self.assertIn("key_permissions", " ".join(summary["readiness"]["reasons"]))


class Smoke(Harness):
    def test_ready_gateway_passes_with_two_posts(self):
        with FakeGateway() as fake:
            started_ms = time.time() * 1000
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 0, summary)
        self.assertEqual(self.verdicts(summary), {
            "model_served": "PASS", "canary": "PASS", "floor64": "PASS", "fence_audit": "PASS"})
        self.assertEqual(len(fake.posts), 2)
        for post in fake.posts:
            deadline = int(post["deadline_ms"])
            self.assertGreater(deadline, started_ms + 55000)
            self.assertLess(deadline, post["at"] * 1000 + 61000)
            self.assertEqual(post["body"]["model"], "Qwen/Qwen3-0.6B")
        self.assertGreaterEqual(fake.posts[1]["height"] - fake.posts[0]["height"], 2)
        self.assert_key_only_in_posts(fake, summary)
        self.assert_no_forbidden_paths(fake)
        with open(os.path.join(self.config, "ledger.jsonl"), encoding="utf-8") as handle:
            self.assertEqual(len(handle.readlines()), 2)

    def test_window_and_fence_follow_the_poc_start(self):
        # As the proxy counts since its PoC windows were anchored: height offset 5 is block 40 of the cycle.
        with FakeGateway(offset=5, shift=35) as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 0, summary)
        self.assertEqual(self.verdicts(summary)["fence_audit"], "PASS")
        for post in fake.posts:
            self.assertTrue(29 <= (post["height"] - 35) % EPOCH_LENGTH <= 50, post["height"])

    def test_window_closing_before_the_send_sends_nothing_late(self):
        # The health read lets 10 blocks pass: a slot found late in the window is stale by the send.
        with FakeGateway(offset=25, health_jump=10) as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 0, summary)
        self.assertEqual(len(fake.posts), 2)
        for post in fake.posts:
            self.assertTrue(29 <= post["height"] % EPOCH_LENGTH <= 50, post["height"])

    def test_sends_wait_for_the_window(self):
        with FakeGateway(offset=5) as fake:
            code, _summary = self.gcheck(fake)
        self.assertEqual(code, 0)
        offsets = [post["height"] % EPOCH_LENGTH for post in fake.posts]
        # Found at 29, read again at 30 right before the send.
        self.assertEqual(offsets[0], 30)
        self.assertIn("waiting for send window 29..50", self.stderr)
        self.assertTrue(all(29 <= offset <= 50 for offset in offsets), offsets)

    def test_output_floor_regression_fails(self):
        with FakeGateway(scenario="floor_broken") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 1)
        self.assertEqual(self.verdicts(summary)["floor64"], "FAIL")
        self.assertEqual(self.verdicts(summary)["canary"], "PASS")

    def test_permit_leak_stops_the_run(self):
        with FakeGateway(scenario="leak") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "permit_leak_suspected")
        self.assertEqual(len(fake.posts), 1)

    def test_dispatch_failure_stops_the_run(self):
        with FakeGateway(scenario="dispatch_fail") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "gateway_dispatch_failure")
        self.assertEqual(len(fake.posts), 1)

    def test_reply_without_admission_headers_stops_the_run(self):
        with FakeGateway(scenario="no_proxy") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "no_admission_header")

    def test_redirect_is_not_followed(self):
        with FakeGateway(scenario="redirect") as fake:
            code, _summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(len(fake.posts), 1)
        self.assert_no_forbidden_paths(fake)

    def test_protocol_misconfiguration_stops_at_once(self):
        with FakeGateway(scenario="misconfigured") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "proxy_misconfigured")
        self.assertEqual(self.verdicts(summary)["canary"], "FAIL")
        self.assertEqual(len(fake.posts), 1)

    def test_two_pre_dispatch_rejections_block(self):
        with FakeGateway(scenario="reject") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 3)
        self.assertTrue(summary["guard"]["blocked"])
        self.assertEqual(len(fake.posts), 2)

    def test_spent_epoch_budget_sends_nothing(self):
        with FakeGateway() as fake:
            epoch = fake.epoch()
            with open(os.path.join(self.config, "ledger.jsonl"), "w", encoding="utf-8") as handle:
                for _ in range(4):
                    handle.write(json.dumps({"target": fake.base_url, "epoch": epoch}) + "\n")
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 3)
        self.assertEqual(fake.posts, [])
        self.assertEqual(self.verdicts(summary)["canary"], "BLOCKED")

    def test_busy_lock_sends_nothing(self):
        with FakeGateway() as fake, RunLock(os.path.join(self.config, "run.lock")):
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 3)
        self.assertIn("lock", " ".join(summary["readiness"]["reasons"]))
        self.assertEqual(fake.posts, [])


class ChainProfile(Harness):
    def chain(self, fake):
        os.remove(self.key_file)
        code, summary = self.gcheck(fake, "--profile", "chain")
        self.assertEqual(fake.posts, [])
        self.assertTrue(all(request["authorization"] is None for request in fake.requests))
        self.assert_no_forbidden_paths(fake)
        return code, summary

    def test_healthy_chain_passes_without_a_key(self):
        with FakeGateway() as fake:
            code, summary = self.chain(fake)
        self.assertEqual(code, 0, summary)
        self.assertEqual(self.verdicts(summary), {"chain_advances": "PASS", "nodes_at_tip": "PASS", "epoch_state": "PASS"})

    def test_lagging_and_unreachable_nodes_fail(self):
        with FakeGateway(node_state={1: 10, 2: "down"}, freeze=True) as fake:
            code, summary = self.chain(fake)
        self.assertEqual(code, 1)
        reason = [item["reason"] for item in summary["verdicts"] if item["check"] == "nodes_at_tip"][0]
        self.assertIn("node1: 10 blocks behind", reason)
        self.assertIn("node2: node_unreachable (502)", reason)

    def test_stalled_chain_fails(self):
        with FakeGateway(freeze=True) as fake:
            code, summary = self.chain(fake)
        self.assertEqual(code, 1)
        self.assertEqual(self.verdicts(summary)["chain_advances"], "FAIL")

    def test_epoch_state_accepts_the_previous_group_during_poc(self):
        with FakeGateway(offset=8) as fake:
            code, summary = self.chain(fake)
        self.assertEqual(code, 0, summary)
        reason = [item["reason"] for item in summary["verdicts"] if item["check"] == "epoch_state"][0]
        self.assertIn("group not switched yet", reason)

    def test_epoch_state_reads_approved_versions_from_their_store(self):
        with FakeGateway(approved="store") as fake:
            code, summary = self.chain(fake)
        self.assertEqual(code, 0, summary)
        self.assertEqual(self.verdicts(summary)["epoch_state"], "PASS")

    def test_epoch_state_without_approved_versions_is_inconclusive(self):
        with FakeGateway(approved="none") as fake:
            _code, summary = self.chain(fake)
        self.assertEqual(self.verdicts(summary)["epoch_state"], "INCONCLUSIVE")

    def test_epoch_state_reports_the_confirmation_poc(self):
        with FakeGateway(offset=40, cpoc=(27, 55)) as fake:
            _code, summary = self.chain(fake)
        reason = [item["reason"] for item in summary["verdicts"] if item["check"] == "epoch_state"][0]
        self.assertIn("CONFIRMATION_POC_GENERATION, trigger at offset 27", reason)


class ChainDetails(Harness):
    def reason(self, summary, check):
        return [item["reason"] for item in summary["verdicts"] if item["check"] == check][0]

    def direct_epoch_state(self, fake):
        path = os.path.join(self.tmp.name, "direct.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(fake.preset(), handle)
        preset = load_preset(path)
        return chaincheck.epoch_state(Chain(Client(preset, None), preset))

    def test_key_is_not_read_and_nothing_is_posted(self):
        os.chmod(self.key_file, 0)
        with FakeGateway() as fake:
            code, summary = self.gcheck(fake, "--profile", "chain")
        self.assertEqual(code, 0, summary)
        self.assertEqual(fake.posts, [])
        self.assertTrue(all(r["method"] == "GET" and r["authorization"] is None for r in fake.requests))
        with open(os.path.join(summary["run_dir"], "manifest.json"), encoding="utf-8") as handle:
            self.assertIsNone(json.load(handle)["key_sha256_prefix"])

    def test_catching_up_and_invalid_nodes_fail(self):
        with FakeGateway(node_state={0: "catching", 1: "invalid"}) as fake:
            code, summary = self.gcheck(fake, "--profile", "chain")
        self.assertEqual(code, 1)
        self.assertIn("node0: catching up at", self.reason(summary, "nodes_at_tip"))
        self.assertIn("node1: node_status_invalid", self.reason(summary, "nodes_at_tip"))

    def test_lag_limit_is_inclusive_and_read_from_the_preset(self):
        with FakeGateway(node_state={0: 5, 1: 6}, freeze=True) as fake:
            _code, summary = self.gcheck(fake, "--profile", "chain")
        self.assertIn("node1: 6 blocks behind; at tip:", self.reason(summary, "nodes_at_tip"))
        self.assertNotIn("node0:", self.reason(summary, "nodes_at_tip").split("; at tip:")[0])
        with FakeGateway(node_state={0: 3}, freeze=True) as fake:
            _code, summary = self.gcheck(fake, "--profile", "chain", node_max_lag_blocks=2)
        self.assertEqual(self.verdicts(summary)["nodes_at_tip"], "FAIL")
        self.assertIn("node0: 3 blocks behind", self.reason(summary, "nodes_at_tip"))

    def test_lagging_public_rpc_fails(self):
        with FakeGateway(node_state={0: -20, 1: -20, 2: -20}, freeze=True) as fake:
            code, summary = self.gcheck(fake, "--profile", "chain")
        self.assertEqual(code, 1)
        self.assertIn("public RPC: 20 blocks behind", self.reason(summary, "nodes_at_tip"))

    def test_unreadable_chain_is_inconclusive_not_pass(self):
        with FakeGateway(fail_paths={"/chain-rpc/status"}) as fake:
            _code, summary = self.gcheck(fake, "--profile", "chain")
        verdicts = self.verdicts(summary)
        self.assertEqual(verdicts["chain_advances"], "INCONCLUSIVE")
        self.assertEqual(verdicts["epoch_state"], "INCONCLUSIVE")
        self.assertIn("public RPC: node_unreachable (429)", self.reason(summary, "nodes_at_tip"))
        with FakeGateway() as fake:
            code, summary = self.gcheck(fake, "--profile", "chain", node_rpcs=[])
        self.assertEqual(self.verdicts(summary)["nodes_at_tip"], "INCONCLUSIVE")
        self.assertEqual(code, 2)

    def test_epoch_state_bounds(self):
        with FakeGateway(offset=16) as fake:
            item = self.direct_epoch_state(fake)
        self.assertEqual(item["verdict"], "PASS")
        self.assertIn("group not switched yet", item["reason"])
        with FakeGateway(offset=29, group_switch=40) as fake:
            self.assertEqual(self.direct_epoch_state(fake)["verdict"], "FAIL")
        with FakeGateway(offset=4, cpoc=(0, 20)) as fake:
            self.assertEqual(self.direct_epoch_state(fake)["verdict"], "INCONCLUSIVE")
        with FakeGateway(offset=40, cpoc=(27, 55), cpoc_phase="CONFIRMATION_POC_BOGUS") as fake:
            self.assertEqual(self.direct_epoch_state(fake)["verdict"], "FAIL")

    def test_plan_for_the_chain_profile_sends_nothing(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(cli.main(["plan", "--profile", "chain"]), 0)
        self.assertIn("total    0 POST", out.getvalue())
        self.assertNotIn("key ", out.getvalue())


class WatchMode(Harness):
    def watch(self, fake, *args):
        path = os.path.join(self.tmp.name, "watch-%d.json" % time.monotonic_ns())
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(fake.preset(), handle)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(["watch", "--preset", path, "--interval", "0"] + list(args))
        samples = out.getvalue().rsplit("records  ", 1)[1].strip()
        with open(os.path.join(os.path.dirname(samples), "summary.json"), encoding="utf-8") as handle:
            return code, json.load(handle), samples

    def test_watch_summarises_a_complete_epoch(self):
        os.remove(self.key_file)
        with FakeGateway(offset=60, cpoc=(27, 31)) as fake:
            code, summary, samples = self.watch(fake, "--epochs", "1", "--duration", "60")
        self.assertEqual(code, 0)
        complete = [epoch for epoch in summary["epochs"] if epoch["complete"]]
        self.assertEqual(len(complete), 1)
        self.assertEqual(complete[0]["samples"], 70)
        self.assertEqual(complete[0]["window_samples"], 22)
        self.assertEqual(complete[0]["window_ready"], 19)
        self.assertEqual(complete[0]["confirmation_poc"], {"CONFIRMATION_POC_GENERATION": [27, 31]})
        with open(samples, encoding="utf-8") as handle:
            self.assertEqual(len(handle.readlines()), sum(epoch["samples"] for epoch in summary["epochs"]))
        self.assertEqual(fake.posts, [])
        self.assertTrue(all(request["authorization"] is None for request in fake.requests))
        self.assert_no_forbidden_paths(fake)

    def test_epochs_and_offsets_follow_the_poc_start(self):
        os.remove(self.key_file)
        with FakeGateway(offset=60, shift=35) as fake:
            code, summary, samples = self.watch(fake, "--epochs", "1", "--duration", "60")
        self.assertEqual(code, 0)
        complete = [epoch for epoch in summary["epochs"] if epoch["complete"]]
        self.assertEqual((len(complete), complete[0]["samples"], complete[0]["window_samples"]), (1, 70, 22))
        with open(samples, encoding="utf-8") as handle:
            for sample in map(json.loads, handle):
                self.assertEqual(sample["offset"], (sample["height"] - 35) % EPOCH_LENGTH, sample)

    def test_watch_counts_health_reasons(self):
        with FakeGateway(offset=30, health="timeout") as fake:
            _code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "60")
        self.assertEqual(summary["totals"]["window_ready"], 0)
        self.assertIn("DEGRADED/UNAVAILABLE (connection_timeout)", summary["totals"]["health"])


class WatchDetails(WatchMode):
    def complete(self, summary):
        return [epoch for epoch in summary["epochs"] if epoch["complete"]]

    def test_status_and_chain_event_count_separately(self):
        with FakeGateway(offset=60, cpoc=(29, 33), status_tracks_cpoc=False) as fake:
            _code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        self.assertEqual(self.complete(summary)[0]["window_ready"], 17)
        with FakeGateway(offset=60, status="confirmation") as fake:
            _code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        self.assertEqual(self.complete(summary)[0]["window_ready"], 0)
        self.assertEqual(self.complete(summary)[0]["confirmation_poc"], {})

    def test_unreadable_confirmation_event_blocks(self):
        with FakeGateway(offset=60, fail_paths={CHAIN_API + "/active_confirmation_poc_event"}) as fake:
            _code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        self.assertEqual(self.complete(summary)[0]["window_ready"], 0)

    def test_devnet_phases_and_completed_do_not_block(self):
        with FakeGateway(offset=60, cpoc=(19, 48), devnet_phases=True) as fake:
            _code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        epoch = self.complete(summary)[0]
        self.assertEqual(epoch["confirmation_poc"], {
            "CONFIRMATION_POC_GRACE_PERIOD": [19, 22], "CONFIRMATION_POC_GENERATION": [23, 43],
            "CONFIRMATION_POC_VALIDATION": [44, 47], "CONFIRMATION_POC_COMPLETED": [48, 48]})
        self.assertEqual(epoch["window_ready"], 3)
        self.assertEqual(summary["totals"]["complete_epochs_with_confirmation_poc"], 1)

    def test_coarse_sampling_still_completes_an_epoch(self):
        with FakeGateway(offset=60, step=3) as fake:
            _code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        self.assertEqual([epoch["complete"] for epoch in summary["epochs"]], [False, True, False])
        self.assertTrue(summary["totals"]["goal_reached"])

    def test_first_epoch_is_partial_even_from_its_first_block(self):
        with FakeGateway(offset=69) as fake:
            _code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        self.assertLessEqual(summary["epochs"][0]["max_gap_blocks"], 6)
        self.assertEqual([epoch["complete"] for epoch in summary["epochs"]], [False, True, False])

    def test_public_watch_interval_has_a_floor(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            cli.main(["watch", "--preset", "devnet", "--interval", "0", "--duration", "0"])
        run_dir = os.path.dirname(out.getvalue().rsplit("records  ", 1)[1].strip())
        with open(os.path.join(run_dir, "manifest.json"), encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["interval_s"], 5)

    def test_a_failed_chain_read_is_counted_and_survived(self):
        with FakeGateway(offset=60, chain_fail_offsets={40}) as fake:
            _code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        epoch = self.complete(summary)[0]
        self.assertEqual(epoch["errors"], {"chain_unreachable (429)": 1})
        self.assertEqual(epoch["window_samples"], 21)
        self.assertEqual(summary["totals"]["errors"], {"chain_unreachable (429)": 1})

    def test_no_valid_sample_is_inconclusive(self):
        with FakeGateway(fail_paths={"/chain-rpc/status"}) as fake:
            code, summary, _samples = self.watch(fake, "--duration", "1")
        self.assertEqual(code, 2)
        self.assertGreater(summary["totals"]["samples"], 0)
        self.assertIn("chain_unreachable (429)", summary["totals"]["errors"])

    def test_stale_health_is_one_reason(self):
        with FakeGateway(offset=60, health="stale") as fake:
            _code, summary, samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        self.assertEqual(list(summary["totals"]["health"]), ["stale"])
        with open(samples, encoding="utf-8") as handle:
            self.assertTrue(all(json.loads(line).get("health_age_s", 0) >= 99 for line in handle))

    def test_malformed_status_does_not_stop_the_watch(self):
        with FakeGateway(offset=60, status="badseed") as fake:
            code, summary, _samples = self.watch(fake, "--epochs", "1", "--duration", "30")
        self.assertEqual(code, 0)
        self.assertEqual(summary["totals"]["errors"], {})


class DirectGateway(Harness):
    """A DevShard gateway under a path of the public API: no admission proxy in front of it."""

    def test_smoke_passes_without_the_proxy(self):
        with FakeGateway(prefix="/a") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 0, summary)
        self.assertEqual(self.verdicts(summary), {"model_served": "PASS", "canary": "PASS", "floor64": "PASS",
                                                  "status_gate": "PASS"})
        gate = next(item for item in summary["verdicts"] if item["check"] == "status_gate")
        self.assertEqual(gate["maps"], ["SMK-05"])
        self.assertIn("2 completion(s) after a routable /v1/status", gate["reason"])
        self.assertEqual(summary["target"], fake.base_url + "/a")
        self.assertEqual([post["path"] for post in fake.posts], ["/a/v1/chat/completions"] * 2)
        self.assertFalse(any(request["path"].startswith("/status/") for request in fake.requests))
        self.assert_key_only_in_posts(fake, summary)
        with open(os.path.join(self.config, "ledger.jsonl"), encoding="utf-8") as handle:
            self.assertEqual({json.loads(line)["target"] for line in handle}, {fake.base_url + "/a"})

    def test_dry_run_needs_no_health_receipt(self):
        with FakeGateway(prefix="/a") as fake:
            code, summary = self.gcheck(fake, "--dry-run")
        self.assertEqual(code, 0)
        self.assertNotIn("health", [item["name"] for item in summary["readiness"]["items"]])
        self.assertEqual(fake.posts, [])

    def test_window_follows_the_chain_cycle_not_the_height(self):
        # Cycle starts at offset 35 of the height grid: height offset 5 is block 40 of the cycle.
        with FakeGateway(prefix="/a", offset=5, shift=35) as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 0, summary)
        for post in fake.posts:
            self.assertTrue(29 <= (post["height"] - 35) % EPOCH_LENGTH <= 50, post["height"])
        # Height offset 30 would pass the proxy fence but is block 65 of the cycle.
        with FakeGateway(prefix="/a", offset=30, shift=35, freeze=True) as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(fake.posts, [])
        self.assertEqual(self.verdicts(summary)["canary"], "INCONCLUSIVE")

    def test_gateway_failure_still_stops_the_run(self):
        with FakeGateway(prefix="/a", scenario="dispatch_fail") as fake:
            code, summary = self.gcheck(fake)
        self.assertEqual(code, 4)
        self.assertEqual(summary["guard"]["reason"], "gateway_dispatch_failure")
        self.assertEqual(len(fake.posts), 1)
        self.assertEqual(self.verdicts(summary)["status_gate"], "INCONCLUSIVE")

    def test_watch_reads_only_the_gateway_status(self):
        os.remove(self.key_file)
        with FakeGateway(prefix="/b", offset=60) as fake:
            code, summary, _samples = WatchMode.watch(self, fake, "--epochs", "1", "--duration", "60")
        self.assertEqual(code, 0)
        self.assertEqual(summary["target"], fake.base_url + "/b")
        complete = [epoch for epoch in summary["epochs"] if epoch["complete"]]
        self.assertEqual(complete[0]["window_ready"], complete[0]["window_samples"])
        self.assertIn("/b/v1/status", [request["path"] for request in fake.requests])
        self.assertFalse(any(request["path"].startswith("/status/") for request in fake.requests))


class Evidence(Harness):
    def test_evidence_run_collects_key_free_results(self):
        out = os.path.join(self.tmp.name, "evidence")
        with FakeGateway() as fake:
            smoke = os.path.join(self.tmp.name, "smoke.json")
            with open(smoke, "w", encoding="utf-8") as handle:
                json.dump(fake.preset(), handle)
            result = subprocess.run(
                [os.path.join(ROOT, "scenarios", "smoke-evidence.sh"), "--out", out, "--smoke", smoke,
                 "--chain", smoke, "--key-dir", self.config, "--wait", "30", "--allow-dirty"],
                capture_output=True, text=True, env=dict(os.environ), check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with open(os.path.join(out, "evidence.json"), encoding="utf-8") as handle:
            evidence = json.load(handle)
        self.assertEqual([(run["profile"], run["overall"]) for run in evidence["runs"]],
                         [("dry-run", "READY"), ("smoke", "PASS"), ("chain", "PASS")])
        self.assertEqual(len(fake.posts), 2)
        with open(os.path.join(out, "evidence.md"), encoding="utf-8") as handle:
            self.assertIn("- PASS `canary` SMK-06", handle.read())
        for folder, _dirs, files in os.walk(out):
            for name in files:
                with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as handle:
                    self.assertNotIn(KEY, handle.read(), name)
        manifest = os.path.join(out, "runs", evidence["runs"][1]["run_id"], "manifest.json")
        with open(manifest, encoding="utf-8") as handle:
            self.assertIn("dirty", json.load(handle)["source"])


class Guard(Harness):
    def test_foreign_target_is_refused(self):
        with FakeGateway() as fake:
            preset = fake.preset(base_url="https://example.com",
                                 chain_rpc="https://example.com/chain-rpc",
                                 chain_api="https://example.com/chain-api")
            path = os.path.join(self.tmp.name, "foreign.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(preset, handle)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["run", "--dry-run", "--preset", path]), 4)
            self.assertEqual(fake.requests, [])

    def test_forbidden_path_is_never_requested(self):
        with FakeGateway() as fake:
            path = os.path.join(self.tmp.name, "fake.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(fake.preset(), handle)
            client = Client(load_preset(path), Recorder(os.path.join(self.tmp.name, "run")))
            for forbidden in ("/status/gateway/v1/admission-status", "/v1/admission-status"):
                with self.assertRaises(TargetRefused):
                    client.get(fake.base_url + forbidden)
            with self.assertRaises(ValueError):
                client._send("GET", fake.base_url + "/v1/models", None, KEY, 5, None)
        self.assertEqual(fake.requests, [])

    def test_foreign_node_rpc_is_refused(self):
        preset = load_preset("devnet")
        preset["node_rpcs"] = ["https://node0.example.com/chain-rpc"]
        with self.assertRaises(TargetRefused):
            check_target(preset)

    def test_tricky_node_rpcs_are_refused(self):
        good = "https://node0.gonka-dev.net/chain-rpc"
        for bad in ("https://node0.gonka-dev.net.evil.example/chain-rpc",
                    "https://node0.gonka-dev.net@evil.example/chain-rpc",
                    "http://node0.gonka-dev.net/chain-rpc",
                    good + "\n"):
            preset = load_preset("devnet")
            preset["node_rpcs"] = [good, bad]
            with self.assertRaises(TargetRefused, msg=bad):
                check_target(preset)
        with FakeGateway() as fake:
            with self.assertRaises(TargetRefused):
                check_target(fake.preset(node_rpcs=[good]))

    def test_node_origin_allows_only_its_rpc_path(self):
        preset = load_preset("devnet")
        check_url(preset, "https://node4.gonka-dev.net/chain-rpc/status")
        for path in ("/v1/chat/completions", "/faucet/claim", "/chain-rpcx/status"):
            with self.assertRaises(TargetRefused, msg=path):
                check_url(preset, "https://node4.gonka-dev.net" + path)

    def test_public_target_refuses_fast_polling(self):
        preset = load_preset("devnet")
        preset["chain_poll_s"] = 0
        with self.assertRaises(TargetRefused):
            check_target(preset)

    def test_only_gateways_a_and_b_are_reachable_by_path(self):
        for name in ("devnet-a", "devnet-b"):
            self.assertIsNone(load_preset(name)["health_url"])
        preset = load_preset("devnet-a")
        for path in ("/c", "/a/b", "/A", "a", "/a/"):
            with self.assertRaises(TargetRefused, msg=path):
                check_target(dict(preset, gateway_path=path))
        with self.assertRaises(TargetRefused):
            check_target(dict(preset, health_url="https://gonka-dev.net/status/gateway-health"))
        with self.assertRaises(TargetRefused):
            check_target(dict(load_preset("devnet"), health_url=None))
        check_url(preset, "https://api.gonka-dev.net/a/v1/status")
        for path in ("/a/v1/admin/state", "/a/v1/admin/escrows", "/a/v1/debug/rotation", "/a/v1/finalize",
                     "/v1/admin/devshards"):
            with self.assertRaises(TargetRefused, msg=path):
                check_url(preset, "https://api.gonka-dev.net" + path)

    def test_admin_path_variants_are_refused(self):
        preset = load_preset("devnet-a")
        for path in ("/v1/admin", "/a/v1/admin", "/a/v1/debug", "/b/v1/admin/state", "/a/v1/state",
                     "/a/debug/pprof/heap", "/a/devshard/7/v1/finalize", "/devshard/7/v1/state",
                     "/a/x/../v1/admin/state", "//a//v1/admin", "/a/v1/%61dmin/state"):
            with self.assertRaises(TargetRefused, msg=path):
                check_url(preset, "https://api.gonka-dev.net" + path)
        for path in ("/a/v1/status", "/a/v1/chat/completions", "/a/v1/models", "/a/v1/stateless"):
            check_url(preset, "https://api.gonka-dev.net" + path)

    def test_plan_for_a_gateway_audits_the_status_gate(self):
        result = subprocess.run([os.path.join(ROOT, "bin", "gcheck"), "plan", "--preset", "devnet-a"],
                                capture_output=True, text=True, env=dict(os.environ), check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("target   https://api.gonka-dev.net/a (devnet-a, point gateway A)", result.stdout)
        self.assertIn("total    2 POST", result.stdout)
        self.assertNotIn("fence_audit", result.stdout)
        self.assertIn("status_gate  SMK-05", result.stdout)

    def test_plan_runs_from_bin_without_network(self):
        result = subprocess.run([os.path.join(ROOT, "bin", "gcheck"), "plan"], capture_output=True, text=True,
                                env=dict(os.environ), check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("total    2 POST", result.stdout)


class Rules(unittest.TestCase):
    SINGLE = {"escrow_id": "1", "phase": "active", "requests_blocked": False, "chain_phase": "Inference",
              "confirmation_poc_phase": "CONFIRMATION_POC_INACTIVE", "height_seed": {"state": "ok"}}

    def test_status_rule(self):
        self.assertIsNone(status_blocker(self.SINGLE))
        self.assertIsNone(status_blocker(dict(self.SINGLE, height_seed=None)))
        self.assertEqual(status_blocker(dict(self.SINGLE, height_seed={"state": "missed"})), "height_seed=missed")
        self.assertIn("confirmation_poc_phase", status_blocker(
            dict(self.SINGLE, confirmation_poc_phase="CONFIRMATION_POC_GENERATION")))
        self.assertIn("requests_blocked", status_blocker(dict(self.SINGLE, requests_blocked=True)))
        pooled = {"capacity": {"total_weight": 5}, "devshards": [
            {"active": True, "runtime": {"phase": "active", "requests_blocked": False, "chain_phase": "Inference"}}]}
        self.assertIsNone(status_blocker(pooled))
        pooled["devshards"][0]["runtime"]["requests_blocked"] = True
        self.assertEqual(status_blocker(pooled), "runtime_not_routable")
        pooled["devshards"][0]["runtime"]["requests_blocked"] = False
        for weight in ("abc", [1], {"w": 1}):
            pooled["capacity"] = {"models": {"m": {"current_weight": weight}}}
            self.assertEqual(status_blocker(pooled), "runtime_not_routable", weight)
        pooled["capacity"] = {"models": {"m": {"current_weight": "5"}}}
        self.assertIsNone(status_blocker(pooled))
        self.assertIsNone(status_blocker({"routable": True}))

    def test_offset_outside_the_cycle_is_outside_every_window(self):
        class Cycle:
            def epoch_start(self):
                return 507885, 0
        params = {"epoch_length": 70, "safe_start": 28}
        self.assertEqual(epoch_offset(Cycle(), 507920), 35)
        self.assertEqual(epoch_offset(Cycle(), 507955), 70)
        self.assertEqual(epoch_offset(Cycle(), 507880), -5)
        self.assertTrue(in_fence(35, params))
        self.assertFalse(in_fence(70, params))
        self.assertFalse(in_fence(-5, params))

    def test_fence_audit_fails_a_dispatch_outside_the_fence(self):
        reply = Reply("POST", "http://127.0.0.1/v1/chat/completions")
        reply.status, reply.seq = 200, 5
        reply.gdc = {"admission": "dispatched_once", "admission_id": "a" * 32, "safe_generation": "sha256:" + "0" * 64,
                     "arrival_height": 1060, "permit_height": 1060, "dispatch_height": 1060, "response_height": 1062}
        facts, slot = {"epoch_length": 70, "safe_start": 28}, {"start": 1000}
        self.assertEqual(fence_audit([(reply, slot)], facts)["verdict"], "PASS")
        reply.gdc["dispatch_height"] = 1061
        failed = fence_audit([(reply, slot)], facts)
        self.assertEqual(failed["verdict"], "FAIL")
        self.assertIn("dispatch height 1061 at epoch offset 61, fence 28..60", failed["reason"])

    def test_status_gate_fails_a_send_outside_the_fence(self):
        reply = Reply("POST", "http://127.0.0.1/a/v1/chat/completions")
        reply.status, reply.send_seq, reply.seq = 200, 4, 5
        facts = {"epoch_length": 70, "safe_start": 28}
        inside, outside = {"offset": 35, "status_seq": 3}, {"offset": 65, "status_seq": 3}
        self.assertEqual(status_gate([(reply, inside)], facts)["verdict"], "PASS")
        failed = status_gate([(reply, inside), (reply, outside)], facts)
        self.assertEqual(failed["verdict"], "FAIL")
        self.assertIn("sent at epoch offset 65, fence 28..60", failed["reason"])
        self.assertEqual(status_gate([], facts)["verdict"], "INCONCLUSIVE")

    def test_ssl_failure_gets_a_hint(self):
        failed = {"readiness": {"reasons": ["chain: chain_unreachable (SSLCertVerificationError: "
                                            "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed)"]},
                  "verdicts": []}
        self.assertEqual(hints(failed), [SSL_HINT])
        self.assertEqual(hints({"readiness": {"reasons": ["key: key_missing"]}, "verdicts": []}), [])

    def test_health_rule(self):
        now = time.time()
        receipt = {"state": "READY", "readiness": "TRAFFIC_READY", "admission": "dispatched_once",
                   "admission_id": "a" * 32, "safe_generation": "sha256:" + "0" * 64,
                   "arrival_height": 10, "permit_height": 10, "dispatch_height": 11, "response_height": 12,
                   "completion_finished_ms": int(now * 1000),
                   "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))}
        self.assertIsNone(health_blocker(receipt, 30, now))
        self.assertIn("stale", health_blocker(receipt, 30, now + 60))
        self.assertIn("malformed", health_blocker(dict(receipt, admission_id="xyz"), 30, now))
        self.assertIn("order", health_blocker(dict(receipt, dispatch_height=9), 30, now))
        self.assertIn("UNAVAILABLE", health_blocker(dict(receipt, readiness="UNAVAILABLE"), 30, now))


if __name__ == "__main__":
    unittest.main()
