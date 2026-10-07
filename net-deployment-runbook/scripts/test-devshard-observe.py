#!/usr/bin/env python3
"""Observation projection contracts using synthetic, source-shaped readbacks."""

import copy
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("observe", Path(__file__).resolve().parents[1] / "04-ops/devshard-observe.py")
o = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(o)
w = o.w


class Clock:
    now = 1700000000.0

    def time(self):
        return self.now

    monotonic = time


class ObservationContracts(unittest.TestCase):
    def setUp(self):
        self.clock, self.retained = Clock(), []
        self.bindings = {"chain_id": "gonka-devnet-community", "creators": {"A": "creator-a", "B": "creator-b"},
                         "spend_caps": {"A": 5000000000, "B": 5000000000}}
        self.status = {"result": {"node_info": {"network": self.bindings["chain_id"]},
                                  "sync_info": {"catching_up": False, "latest_block_height": "100"}}}
        self.epoch = {"block_height": "100", "latest_epoch": {"index": "1"}, "phase": "Inference",
                      "epoch_stages": {"epoch_index": "1", "next_poc_start": "200"},
                      "is_confirmation_poc_active": False}
        self.params = {"devshard_escrow_params": {"devshard_requests_enabled": True, "max_nonce": 20000}}
        self.hosts = {"host-a": {"model": w.MODEL, "artifact_sha256": w.ARTIFACT, "context_tokens": 8192,
                                  "context_source": "serving-runtime", "receipt_sha256": "a" * 64}}
        self.headers = [{"result": {"block": {"header": {
            "height": str(height), "chain_id": self.bindings["chain_id"],
            "time": datetime.fromtimestamp(1700000000 - 5 * (100 - height), timezone.utc).isoformat()}}}}
            for height in range(80, 101)]
        self.registries, self.escrows = {}, {}
        for identifier, name in enumerate(("A", "B"), 2):
            identifier = str(identifier)
            self.escrows[identifier] = {"found": True, "escrow": {
                "id": identifier, "creator": self.bindings["creators"][name], "model_id": w.MODEL,
                "epoch_index": "1", "slots": ["host-a"]}}
            self.registries[name] = {"devshards": [{"id": identifier, "model": w.MODEL, "active": True,
                "route_prefix": "/devshard/v5", "runtime": {
                    "id": identifier, "model": w.MODEL, "session_version": "v5", "active": True, "on_hold": False,
                    "chain_phase": "Inference", "requests_blocked": False, "nonce": 2, "balance": 4999987114,
                    "active_requests": 0, "pending_race_cleanup": 0}}],
                "settings": {"default_model": w.MODEL, "disabled": {"enabled": False},
                             "model_limits": [{"model_id": w.MODEL, "access_mode": "api_key"}],
                             "escrow_rotation": {"enabled": False, "settlement_enabled": False}},
                "capacity": {"models": {w.MODEL: {"current_weight": 1, "routable_devshards": 1,
                             "routable": True, "access_enabled": True, "access_mode": "api_key"}}}}

    def read(self, kind, subject, deadline):
        values = {"status": self.status, "epoch": self.epoch, "params": self.params,
                  "blocks": self.headers, "hosts": self.hosts}
        value = (self.registries[subject] if kind == "gateway" else self.escrows[subject] if kind == "escrow"
                 else values[kind])
        return {"observed_at": self.clock.time(), "ok": True, "value": copy.deepcopy(value)}

    def collector(self, read=None):
        return o.Collector(read or self.read, lambda kind, **fields: self.retained.append((kind, fields)),
                           self.bindings, "devnet", self.clock)

    def observe(self):
        return self.collector().observe(self.clock.monotonic() + 10)

    def test_observations_bind_all_sources_and_conservative_reservations(self):
        observation = self.observe()
        self.assertTrue(w.eligibility(observation, self.clock.time(), self.bindings))
        self.assertEqual(len(self.retained), 9)
        self.assertEqual(observation["block_intervals"], [5] * 20)
        self.assertEqual(observation["gateways"]["A"]["request_reserve"], 4999987114)
        self.assertEqual(observation["gateways"]["A"]["nonce_reserve"], 19998)
        self.assertEqual(observation["gateways"]["B"]["escrow_id"], "3")

    def test_static_mock_epoch_cannot_pass_as_live_chain_observation(self):
        self.epoch["block_height"] = "150"
        with self.assertRaisesRegex(ValueError, "not current"):
            self.observe()
        self.assertEqual(len(self.retained), 2)

    def test_header_windows_reject_gaps_zero_time_and_wrong_chain(self):
        for field, value in (("height", "79"), ("time", "0001-01-01T00:00:00Z"), ("chain_id", "other")):
            bad = copy.deepcopy(self.headers)
            bad[0]["result"]["block"]["header"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                o.block_intervals(bad, self.bindings["chain_id"], 100, self.clock.time())

    def test_fresh_http_receipt_does_not_mask_stalled_or_future_block_head(self):
        for now in (self.clock.time() + 11, self.clock.time() - 1):
            with self.subTest(now=now), self.assertRaisesRegex(ValueError, "stale or future chain head"):
                o.block_intervals(self.headers, self.bindings["chain_id"], 100, now)

    def test_gateway_output_context_and_mock_context_do_not_prove_live_capacity(self):
        for source in ("gateway-model-descriptor", "desired-config", "mock-unbounded"):
            self.hosts["host-a"]["context_source"] = source
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, "actual serving"):
                self.observe()

    def test_missing_host_or_wrong_artifact_refuses_dispatch(self):
        self.hosts["host-a"]["artifact_sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "wrong Host"):
            self.observe()
        self.hosts.clear()
        with self.assertRaisesRegex(ValueError, "missing actual Host"):
            self.observe()

    def test_unknown_capacity_is_not_inferred_from_active_runtime(self):
        self.registries["A"]["capacity"]["models"][w.MODEL]["routable"] = False
        observation = self.observe()
        self.assertFalse(w.eligibility(observation, self.clock.time(), self.bindings))

    def test_cpoc_and_phase_remain_quiet_without_claiming_inference(self):
        self.epoch["is_confirmation_poc_active"] = True
        self.assertFalse(w.eligibility(self.observe(), self.clock.time(), self.bindings))
        self.epoch["is_confirmation_poc_active"] = False
        self.epoch["phase"] = "PoCGenerate"
        observation = self.observe()
        self.assertEqual(observation["phase"], "PoC")
        self.assertFalse(w.eligibility(observation, self.clock.time(), self.bindings))

    def test_stale_source_is_retained_but_not_retimestamped(self):
        def stale(kind, subject, deadline):
            receipt = self.read(kind, subject, deadline)
            receipt["observed_at"] -= 6
            return receipt
        with self.assertRaisesRegex(ValueError, "stale source"):
            self.collector(stale).observe(self.clock.monotonic() + 10)
        self.assertEqual(len(self.retained), 1)

    def test_whole_collection_deadline_and_oldest_source_timestamp(self):
        def delayed(kind, subject, deadline):
            receipt = self.read(kind, subject, deadline)
            self.clock.now += 1
            return receipt
        with self.assertRaisesRegex(ValueError, "collection deadline"):
            self.collector(delayed).observe(self.clock.monotonic() + 10)
        self.assertEqual(len(self.retained), 5)

    def test_only_nonce_and_balance_may_default_from_omitempty(self):
        runtime = self.registries["A"]["devshards"][0]["runtime"]
        del runtime["nonce"]
        self.assertEqual(self.observe()["gateways"]["A"]["nonce"], 0)
        del runtime["active_requests"]
        with self.assertRaises(KeyError):
            self.observe()

    def test_wrong_creator_extra_escrow_and_lifecycle_enablement_refuse(self):
        original = copy.deepcopy(self.registries["A"])
        for change in (lambda row: row["devshards"].append(copy.deepcopy(row["devshards"][0])),
                       lambda row: row["settings"]["escrow_rotation"].update(settlement_enabled=True)):
            self.registries["A"] = copy.deepcopy(original)
            change(self.registries["A"])
            with self.assertRaises(ValueError):
                self.observe()
        self.registries["A"] = original
        self.escrows["2"]["escrow"]["creator"] = "other"
        with self.assertRaisesRegex(ValueError, "identity/settlement"):
            self.observe()

    def test_failed_read_receipt_is_retained_before_rejection(self):
        def failure(kind, subject, deadline):
            return {"observed_at": self.clock.time(), "ok": False, "error": "HTTP 503"}
        with self.assertRaisesRegex(ValueError, "source read failed"):
            self.collector(failure).observe(self.clock.monotonic() + 10)
        self.assertEqual(self.retained[0][1]["receipt"]["error"], "HTTP 503")

    def test_transport_error_preserves_original_failed_receipt(self):
        receipt = {"response": {"http_status": 503, "body": "unavailable"}}
        def failure(kind, subject, deadline):
            raise o.t.ObservationError(receipt)
        with self.assertRaises(o.t.ObservationError):
            self.collector(failure).observe(self.clock.monotonic() + 10)
        self.assertEqual(self.retained, [("source-error", {"source": "status", "subject": None, "receipt": receipt})])

    def test_strict_chain_numbers_reject_boolean_float_and_signed_text(self):
        for value in (True, 1.0, "01", "+1", "-1", "1.0"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                o.uint(value)

    def mock_samples(self):
        chain = "gonka-test-ds502-isolated"
        return [{"started_at": self.clock.time() - (150 - height) - .8 + poll * .2 - .02,
                 "observed_at": self.clock.time() - (150 - height) - .8 + poll * .2,
                 "value": {"result": {"node_info": {"network": chain},
                    "sync_info": {"catching_up": False, "latest_block_height": str(height)}}}}
                for height in range(129, 151) for poll in range(5)]

    def mock_epoch(self):
        return {"stub": {"block_height": 150, "latest_epoch": {"index": 1},
                         "phase": "Inference", "is_confirmation_poc_active": False},
                "revision": {"block_height": 150, "params_block_height": 1,
                             "epoch_index": 1, "next_poc_start_block_height": 100000}}

    def test_mock_interval_lower_bounds_do_not_invent_header_timestamps(self):
        samples = self.mock_samples()
        intervals = o.measured_intervals(samples, "gonka-test-ds502-isolated", 150, self.clock.time())
        self.assertEqual(len(intervals), 20)
        for value in intervals:
            self.assertAlmostEqual(value, .78, places=5)

    def test_mock_observation_cannot_qualify_devnet_or_mainnet(self):
        for chain in ("gonka-devnet-community", "gonka-mainnet"):
            with self.subTest(chain=chain), self.assertRaisesRegex(ValueError, "cannot qualify DevNet"):
                o.measured_intervals(self.mock_samples(), chain, 150, self.clock.time())
            with self.subTest(chain=chain), self.assertRaisesRegex(ValueError, "cannot qualify DevNet"):
                o.isolated_chain_state(self.status, self.mock_epoch(), chain)

    def test_measured_samples_reject_gaps_regression_and_chain_drift(self):
        for field, value in (("latest_block_height", "140"), ("latest_block_height", "128"),
                             ("catching_up", True)):
            samples = self.mock_samples()
            samples[1]["value"]["result"]["sync_info"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                o.measured_intervals(samples, "gonka-test-ds502-isolated", 150, self.clock.time())
        samples = self.mock_samples()
        samples[1]["value"]["result"]["node_info"]["network"] = "gonka-devnet-community"
        with self.assertRaisesRegex(ValueError, "chain mismatch"):
            o.measured_intervals(samples, "gonka-test-ds502-isolated", 150, self.clock.time())

    def test_measured_samples_require_complete_current_nonoverlapping_window(self):
        for mutation in (lambda rows: rows.__delitem__(slice(21, None)),
                         lambda rows: rows[1].update(started_at=rows[0]["observed_at"] - .1),
                         lambda rows: rows[-1].update(observed_at=self.clock.time() + 1)):
            samples = self.mock_samples()
            mutation(samples)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                o.measured_intervals(samples, "gonka-test-ds502-isolated", 150, self.clock.time())
        for height, now in ((151, self.clock.time()), (150, self.clock.time() + 6)):
            with self.subTest(height=height, now=now), self.assertRaises(ValueError):
                o.measured_intervals(self.mock_samples(), "gonka-test-ds502-isolated", height, now)

    def test_isolated_phase_requires_unchanged_stub_and_current_revision(self):
        status = copy.deepcopy(self.status)
        status["result"]["node_info"]["network"] = "gonka-test-ds502-isolated"
        status["result"]["sync_info"]["latest_block_height"] = "150"
        projected = o.isolated_chain_state(status, self.mock_epoch(), "gonka-test-ds502-isolated")
        self.assertEqual(projected["blocks_to_poc"], 99850)
        self.assertEqual(projected["phase_source"], "isolated-static-stub-and-current-revision")
        for section, field, value in (("revision", "block_height", 153),
                                     ("revision", "epoch_index", 2),
                                     ("revision", "params_block_height", 2),
                                     ("revision", "next_poc_start_block_height", 151),
                                     ("stub", "phase", "PoC"),
                                     ("stub", "is_confirmation_poc_active", True)):
            evidence = self.mock_epoch()
            evidence[section][field] = value
            with self.subTest(section=section, field=field), self.assertRaises(ValueError):
                o.isolated_chain_state(status, evidence, "gonka-test-ds502-isolated")

    def test_connected_mock_projection_is_explicitly_separate_from_devnet(self):
        self.bindings["chain_id"] = "gonka-test-ds502-isolated"
        self.status["result"]["node_info"]["network"] = self.bindings["chain_id"]
        self.status["result"]["sync_info"]["latest_block_height"] = "150"
        self.epoch, self.headers = self.mock_epoch(), self.mock_samples()
        self.hosts["host-a"]["context_source"] = "mock-unbounded"
        collector = o.Collector(self.read, lambda kind, **fields: self.retained.append((kind, fields)),
                                self.bindings, "lab-mock", self.clock)
        observation = collector.observe(self.clock.monotonic() + 10)
        self.assertEqual(observation["environment_kind"], "lab-mock")
        self.assertEqual(observation["height"], 150)
        self.assertEqual(len(self.retained), 9)
        with self.assertRaisesRegex(ValueError, "environment/chain mismatch"):
            o.Collector(self.read, lambda *args: None, self.bindings, "devnet", self.clock)


if __name__ == "__main__":
    unittest.main(verbosity=2)
