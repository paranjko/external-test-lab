#!/usr/bin/env python3
"""Native traffic scope, real source freshness and reset refusal contracts."""
import importlib.util
import json
import sqlite3
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import Mock
from urllib.parse import parse_qs, urlsplit

SPEC = importlib.util.spec_from_file_location("traffic", Path(__file__).parent / "telegram-bot/gateway_traffic.py")
TRAFFIC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRAFFIC)
MODEL = "Qwen/Qwen3-0.6B"


def payload(rows):
    return {"status": "success", "data": {"resultType": "vector", "result": rows}}


def row(gateway="A", value="3", **labels):
    return {"metric": {"gateway": gateway, "model": MODEL, **labels}, "value": [1000, value]}


class TrafficTest(unittest.TestCase):
    def snapshot(self, value="3", observed="1000", previous=None):
        return TRAFFIC.parse_snapshot(payload([row(value=value, outcome="success")]),
                                      payload([row(value=observed)]), MODEL, 1001, previous)

    def test_native_scope_includes_both_consumers_without_adding_bot_attempts(self):
        result = self.snapshot()
        self.assertEqual(result["state"], "PARTIAL")
        self.assertEqual(result["backends"][0]["counters"][0]["value"], 3)
        self.assertEqual(result["scope"], "native_gateway_requests_including_bot_and_direct_clients")
        self.assertIsNone(result["backends"][0]["tokens"])
        self.assertEqual(result["backends"][1]["counters"], [])

    def test_real_zero_is_distinct_from_missing(self):
        result = self.snapshot("0")
        self.assertEqual(result["backends"][0]["state"], "FRESH")
        self.assertEqual(result["backends"][0]["counters"][0]["value"], 0)
        self.assertEqual(result["backends"][1]["state"], "UNVERIFIED")

    def test_query_timestamp_cannot_refresh_old_or_future_source(self):
        for observed in ("970", "1002", "0"):
            result = self.snapshot(observed=observed)
            self.assertEqual(result["state"], "UNVERIFIED")
            self.assertEqual(result["backends"][0]["counters"], [])

    def test_counter_delta_and_reset_never_create_negative_rate(self):
        baseline = self.snapshot(value="2", observed="990")
        self.assertEqual(self.snapshot(previous=baseline)["backends"][0]["requests_per_second"], 0.1)
        reset = self.snapshot(value="1", previous=baseline)["backends"][0]
        self.assertIsNone(reset["requests_per_second"])
        self.assertEqual(reset["rate_reason"], "counter_reset")

    def test_wrong_model_private_dimensions_and_nonfinite_values_are_rejected(self):
        for metric in (row(model="OTHER", outcome="success"), row(telegram_id="private", outcome="success"),
                       row(value="NaN", outcome="success"), row(value="-1", outcome="success")):
            with self.assertRaises(ValueError):
                TRAFFIC.parse_snapshot(payload([metric]), payload([row(value="1000")]), MODEL, 1001)

    def test_empty_or_duplicate_series_are_not_zero(self):
        result = TRAFFIC.parse_snapshot(payload([]), payload([]), MODEL, 1001)
        self.assertEqual(result["state"], "UNVERIFIED")
        duplicate = row(outcome="success")
        with self.assertRaises(ValueError):
            TRAFFIC.parse_snapshot(payload([duplicate, duplicate]), payload([row(value="1000")]), MODEL, 1001)

    def test_collector_is_readonly_and_encodes_model_in_bounded_queries(self):
        counts, source = row(outcome="success"), row(value="1000")
        counts["value"][0] = source["value"][0] = 1001
        opener = Mock(side_effect=[BytesIO(json.dumps(payload([counts])).encode()),
                                  BytesIO(json.dumps(payload([source])).encode())])
        result = TRAFFIC.collect("https://grafana.example/api/v1/query", MODEL, opener=opener, clock=lambda: 1001)
        self.assertEqual(result["state"], "PARTIAL")
        self.assertEqual(opener.call_count, 2)
        for args, kwargs in opener.call_args_list:
            self.assertIsNone(args[0].data)
            self.assertNotIn("Authorization", args[0].headers)
            self.assertLessEqual(kwargs["timeout"], 3)
            self.assertEqual(parse_qs(urlsplit(args[0].full_url).query)["time"], ["1001"])

    def test_queries_must_share_one_verified_evaluation_instant(self):
        counts, source = row(outcome="success"), row(value="1061")
        counts["value"][0], source["value"][0] = 1060, 1061
        opener = Mock(side_effect=[BytesIO(json.dumps(payload([counts])).encode()),
                                  BytesIO(json.dumps(payload([source])).encode())])
        result = TRAFFIC.collect("https://metrics.example/query", MODEL, opener=opener,
                                 clock=lambda: 1061, monotonic=lambda: 0)
        self.assertEqual(result["state"], "UNVERIFIED")

    def test_source_order_survives_new_fetch_failure_and_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "traffic.sqlite3")
            with sqlite3.connect(path) as db:
                TRAFFIC.initialize(db)
                first = self.snapshot(value="100", observed="1000")
                TRAFFIC.finish(db, TRAFFIC.begin(db, MODEL, 1001), first)
                regressed = self.snapshot(value="90", observed="995", previous=first)
                self.assertEqual(regressed["backends"][0]["state"], "UNVERIFIED")
                TRAFFIC.finish(db, TRAFFIC.begin(db, MODEL, 1002), TRAFFIC.unknown(MODEL))
            with sqlite3.connect(path) as db:
                TRAFFIC.initialize(db)
                # No previous argument and a fresh fetch cannot bypass the durable watermark.
                TRAFFIC.finish(db, TRAFFIC.begin(db, MODEL, 1003), self.snapshot(value="90", observed="995"))
                result = TRAFFIC.latest(db, MODEL, 1003)
                self.assertEqual(result["backends"][0]["state"], "UNVERIFIED")
                self.assertEqual(result["backends"][0]["counters"], [])

    def test_transport_deadline_and_unsafe_endpoint_are_unknown_not_outage(self):
        opener = Mock(side_effect=OSError("private diagnostic"))
        for endpoint in ("https://grafana.example/api/v1/query", "http://public.example/query", "https://secret:password@public.example/query"):
            result = TRAFFIC.collect(endpoint, MODEL, opener=opener)
            self.assertEqual(result["state"], "UNVERIFIED")
            self.assertNotIn("private diagnostic", json.dumps(result))
        opener.reset_mock(side_effect=True)
        result = TRAFFIC.collect("https://grafana.example/query", MODEL, opener=opener, monotonic=Mock(side_effect=[0, 6]))
        self.assertEqual(result["state"], "UNVERIFIED")
        opener.assert_not_called()

    def test_durable_order_expiry_and_duplicate_completion_do_not_renew(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "traffic.sqlite3")
            with sqlite3.connect(path) as db:
                TRAFFIC.initialize(db)
                old = TRAFFIC.begin(db, MODEL, 1000)
                new = TRAFFIC.begin(db, MODEL, 1000)
                TRAFFIC.finish(db, new, self.snapshot(value="4"))
                TRAFFIC.finish(db, old, self.snapshot(value="3"))
                self.assertFalse(TRAFFIC.finish(db, new, self.snapshot(value="99")))
                self.assertEqual(TRAFFIC.latest(db, MODEL, 1001)["backends"][0]["counters"][0]["value"], 4)
            with sqlite3.connect(path) as db:
                result = TRAFFIC.latest(db, MODEL, 1031)
                self.assertEqual(result["state"], "UNVERIFIED")
                self.assertEqual(result["backends"][0]["observed_at"], 1000)
                self.assertEqual(result["backends"][0]["expires_at"], 1030)
                self.assertEqual(result["backends"][0]["counters"], [])

    def test_pending_observation_and_other_model_never_hide_current_completion(self):
        with sqlite3.connect(":memory:") as db:
            TRAFFIC.initialize(db)
            current = TRAFFIC.begin(db, MODEL, 1000)
            TRAFFIC.finish(db, current, self.snapshot())
            TRAFFIC.begin(db, MODEL, 1001)
            other = TRAFFIC.begin(db, "OTHER", 1001)
            TRAFFIC.finish(db, other, TRAFFIC.unknown("OTHER"))
            self.assertEqual(TRAFFIC.latest(db, MODEL, 1001)["state"], "PARTIAL")

    def test_same_source_conflict_is_unknown_but_new_source_can_recover(self):
        with sqlite3.connect(":memory:") as db:
            TRAFFIC.initialize(db)
            TRAFFIC.finish(db, TRAFFIC.begin(db, MODEL, 1001), self.snapshot(value="4"))
            TRAFFIC.finish(db, TRAFFIC.begin(db, MODEL, 1001), self.snapshot(value="5"))
            self.assertEqual(TRAFFIC.latest(db, MODEL, 1001)["state"], "UNVERIFIED")
            TRAFFIC.finish(db, TRAFFIC.begin(db, MODEL, 1001), self.snapshot(value="5", observed="1001"))
            self.assertEqual(TRAFFIC.latest(db, MODEL, 1001)["state"], "PARTIAL")

    def test_fresh_failure_replaces_old_success_without_inventing_zero(self):
        with sqlite3.connect(":memory:") as db:
            TRAFFIC.initialize(db)
            current = TRAFFIC.begin(db, MODEL, 1000)
            TRAFFIC.finish(db, current, self.snapshot())
            failed = TRAFFIC.begin(db, MODEL, 1001)
            TRAFFIC.finish(db, failed, TRAFFIC.unknown(MODEL))
            result = TRAFFIC.latest(db, MODEL, 1001)
            self.assertEqual(result["state"], "UNVERIFIED")
            self.assertEqual(result["backends"], [])

    def test_corrupt_or_extended_expiry_store_is_unknown_without_erasing_evidence(self):
        with sqlite3.connect(":memory:") as db:
            TRAFFIC.initialize(db)
            receipt = TRAFFIC.begin(db, MODEL, 1000)
            TRAFFIC.finish(db, receipt, self.snapshot())
            extended = self.snapshot()
            extended["backends"][0]["expires_at"] = 99999
            for corrupt in ("{", json.dumps({"model": "OTHER"}), json.dumps(extended)):
                db.execute("UPDATE gateway_traffic_snapshots SET payload=? WHERE id=?", (corrupt, receipt))
                db.commit()
                self.assertEqual(TRAFFIC.latest(db, MODEL, 1001)["state"], "UNVERIFIED")
                self.assertEqual(db.execute("SELECT payload FROM gateway_traffic_snapshots WHERE id=?", (receipt,)).fetchone()[0], corrupt)

    def test_projection_revision_advances_once_per_start_and_completion(self):
        with sqlite3.connect(":memory:") as db:
            TRAFFIC.initialize(db)
            self.assertEqual(TRAFFIC.revision(db), 0)
            receipt = TRAFFIC.begin(db, MODEL, 1000)
            self.assertEqual(TRAFFIC.revision(db), 1)
            TRAFFIC.finish(db, receipt, self.snapshot())
            self.assertEqual(TRAFFIC.revision(db), 2)
            TRAFFIC.finish(db, receipt, self.snapshot(value="99"))
            TRAFFIC.initialize(db)
            self.assertEqual(TRAFFIC.revision(db), 2)


if __name__ == "__main__":
    unittest.main()
