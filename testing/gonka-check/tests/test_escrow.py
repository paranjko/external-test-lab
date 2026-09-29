"""gcheck escrow against a local fake chain fed by recorded mainnet reads: no request leaves the machine."""

import contextlib
import copy
import glob
import hashlib
import io
import json
import math
import os
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ElementTree

from gonka_check import cli, source
from gonka_check.escrow import evaluate
from gonka_check.escrow.slots import escrow_owner, select_slots, slot_value, sorted_entries
from gonka_check.escrow.snapshot import API, load_snapshot, write_snapshot
from gonka_check.scheduler import RunLock
from gonka_check.source import RequestCapReached, SourceClient, resolve
from gonka_check.target import ROOT, TargetRefused, config_dir

from tests.fake_chain import FakeChain, load_fixture

MM, DS, GLM = "MiniMaxAI/MiniMax-M2.7", "deepseek-ai/DeepSeek-V4-Flash-0731", "zai-org/GLM-5.3-Flash"


def weights_of(group):
    return {item["member_address"]: int(item["weight"]) for item in group["validation_weights"]}


def fixture_snapshot():
    """The fixture as a snapshot, without the network."""
    data = load_fixture()
    models = {model: {"total_weight": int(group["total_weight"]), "weights": weights_of(group),
                      "dropped_non_positive": 0} for model, group in data["models"].items()}
    escrows = {}
    for escrow in data["escrows"]:
        members = sorted(models[escrow["model_id"]]["weights"], key=str.encode)
        escrows.setdefault(escrow["model_id"], []).append(
            [int(escrow["id"]), escrow["app_hash"], [members.index(address) for address in escrow["slots"]]])
    return {"format": 1, "taken_at": "fixture", "chain": {"version": "v0.2.15", "commit": "4d687ed6782b"},
            "epoch": 408, "epoch_end": 408, "latest_epoch_start": 408, "epoch_length": 15391, "height_start": 1,
            "height_end": 2, "group_size": 16, "poc_start": 0,
            "root": {"total_weight": int(data["root"]["total_weight"]),
                     "members": sorted(weights_of(data["root"]), key=str.encode)},
            "models": models, "excluded": [{"address": item["address"], "reason": item["reason"], "height": 0}
                                           for item in data["excluded"]],
            "escrows": escrows, "escrow_range": [99448, 99459], "escrows_indexed": 12, "escrows_missing": [],
            "escrows_failed": [], "escrows_other_epoch": [], "escrow_ids_given": False}


class EscrowHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {name: os.environ.get(name) for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME")}
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "config")
        os.environ["XDG_DATA_HOME"] = os.path.join(self.tmp.name, "data")
        self.backoff = source.BACKOFF_S
        source.BACKOFF_S = (0.01, 0.01, 0.01, 0.01)

    def tearDown(self):
        source.BACKOFF_S = self.backoff
        for name, value in self.env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def gcheck(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(args))
        self.out, self.err = out.getvalue(), err.getvalue()
        return code

    def snapshot(self, fake, *extra):
        code = self.gcheck("escrow", "snapshot", "--source", fake.url, *extra)
        runs = glob.glob(os.path.join(self.tmp.name, "data", "gonka-check", "runs", "*"))
        return code, max(runs, key=os.path.getmtime) if runs else None

    def summary(self, run_dir):
        with open(os.path.join(run_dir, "summary.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def write_fixture_snapshot(self, snap=None):
        path = os.path.join(self.tmp.name, "snapshot.json")
        write_snapshot(path, snap or fixture_snapshot())
        return path


class PortTests(unittest.TestCase):
    def test_port_reproduces_recorded_mainnet_escrows(self):
        data = load_fixture()
        for escrow in data["escrows"] + data["boundary_escrows"]:
            entries, total = sorted_entries(weights_of(data["models"][escrow["model_id"]]))
            slots = select_slots(escrow["app_hash"], escrow_owner(int(escrow["id"])), escrow["model_id"],
                                 entries, total, len(escrow["slots"]))
            self.assertEqual(slots, escrow["slots"], escrow["id"])

    def test_draw_equal_to_a_cumulative_weight_goes_to_the_next_member(self):
        entries, total = sorted_entries({"a": 1, "b": 1})
        slots = select_slots("00", "o", "m", entries, total, 32)
        self.assertEqual(slots, ["a" if slot_value("00", "o", "m", i, 2) == 0 else "b" for i in range(32)])

    def test_larger_group_extends_the_same_draw(self):
        entries, total = sorted_entries(weights_of(load_fixture()["models"][MM]))
        small = select_slots("ab" * 20, escrow_owner(7), MM, entries, total, 32)
        large = select_slots("ab" * 20, escrow_owner(7), MM, entries, total, 64)
        self.assertEqual(large[:32], small)

    def test_entries_sort_by_bytes_and_skip_non_positive(self):
        entries, total = sorted_entries({"gonka1b": 5, "gonka1B": 3, "gonka1a": 0, "gonka1c": -1})
        self.assertEqual(entries, [("gonka1B", 3), ("gonka1b", 5)])
        self.assertEqual(total, 8)

    def test_simulation_pins_the_lightest_minimax_member(self):
        # Fixed seeds: the counts are exact; the formula 1-(1-p)^G gives about 13, 26 and 52.
        rows = evaluate.simulate(fixture_snapshot(), [16, 32, 64], 1000)
        lightest = [row for row in rows if row["model"] == MM and row["address"].endswith("gjz0qxy")]
        self.assertEqual([row["included"] for row in lightest], [14, 29, 52])
        row = lightest[0]
        self.assertEqual((row["slots"], row["max_slots_in_one_escrow"]), (15, 2))
        self.assertAlmostEqual(row["slot_share_ratio"], 1.133, places=3)
        self.assertAlmostEqual(row["work_share_when_included"], 15 / 14 / 16)
        self.assertAlmostEqual(row["overload_when_included"], 80.94, places=2)
        self.assertEqual([r["weight"] for r in evaluate.lightest(rows, MM, 16)], [1262, 2959, 4738, 4738, 5341, 5427])
        self.assertEqual([len(evaluate.lightest(rows, model, 16)) for model in (MM, DS, GLM)], [6, 2, 1])

    def test_simulation_skips_non_positive_weights(self):
        rows = evaluate.simulate({"models": {"m": {"weights": {"gonka1a": 3, "gonka1b": 0}}}}, [4], 10)
        self.assertEqual({row["address"] for row in rows}, {"gonka1a"})


class EvaluateTests(unittest.TestCase):
    def test_weights_fail_when_the_sum_differs(self):
        snap = fixture_snapshot()
        snap["models"][MM]["total_weight"] += 1
        self.assertEqual(evaluate.check_weights(snap)["verdict"], "FAIL")

    def test_simulation_checks_wait_for_the_replay(self):
        verdicts = evaluate.check_simulation([], 20, {"verdict": "INCONCLUSIVE"})
        self.assertEqual([v["verdict"] for v in verdicts], ["INCONCLUSIVE", "INCONCLUSIVE"])

    def test_bands_fail_outside_five_sigma(self):
        runs, size = 200, 16
        rows = evaluate.simulate(fixture_snapshot(), [size], runs)
        passed = {"verdict": "PASS"}
        self.assertEqual([v["verdict"] for v in evaluate.check_simulation(rows, runs, passed)], ["PASS", "PASS"])
        heavy = sorted((row for row in rows if row["model"] == MM), key=lambda row: -row["weight"])
        shifted = copy.deepcopy(rows)
        a = next(row for row in shifted if row["address"] == heavy[0]["address"] and row["model"] == MM)
        b = next(row for row in shifted if row["address"] == heavy[1]["address"] and row["model"] == MM)
        p = a["weight_share"]
        target = math.floor(runs * size * p + 5 * math.sqrt(runs * size * p * (1 - p))) + 2
        b["slots"] -= target - a["slots"]
        a["slots"] = target
        self.assertIn("outside the band", evaluate.check_simulation(shifted, runs, passed)[0]["reason"])
        lost = copy.deepcopy(rows)
        lost[0]["slots"] -= 1
        self.assertIn("slot totals wrong", evaluate.check_simulation(lost, runs, passed)[0]["reason"])
        light = copy.deepcopy(rows)
        row = min((r for r in light if r["model"] == MM), key=lambda r: r["weight"])
        q = 1 - (1 - row["weight_share"]) ** size
        row["included"] = math.floor(runs * q + 5 * math.sqrt(runs * q * (1 - q))) + 2
        self.assertEqual(evaluate.check_simulation(light, runs, passed)[1]["verdict"], "FAIL")

    def test_address_summary_uses_the_escrow_mix(self):
        snap = fixture_snapshot()
        result = evaluate.evaluate(snap, [16, 32], 100, 10)
        self.assertEqual(result["mix"], {MM: 4 / 12, DS: 5 / 12, GLM: 3 / 12})
        weights = snap["models"][DS]["weights"]
        only_ds = [a for a in weights if not any(a in snap["models"][m]["weights"] for m in (MM, GLM))]
        self.assertTrue(only_ds)
        for entry in result["addresses"]:
            if entry["address"] in only_ds:
                expected = 5 / 12 * weights[entry["address"]] / sum(weights.values())
                self.assertAlmostEqual(entry["expected_share"], expected)
        self.assertEqual({e["address"] for e in result["addresses"]}, set(snap["root"]["members"]))
        self.assertEqual({e["address"] for e in result["addresses"] if e["excluded"]},
                         {item["address"] for item in snap["excluded"]})
        for size in (16, 32):
            self.assertAlmostEqual(sum(e["share_of_slots"] for e in result["addresses"] if e["G"] == size), 1.0)

    def test_escrow_gaps_are_inconclusive_unless_ids_were_given(self):
        snap = fixture_snapshot()
        self.assertEqual(evaluate.check_escrows(snap)["verdict"], "PASS")
        snap["escrows_missing"] = [99450]
        self.assertEqual(evaluate.check_escrows(snap)["verdict"], "INCONCLUSIVE")
        snap["escrow_ids_given"] = True
        self.assertEqual(evaluate.check_escrows(snap)["verdict"], "PASS")


class SourceTests(unittest.TestCase):
    def test_only_named_sources_or_loopback(self):
        self.assertEqual(resolve("mainnet"), ("mainnet", "https://node3.gonka.ai", 1.0))
        self.assertEqual(resolve("devnet"), ("devnet", "https://api.gonka-dev.net", 2.0))
        self.assertEqual(resolve("http://127.0.0.1:8080")[1], "http://127.0.0.1:8080")
        for bad in ("https://node3.gonka.ai.evil.example", "http://node3.gonka.ai", "https://node3.gonka.ai",
                    "http://user@127.0.0.1:8080", "http://127.0.0.1:8080/chain-api", "https://api.gonka-dev.net:8443",
                    "testnet"):
            with self.assertRaises(TargetRefused, msg=bad):
                resolve(bad)

    def test_only_chain_paths(self):
        client = SourceClient("https://node3.gonka.ai", 1.0, None, 10)
        self.assertEqual(client.url("/chain-api/x"), "https://node3.gonka.ai/chain-api/x")
        for bad in ("/v1/chat/completions", "/chain-api/../v1/models", "/chain-api/%2e%2e/status/gateway/x",
                    "/chain-rpc/.%2e/v1/admission-status", "@evil.example/chain-api/x", ".evil.example/chain-api/x"):
            with self.assertRaises(TargetRefused, msg=bad):
                client.url(bad)
        self.assertFalse(hasattr(client, "post"))

    def test_requests_are_paced(self):
        with FakeChain() as fake:
            client = SourceClient(fake.url, 0.2, None, 10)
            started = time.monotonic()
            for _ in range(3):
                client.get(API + "/params")
        self.assertGreaterEqual(time.monotonic() - started, 0.4)

    def test_retries_count_against_the_cap(self):
        with FakeChain(busy_first=50) as fake:
            client = SourceClient(fake.url, 0, None, 3, backoff_s=(0, 0, 0, 0))
            with self.assertRaises(RequestCapReached):
                client.get(API + "/params")
        self.assertEqual(len(fake.requests), 3)
        with FakeChain(busy_first=50) as fake:
            client = SourceClient(fake.url, 0, None, 10, backoff_s=(0, 0))
            reply = client.get(API + "/params")
        self.assertEqual((reply.status, client.requests, client.retries), (503, 3, 2))

    def test_a_retry_waits_for_its_backoff(self):
        with FakeChain(busy_first=1) as fake:
            client = SourceClient(fake.url, 0, None, 10, backoff_s=(0.3,))
            started = time.monotonic()
            reply = client.get(API + "/params")
        self.assertEqual((reply.status, client.retries), (200, 1))
        self.assertGreaterEqual(time.monotonic() - started, 0.3)

    def test_gcheck_run_still_refuses_a_mainnet_preset(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(ROOT, "presets", "devnet.json"), encoding="utf-8") as handle:
                preset = json.load(handle)
            base = "https://node3.gonka.ai"
            preset.update(base_url=base, chain_rpc=base + "/chain-rpc", chain_api=base + "/chain-api/x",
                          health_url=base + "/status")
            path = os.path.join(tmp, "mainnet.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(preset, handle)
            err = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                code = cli.main(["run", "--preset", path, "--dry-run"])
        self.assertEqual(code, 4)
        self.assertIn("not an allowed public gateway", err.getvalue())


class SnapshotTests(EscrowHarness):
    def test_snapshot_reads_the_epoch_with_get_only(self):
        with FakeChain() as fake:
            code, run_dir = self.snapshot(fake)
        self.assertEqual(code, 0, self.out + self.err)
        snap, _ = load_snapshot(run_dir)
        self.assertEqual(snap["epoch"], 408)
        self.assertEqual(sorted(snap["models"]), sorted(fake.data["models"]))
        self.assertEqual(sum(len(items) for items in snap["escrows"].values()), 12)
        self.assertEqual(snap["escrow_range"], [99448, 99459])
        self.assertEqual(self.summary(run_dir)["overall"], "PASS")
        self.assertIn("overall  PASS (exit 0)", self.out)
        self.assertEqual({request["method"] for request in fake.requests}, {"GET"})
        self.assertTrue(all(request["authorization"] is None for request in fake.requests))
        with open(os.path.join(run_dir, "chain.jsonl"), encoding="utf-8") as handle:
            kinds = {json.loads(line)["kind"] for line in handle}
        self.assertTrue({"current_epoch", "epoch_info", "params", "epoch_group", "escrow", "tx_search"} <= kinds)

    def test_the_next_epochs_poc_does_not_move_the_snapshot(self):
        with FakeChain(poc_ahead=True) as fake:
            code, run_dir = self.snapshot(fake)
        self.assertEqual(code, 0, self.out + self.err)
        snap, _ = load_snapshot(run_dir)
        self.assertEqual((snap["epoch"], snap["latest_epoch_start"]), (408, 409))
        self.assertEqual(sum(len(items) for items in snap["escrows"].values()), 12)
        with FakeChain(poc_ahead=True) as fake:
            self.assertEqual(self.gcheck("escrow", "snapshot", "--source", fake.url, "--dry-run"), 0)
        self.assertIn("PoC of epoch 409 is running", self.out)

    def test_busy_answers_are_retried(self):
        with FakeChain(busy_first=3) as fake:
            code, run_dir = self.snapshot(fake)
        self.assertEqual(code, 0, self.out + self.err)
        self.assertGreaterEqual(self.summary(run_dir)["retries"], 3)

    def test_an_effective_epoch_change_makes_the_snapshot_inconclusive(self):
        with FakeChain(epoch_switch_after=1) as fake:
            code, run_dir = self.snapshot(fake)
        self.assertEqual(code, 2)
        self.assertIn("effective epoch changed", self.summary(run_dir)["verdicts"][0]["reason"])

    def test_a_small_cap_keeps_the_weights_and_says_why(self):
        with FakeChain() as fake:
            code, run_dir = self.snapshot(fake, "--max-requests", "12")
        self.assertEqual(code, 2)
        snap, _ = load_snapshot(run_dir)
        self.assertEqual(len(snap["models"]), 3)
        self.assertIn("pass --last N", snap["stopped"])
        self.assertLessEqual(len(fake.requests), 12)

    def test_three_failed_escrow_reads_in_a_row_stop_but_keep_the_snapshot(self):
        with FakeChain(fail_paths=("/devshard_escrow/",)) as fake:
            code, run_dir = self.snapshot(fake)
        self.assertEqual(code, 2)
        snap, _ = load_snapshot(run_dir)
        self.assertEqual(snap["escrows_failed"], [99448, 99449, 99450])
        self.assertIn("3 escrow reads in a row failed", snap["stopped"])
        self.assertEqual(sum("/devshard_escrow/" in request["path"] for request in fake.requests), 3)

    def test_scattered_failures_are_kept_and_reported(self):
        failing = ("/devshard_escrow/99449", "/devshard_escrow/99451", "/devshard_escrow/99453")
        with FakeChain(fail_paths=failing) as fake:
            code, run_dir = self.snapshot(fake)
        self.assertEqual(code, 2)
        snap, _ = load_snapshot(run_dir)
        self.assertEqual(snap["escrows_failed"], [99449, 99451, 99453])
        self.assertNotIn("stopped", snap)
        self.assertEqual(sum(len(items) for items in snap["escrows"].values()), 9)

    def test_found_false_and_other_epochs_and_last(self):
        with FakeChain() as fake:
            fake.data["escrows"][0]["epoch_index"] = "407"
            code, run_dir = self.snapshot(fake, "--escrow-ids", "99446-99459")
        self.assertEqual(code, 0, self.out + self.err)
        snap, _ = load_snapshot(run_dir)
        self.assertEqual(snap["escrows_missing"], [99446, 99447])
        self.assertEqual(snap["escrows_other_epoch"], [99448])
        self.assertEqual(sum(len(items) for items in snap["escrows"].values()), 11)
        with FakeChain() as fake:
            code, run_dir = self.snapshot(fake, "--last", "5")
        snap, _ = load_snapshot(run_dir)
        self.assertEqual((snap["escrow_range"], sum(len(items) for items in snap["escrows"].values())),
                         ([99455, 99459], 5))

    def test_base64_events(self):
        with FakeChain(base64_events=True) as fake:
            code, run_dir = self.snapshot(fake)
        self.assertEqual(code, 0, self.out + self.err)
        self.assertEqual(load_snapshot(run_dir)[0]["escrow_range"], [99448, 99459])

    def test_group_bodies_larger_than_the_record_limit_are_kept(self):
        with FakeChain(extra_members=500) as fake:
            code, run_dir = self.snapshot(fake)
        self.assertEqual(code, 0, self.out + self.err)
        with open(os.path.join(run_dir, "chain.jsonl"), encoding="utf-8") as handle:
            groups = [json.loads(line) for line in handle]
        body = next(e["body"] for e in groups if e["kind"] == "epoch_group" and e["key"] == MM)
        self.assertEqual(len(body["epoch_group_data"]["validation_weights"]), 521)
        with open(os.path.join(run_dir, "records.jsonl"), encoding="utf-8") as handle:
            records = [json.loads(line) for line in handle]
        self.assertTrue(any(r.get("path", "").endswith("/epoch_group_data/408") and r.get("body") is None
                            for r in records))
        out = os.path.join(self.tmp.name, "report")
        self.assertEqual(self.gcheck("escrow", "report", run_dir, "--min-escrows", "10", "--runs", "50",
                                     "--out", out), 0, self.out)

    def test_dry_run(self):
        with FakeChain() as fake:
            self.assertEqual(self.gcheck("escrow", "snapshot", "--source", fake.url, "--dry-run"), 0)
        self.assertIn("ready    READY", self.out)
        self.assertIn("12 so far", self.out)
        error = {"jsonrpc": "2.0", "error": {"code": -32603, "message": "Internal error",
                                             "data": "transaction indexing is disabled"}}
        with FakeChain(fail_paths=("tx_search",), error_body=error) as fake:
            self.assertEqual(self.gcheck("escrow", "snapshot", "--source", fake.url, "--dry-run"), 3)
        self.assertIn("ready    BLOCKED", self.out)
        self.assertIn("transaction indexing is disabled", self.out)
        self.assertIn("--escrow-ids", self.out)

    def test_one_snapshot_per_machine(self):
        with FakeChain() as fake:
            with RunLock(os.path.join(config_dir(), "source.lock")):
                code, _ = self.snapshot(fake)
        self.assertEqual(code, 3)
        self.assertIn("BLOCKED", self.out)
        self.assertEqual(fake.requests, [])


class ReportTests(EscrowHarness):
    def test_report_passes_and_repeats_byte_for_byte_across_hash_seeds(self):
        path = self.write_fixture_snapshot()
        outs = []
        for seed in ("0", "1"):
            out = os.path.join(self.tmp.name, "out-" + seed)
            env = dict(os.environ, PYTHONHASHSEED=seed)
            done = subprocess.run([sys.executable, "-m", "gonka_check", "escrow", "report", path, "--min-escrows", "10",
                                   "--out", out], cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            outs.append(out)
        names = sorted(os.listdir(outs[0]))
        self.assertEqual(names, sorted(os.listdir(outs[1])))
        for name in names:
            with open(os.path.join(outs[0], name), "rb") as a, open(os.path.join(outs[1], name), "rb") as b:
                self.assertEqual(a.read(), b.read(), name)
            if name.endswith(".svg"):
                ElementTree.parse(os.path.join(outs[0], name))
        with open(os.path.join(outs[0], "selection.csv"), encoding="utf-8") as handle:
            self.assertEqual(sum(1 for _ in handle) - 1, (21 + 7 + 4) * 3)
        with open(os.path.join(outs[0], "verdicts.json"), encoding="utf-8") as handle:
            verdicts = {item["check"]: item["verdict"] for item in json.load(handle)["verdicts"]}
        self.assertEqual(verdicts, {"weights": "PASS", "escrows": "PASS", "slots_replay": "PASS", "slot_share": "PASS",
                                    "inclusion": "PASS"})
        with open(os.path.join(outs[0], "report.md"), encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("| …jz0qxy | 0.0827 % | 14 | 29 | 52 | 6.7 % |", text)
        self.assertIn("not from all 24 members of the epoch", text)

    def test_few_real_escrows_are_inconclusive(self):
        path = self.write_fixture_snapshot()
        self.assertEqual(self.gcheck("escrow", "verify", path), 2)
        self.assertIn("only 12 real escrows", self.out)

    def test_a_replay_mismatch_stops_the_simulation_checks(self):
        snap = fixture_snapshot()
        slots = snap["escrows"][MM][0][2]
        j = next(i for i, slot in enumerate(slots) if slot != slots[0])
        slots[0], slots[j] = slots[j], slots[0]
        path = self.write_fixture_snapshot(snap)
        code = self.gcheck("escrow", "simulate", path, "--min-escrows", "10", "--runs", "50",
                           "--out", os.path.join(self.tmp.name, "sim"))
        self.assertEqual(code, 1)
        self.assertIn("FAIL         slots_replay", self.out)
        self.assertIn("INCONCLUSIVE slot_share", self.out)

    def test_slots_source_hash(self):
        path = self.write_fixture_snapshot()
        go = os.path.join(self.tmp.name, "slots.go")
        with open(go, "w", encoding="utf-8") as handle:
            handle.write("package calculations\n")
        self.gcheck("escrow", "verify", path, "--min-escrows", "10", "--slots-go", go)
        self.assertIn("FAIL         slots_source", self.out)
        pinned = evaluate.SLOTS_GO_SHA256
        evaluate.SLOTS_GO_SHA256 = hashlib.sha256(b"package calculations\n").hexdigest()
        try:
            self.assertEqual(self.gcheck("escrow", "verify", path, "--min-escrows", "10", "--slots-go", go), 0)
        finally:
            evaluate.SLOTS_GO_SHA256 = pinned

    def test_a_model_without_weights_is_named_and_skipped(self):
        snap = fixture_snapshot()
        snap["models"]["new/Empty"] = {"total_weight": 0, "weights": {}, "dropped_non_positive": 0}
        path = self.write_fixture_snapshot(snap)
        out = os.path.join(self.tmp.name, "report")
        self.assertEqual(self.gcheck("escrow", "report", path, "--min-escrows", "10", "--runs", "50", "--out", out), 0,
                         self.out + self.err)
        with open(os.path.join(out, "report.md"), encoding="utf-8") as handle:
            self.assertIn("No member with a positive weight", handle.read())
        self.assertIn("new/Empty has no member with a positive weight", self.out)
