#!/usr/bin/env python3
"""Deterministic workload safety tests; no live requests or shortened acceptance."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("workload", Path(__file__).resolve().parents[1] / "04-ops/devshard-workload.py")
w = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(w)


def completion(escrow="1", nonce=1, streaming=False):
    base = {"id": f"devshard-{escrow}-{nonce}", "model": w.MODEL}
    usage = {"prompt_tokens": 161, "completion_tokens": 5, "total_tokens": 166}
    if not streaming:
        return json.dumps({**base, "choices": [{"index": 0, "message": {"role": "assistant", "content": "fixture answer"},
                                                "finish_reason": "stop"}], "usage": usage})
    return "".join("data: " + json.dumps(doc) + "\n\n" for doc in [
        {**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "fixture answer"}, "finish_reason": None}]},
        {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
        {**base, "choices": [], "usage": usage}]) + "data: [DONE]\n\n"


class Clock:
    def __init__(self):
        self.now = 1000.0

    def time(self):
        return self.now

    monotonic = time

    def sleep(self, delay):
        self.now += delay


class Adapter:
    def __init__(self, clock):
        self.clock, self.calls = clock, []
        self.states = {name: {"creator": f"creator-{name}", "escrow_id": str(i), "model": w.MODEL,
                             "protocol": "v5", "artifact_sha256": w.ARTIFACT, "nonce": 0, "max_nonce": 20000,
                             "balance": 5000000000, "request_reserve": 2152, "nonce_reserve": 1,
                             "routable": True, "active_requests": 0, "pending_cleanup": 0,
                             "rotation": False, "settlement": False, "context_tokens": 1152, "escrow_epoch": 1}
                       for i, name in enumerate(("A", "B"), 1)}

    def observe(self, deadline):
        return {"chain_id": "gonka-test-ds502-isolated", "observed_at": self.clock.time(), "height": 150,
                "epoch": 1, "phase": "Inference", "cpoc": False, "blocks_to_poc": 1000,
                "block_intervals": [5] * 20, "gateways": copy.deepcopy(self.states)}

    def send(self, gateway, wire, deadline, request_id):
        self.calls.append((gateway, json.loads(wire), request_id, self.clock.time(), deadline))
        self.clock.sleep(.1)
        self.states[gateway]["nonce"] += 1
        self.states[gateway]["balance"] -= 10
        return {"http_status": 200, "body_complete": True, "transport_error": None,
                "elapsed_seconds": .1, "ttft_seconds": .05 if json.loads(wire)["stream"] else None,
                "body": completion(self.states[gateway]["escrow_id"], self.states[gateway]["nonce"], json.loads(wire)["stream"])}


class WorkloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.bindings = {"chain_id": "gonka-test-ds502-isolated", "creators": {"A": "creator-A", "B": "creator-B"},
                         "spend_caps": {"A": 80000000000, "B": 80000000000}}
        self.locks = [self.root / ".a.lock", self.root / ".b.lock"]
        self.clock = Clock()
        self.adapter = Adapter(self.clock)

    def campaign(self, name="campaign", bindings=None):
        return w.Campaign(self.root / name, bindings or self.bindings, self.locks)

    def test_frozen_payloads_and_full_schedule(self):
        self.assertEqual(len(w.payloads()), 40)
        first, second = w.schedule(1), w.schedule(2)
        self.assertEqual(len(first), 40)
        self.assertEqual([i["gateway"] for i in first[:4]], ["A", "B", "B", "A"])
        self.assertEqual([(i["gateway"], i["case"], i["stream"]) for i in first],
                         [(i["gateway"], i["case"], not i["stream"]) for i in second])
        for name in ("A", "B"):
            own = [i for i in first if i["gateway"] == name]
            self.assertEqual(sum(i["stream"] for i in own), 10)
            for case in range(1, 21):
                self.assertEqual(sum(i["case"] == f"DOC-{case:02d}" for i in own), 1)
        self.assertEqual((w.LIFETIME, w.ESCROWS, w.WALL_SECONDS), (60, 16, 14400))
        manifest = w.execution_manifest()
        self.assertEqual(manifest["schema"], "gdc-devshard-workload/3")
        self.assertEqual(len(manifest["schedule"]), 80)

    def test_usage_opt_in_changes_only_versioned_streaming_wire(self):
        manifest = json.loads((w.ASSETS / "manifest.json").read_text())
        wires = w.payloads()
        for sample in manifest["samples"]:
            for streaming in (False, True):
                wire = json.loads(wires[(sample["id"], streaming)])
                if streaming:
                    self.assertEqual(wire.pop("stream_options"), {"include_usage": True})
                else:
                    self.assertNotIn("stream_options", wire)
                self.assertEqual(w.hashlib.sha256(w.canonical(wire)).hexdigest(),
                                 sample["payload_sha256_by_stream"][str(streaming).lower()])

    def test_json_and_sse_preserve_correlation_and_require_manual_review(self):
        for streaming in (False, True):
            result = w.response(completion(streaming=streaming), streaming)
            self.assertEqual((result["escrow_id"], result["nonce"], result["factual_review"]), ("1", 1, "PENDING"))

    def test_invalid_truncated_and_duplicate_response_outcomes(self):
        for body, stream in [(completion(streaming=True).replace("data: [DONE]\n\n", ""), True),
                             (completion(streaming=True) + "data: [DONE]\n\n", True),
                             (completion().replace('"stop"', '"length"'), False),
                             (completion().replace('"fixture answer"', '""'), False),
                             (completion().replace('"total_tokens": 166', '"total_tokens": 9'), False),
                             (completion().replace(w.MODEL, "wrong-model"), False),
                             ('{"id":"a","id":"b"}', False)]:
            with self.subTest(body=body), self.assertRaises(ValueError):
                w.response(body, stream)

    def test_official_gateway_final_usage_stop_without_late_content(self):
        body = completion(streaming=True)
        final_choice = {"index": 0, "delta": {}, "finish_reason": "stop"}
        body = body.replace('"choices": []', '"choices": ' + json.dumps([final_choice]))
        self.assertEqual(w.response(body, True)["usage"]["total_tokens"], 166)
        final = json.loads(body.split("data: ")[-2].strip())
        for changed in [
            {**final, "choices": [{**final_choice, "delta": {"content": "late"}}]},
            {**final, "choices": [{**final_choice, "finish_reason": None}]},
            {**final, "choices": [{**final_choice, "index": False}]},
            {**final, "usage": None},
        ]:
            changed_body = body[:body.rfind("data: ", 0, body.rfind("data: "))]
            changed_body += "data: " + json.dumps(changed) + "\n\ndata: [DONE]\n\n"
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                w.response(changed_body, True)
        repeated = body.replace("data: [DONE]", "data: " + json.dumps(final) + "\n\ndata: [DONE]")
        with self.assertRaisesRegex(ValueError, "duplicate or late"):
            w.response(repeated, True)

    def test_two_complete_runs_reopen_same_append_only_ledger(self):
        with self.campaign() as campaign:
            one = w.Runner(campaign, self.adapter.observe, self.adapter.send, self.clock).run(1)
            self.assertEqual(one["automated_outcome"], "PASS")
            self.assertEqual(one["completed"], {"A": 20, "B": 20})
            self.assertAlmostEqual(one["wall_seconds"], 4)
            self.assertEqual(campaign.events[0]["execution_manifest"], w.execution_manifest())
        original = (self.root / "campaign/events.jsonl").read_bytes()
        with self.campaign() as campaign:
            two = w.Runner(campaign, self.adapter.observe, self.adapter.send, self.clock).run(2)
            self.assertEqual(two["automated_outcome"], "PASS")
            self.assertEqual(two["factual_review"], "PENDING")
            terminals = [e for e in campaign.events if e["kind"] == "terminal"]
            self.assertEqual(len(terminals), 80)
            self.assertEqual(len({e["request_id"] for e in terminals}), 80)
            self.assertEqual(sum(e["charged"] for e in terminals), 800)
            for gateway in ("A", "B"):
                calls = [row for row in self.adapter.calls if row[0] == gateway]
                for a, b in zip(calls, calls[1:]):
                    self.assertGreaterEqual(b[3] - a[3], .099)
            with self.assertRaisesRegex(ValueError, "no rerun"):
                w.Runner(campaign, self.adapter.observe, self.adapter.send, self.clock).run(2)
        self.assertTrue((self.root / "campaign/events.jsonl").read_bytes().startswith(original))

    def test_overlap_locks_span_different_evidence_directories(self):
        with self.campaign():
            with self.assertRaises(BlockingIOError), self.campaign("other"):
                self.fail("second owner acquired locks")
        self.assertFalse((self.root / "other").exists())

    def test_incomplete_admission_never_replays_on_restart(self):
        with self.campaign() as campaign:
            campaign.admit(w.schedule(1)[0], self.adapter.states["A"], w.payloads()[("DOC-01", False)], self.clock.time())
        original = (self.root / "campaign/events.jsonl").read_bytes()
        with self.assertRaisesRegex(ValueError, "never redispatch"), self.campaign():
            self.fail("uncertain admission accepted")
        self.assertEqual((self.root / "campaign/events.jsonl").read_bytes(), original)

    def test_new_directory_cannot_reset_instance_lifetime_accounting(self):
        with self.campaign():
            pass
        with self.assertRaisesRegex(ValueError, "never reset lifetime"), self.campaign("other"):
            pass
        self.assertFalse((self.root / "other").exists())

    def test_drift_corruption_and_partial_tail_rejected(self):
        with self.campaign():
            pass
        drift = copy.deepcopy(self.bindings)
        drift["spend_caps"]["A"] += 1
        with self.assertRaisesRegex(ValueError, "binding drift"), self.campaign(bindings=drift):
            pass
        path = self.root / "campaign/events.jsonl"
        original = path.read_text()
        path.write_text(original.replace('"creator-A"', '"creator-X"'))
        with self.assertRaisesRegex(ValueError, "integrity"), self.campaign():
            pass
        path.write_text(original + '{"interrupted":')
        with self.assertRaisesRegex(ValueError, "interrupted"), self.campaign():
            pass

    def test_phase_cpoc_margin_and_busy_capacity_block_admission(self):
        for key, value in [("phase", "PoC"), ("cpoc", True), ("blocks_to_poc", 18), ("block_intervals", [.001] * 20)]:
            obs = self.adapter.observe(0)
            obs[key] = value
            self.assertFalse(w.eligibility(obs, self.clock.time(), self.bindings))
        for key, value in [("active_requests", 1), ("pending_cleanup", 1), ("routable", False), ("escrow_epoch", 2)]:
            obs = self.adapter.observe(0)
            obs["gateways"]["A"][key] = value
            self.assertFalse(w.eligibility(obs, self.clock.time(), self.bindings))

    def test_stale_mainnet_unknown_phase_context_and_identity_rejected(self):
        for key, value in [("observed_at", 990), ("observed_at", 1001), ("chain_id", "gonka-mainnet"),
                           ("phase", "unknown"), ("cpoc", "false"), ("block_intervals", [5] * 19)]:
            obs = self.adapter.observe(0)
            obs[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                w.eligibility(obs, self.clock.time(), self.bindings)
        for key, value in [("creator", "wrong"), ("artifact_sha256", "0" * 64), ("settlement", True),
                           ("context_tokens", 0), ("max_nonce", 20001), ("nonce", True)]:
            obs = self.adapter.observe(0)
            obs["gateways"]["A"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                w.eligibility(obs, self.clock.time(), self.bindings)

    def test_nonce_balance_and_spend_caps_prevent_dispatch(self):
        for key, value in [("nonce", 20000), ("balance", 0)]:
            obs = self.adapter.observe(0)
            obs["gateways"]["A"][key] = value
            with self.assertRaises(w.Stop):
                w.eligibility(obs, self.clock.time(), self.bindings)
        self.bindings["spend_caps"]["A"] = 2151
        with self.campaign() as campaign:
            result = w.Runner(campaign, self.adapter.observe, self.adapter.send, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "BLOCKED")
            self.assertFalse(self.adapter.calls)

    def test_request_lifetime_cap_includes_smoke(self):
        wire = w.payloads()[("DOC-01", False)]
        with self.campaign() as campaign:
            for i in range(60):
                item = {**w.schedule(1)[0], "request_id": f"smoke-{i}"}
                campaign.admit(item, self.adapter.states["A"], wire, self.clock.time())
                campaign.append("terminal", request_id=item["request_id"], gateway="A", outcome="PASS", charged=1)
            with self.assertRaisesRegex(w.Stop, "request cap"):
                campaign.admit(w.schedule(1)[0], self.adapter.states["A"], wire, self.clock.time())

    def test_escrow_lifetime_cap_includes_smoke(self):
        wire = w.payloads()[("DOC-01", False)]
        with self.campaign() as campaign:
            for i in range(16):
                state = {**self.adapter.states["A"], "escrow_id": str(i + 10)}
                item = {**w.schedule(1)[0], "request_id": f"smoke-{i}"}
                campaign.admit(item, state, wire, self.clock.time())
                campaign.append("terminal", request_id=item["request_id"], gateway="A", outcome="PASS", charged=1)
            with self.assertRaisesRegex(w.Stop, "escrow cap"):
                campaign.admit(w.schedule(1)[0], self.adapter.states["A"], wire, self.clock.time())

    def test_timeout_is_terminal_and_never_redispatched(self):
        calls = []

        def timeout(*args):
            calls.append(args)
            raise TimeoutError("fixture timeout")

        with self.campaign() as campaign:
            result = w.Runner(campaign, self.adapter.observe, timeout, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "INCONCLUSIVE")
            self.assertEqual(len(calls), 1)
            self.assertEqual(len([e for e in campaign.events if e["kind"] == "terminal"]), 1)
            with self.assertRaises(ValueError):
                w.Runner(campaign, self.adapter.observe, timeout, self.clock).run(2)

    def test_post_dispatch_nonce_mismatch_stops_with_raw_response_retained(self):
        def wrong_nonce(*args):
            result = self.adapter.send(*args)
            result["body"] = completion("1", 99)
            return result

        with self.campaign() as campaign:
            result = w.Runner(campaign, self.adapter.observe, wrong_nonce, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "INCONCLUSIVE")
            self.assertEqual(len(self.adapter.calls), 1)
            self.assertEqual(len([e for e in campaign.events if e["kind"] == "response"]), 1)

    def test_four_hour_deadline_even_when_observation_returns_late(self):
        def late(deadline):
            self.clock.sleep(14401)
            return self.adapter.observe(deadline)

        with self.campaign() as campaign:
            result = w.Runner(campaign, late, self.adapter.send, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "BLOCKED")
            self.assertFalse(self.adapter.calls)

    def test_drain_is_bounded_after_one_dispatched_request(self):
        def busy(deadline):
            obs = self.adapter.observe(deadline)
            if self.adapter.calls:
                obs["gateways"]["A"]["pending_cleanup"] = 1
            return obs

        with self.campaign() as campaign:
            result = w.Runner(campaign, busy, self.adapter.send, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "INCONCLUSIVE")
            self.assertEqual(len(self.adapter.calls), 1)
            self.assertAlmostEqual(result["wall_seconds"], 90.1)

    def test_phase_pause_is_not_counted_or_dispatched(self):
        def phase_at(now):
            return "PoC" if now < 1002 or 1003 <= now < 1005 else "Inference"

        def observe(deadline):
            obs = self.adapter.observe(deadline)
            obs["phase"] = phase_at(self.clock.time())
            return obs

        with self.campaign() as campaign:
            result = w.Runner(campaign, observe, self.adapter.send, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "PASS")
            self.assertGreaterEqual(result["wall_seconds"] - result["eligible_seconds"], 4)
            self.assertTrue(all(phase_at(call[3]) == "Inference" for call in self.adapter.calls))

    def test_http_and_deadline_failures_stop_after_one_attempt(self):
        for kind in ("http", "deadline", "malformed"):
            self.locks = [self.root / f"{kind}-{name}.lock" for name in ("A", "B")]
            def send(*args):
                result = self.adapter.send(*args)
                if kind == "http":
                    result["http_status"] = 503
                elif kind == "deadline":
                    self.clock.sleep(61)
                else:
                    result["body"] = "not-json"
                return result

            self.adapter.calls.clear()
            with self.campaign(kind) as campaign:
                result = w.Runner(campaign, self.adapter.observe, send, self.clock).run(1)
                self.assertEqual(result["automated_outcome"], "FAIL")
                self.assertEqual(len(self.adapter.calls), 1)
                self.assertEqual(len([e for e in campaign.events if e["kind"] == "terminal"]), 1)

    def test_unknown_drain_preserves_full_reservation(self):
        def observe(deadline):
            if self.adapter.calls:
                raise TimeoutError("readback unavailable")
            return self.adapter.observe(deadline)

        with self.campaign() as campaign:
            result = w.Runner(campaign, observe, self.adapter.send, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "INCONCLUSIVE")
            terminal = next(e for e in campaign.events if e["kind"] == "terminal")
            self.assertEqual(terminal["charged"], 2152)

    def test_incomplete_transport_receipt_is_preserved_and_not_retried(self):
        def send(*args):
            result = self.adapter.send(*args)
            result.update(body_complete=False, transport_error="TimeoutError")
            return result

        with self.campaign() as campaign:
            result = w.Runner(campaign, self.adapter.observe, send, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "INCONCLUSIVE")
            self.assertEqual(len(self.adapter.calls), 1)
            raw = next(event for event in campaign.events if event["kind"] == "response")
            self.assertEqual(raw["result"]["transport_error"], "TimeoutError")
            terminal = next(event for event in campaign.events if event["kind"] == "terminal")
            self.assertEqual(terminal["charged"], 2152)

    def test_mutable_inputs_cannot_rewrite_frozen_accounting(self):
        campaign = self.campaign()
        self.bindings["spend_caps"]["A"] = 1
        with campaign:
            state = copy.deepcopy(self.adapter.states["A"])
            campaign.admit(w.schedule(1)[0], state, w.payloads()[("DOC-01", False)], self.clock.time())
            state["request_reserve"] = 0
            self.assertEqual(campaign.bindings["spend_caps"]["A"], 80000000000)
            self.assertEqual(campaign.events[-1]["before"]["request_reserve"], 2152)

    def test_uncertain_timeout_keeps_reservation_even_with_idle_readback(self):
        def timeout(*args):
            raise TimeoutError("fixture timeout")

        with self.campaign() as campaign:
            result = w.Runner(campaign, self.adapter.observe, timeout, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "INCONCLUSIVE")
            terminal = next(e for e in campaign.events if e["kind"] == "terminal")
            self.assertEqual(terminal["observed_charge"], 0)
            self.assertEqual(terminal["charged"], 2152)

    def test_stale_phase_fails_before_admission(self):
        def observe(deadline):
            obs = self.adapter.observe(deadline)
            obs["observed_at"] -= 6
            return obs

        with self.campaign() as campaign:
            result = w.Runner(campaign, observe, self.adapter.send, self.clock).run(1)
            self.assertEqual(result["automated_outcome"], "BLOCKED")
            self.assertFalse(self.adapter.calls)
            self.assertFalse(any(e["kind"] == "admitted" for e in campaign.events))

    def test_changed_execution_contract_does_not_reinterpret_prior_results(self):
        from unittest.mock import patch
        old = {**w.execution_manifest(), "schema": "gdc-devshard-workload/1"}
        with patch.object(w, "execution_manifest", return_value=old), self.campaign():
            pass
        original = (self.root / "campaign/events.jsonl").read_bytes()
        with self.assertRaisesRegex(ValueError, "execution contract changed"), self.campaign():
            pass
        self.assertEqual((self.root / "campaign/events.jsonl").read_bytes(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
