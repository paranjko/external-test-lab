#!/usr/bin/env python3
"""Private faucet policy contracts, synthetic signer and clock, no live funding."""

import importlib.util
import io
import json
import multiprocessing
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / "04-ops/faucet/faucet.py"
ENV = {"FAUCET_CHAIN_ID": "policy-test", "FAUCET_GENESIS_SHA256": "a" * 64,
       "FAUCET_RPC_URL": "http://127.0.0.1:1", "FAUCET_KEYRING_PASSWORD": "fixture",
       "FAUCET_AMOUNT_NGONKA": "100000000000", "FAUCET_INITIAL_ADMINS_JSON": "[77]"}


def load_module(path):
    with patch.dict(os.environ, ENV | {"FAUCET_STATE_DB": str(path)}):
        spec = importlib.util.spec_from_file_location("faucet_policy_fixture", SOURCE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    module.TELEGRAM_MAX_CLAIMS_PER_USER = 100
    return module


def competing_claim(path, key, event, queue):
    module = load_module(path)
    module.AMOUNT = "60000000000"
    event.wait(5)
    try:
        with module.database() as db:
            _, fresh = module.reserve_telegram_claim(db, key, "fixture-address", 44, 100000)
        queue.put("fresh" if fresh else "duplicate")
    except module.PolicyError as error:
        queue.put(error.status)


def competing_remove(path, actor, event, queue):
    module = load_module(path)
    event.wait(5)
    try:
        with module.database() as db:
            module.administer_telegram(db, actor, "remove", actor)
        queue.put(200)
    except module.PolicyError as error:
        queue.put(error.status)


def held_submission(path, started, release, result):
    module = load_module(path)

    def signer(*_args, **_kwargs):
        started.set()
        if not release.wait(10):
            raise TimeoutError("fixture gate timed out")
        return "A" * 64

    module.submit = signer
    with module.database() as db:
        result.put(module.dispatch_telegram_claim(db, "a" * 64))


def acknowledged_close(path, requested, acknowledged):
    module = load_module(path)
    requested.set()
    with module.database() as db:
        module.administer_telegram(db, 77, "close")
    acknowledged.set()


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "policy.sqlite3"
        self.module = load_module(self.path)
        with self.module.database():
            pass

    def admin(self, action, value=None, actor=77):
        with self.module.database() as db:
            return self.module.administer_telegram(db, actor, action, value)

    def claim(self, key="a" * 64, actor=44, address="fixture-address", now=100000):
        with self.module.database() as db:
            return self.module.reserve_telegram_claim(db, key, address, actor, now)

    def rejected(self, status, operation):
        with self.assertRaises(self.module.PolicyError) as caught:
            operation()
        self.assertEqual(caught.exception.status, status)

    def http(self, method, payload, key="a" * 64, token="fixture-token"):
        handler = object.__new__(self.module.FaucetHandler)
        raw = json.dumps(payload).encode()
        handler.headers = {"Content-Length": str(len(raw)), "Authorization": f"Bearer {token}",
                           "Idempotency-Key": key}
        handler.rfile = io.BytesIO(raw)
        result = []
        handler.reply = lambda status, body: result.append((status, body))
        self.module.TELEGRAM_TOKEN = "fixture-token"
        getattr(handler, method)()
        return result[0]

    def test_closed_default_and_default_integer_amount(self):
        policy = self.admin("list")
        self.assertEqual(policy, {"state": "closed", "admin": True, "administrator_ids": [77],
                                  "limit_ngonka": "100000000000", "window_seconds": 86400})
        self.rejected(403, self.claim)
        self.admin("open")
        row, fresh = self.claim()
        self.assertTrue(fresh)
        self.assertEqual(row[4], 100 * 10**9)

    def test_admin_add_remove_last_guard_and_no_bootstrap_replay(self):
        self.admin("add", 88)
        self.admin("add", 88)
        self.admin("remove", 77, actor=88)
        self.module = load_module(self.path)
        self.assertEqual(self.admin("list", actor=88)["administrator_ids"], [88])
        self.rejected(403, lambda: self.admin("open", actor=77))
        self.rejected(409, lambda: self.admin("remove", 88, actor=88))
        self.admin("remove", 999, actor=88)

    def test_open_close_limit_survive_restart_and_lineage_change(self):
        self.admin("limit", 250 * 10**9)
        self.admin("open")
        self.module = load_module(self.path)
        self.assertEqual(self.admin("list")["limit_ngonka"], "250000000000")
        self.assertEqual(self.admin("status")["state"], "open")
        self.module.GENESIS_SHA256 = "b" * 64
        self.assertEqual(self.admin("list")["administrator_ids"], [77])
        self.assertEqual(self.admin("list")["limit_ngonka"], "250000000000")
        self.admin("close")
        self.module = load_module(self.path)
        self.assertEqual(self.admin("status")["state"], "closed")

    def test_invalid_admin_and_limit_inputs_fail_closed(self):
        for value in (True, False, 0, -1, "88", 1.5, 2**63):
            self.rejected(400, lambda: self.admin("add", value))
        for value in (True, 0, -1, "100", 0.5, 2**63):
            self.rejected(400, lambda: self.admin("limit", value))
        self.rejected(403, lambda: self.admin("limit", 999, actor=88))

    def test_rolling_amount_across_addresses_exact_boundary(self):
        self.admin("open")
        self.admin("limit", 60000000000)
        self.claim()
        self.admin("limit", 100000000000)
        self.claim("b" * 64, address="second-address", now=100001)
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE telegram_claims SET state='confirmed', confirmed_at=created_at")
        self.module.AMOUNT = "1"
        self.rejected(429, lambda: self.claim("c" * 64, now=186399))
        self.claim("c" * 64, now=186400)
        self.claim("d" * 64, actor=45, address="fixture-address")

    def test_duplicate_retains_amount_identity_and_closed_readback(self):
        self.admin("open")
        original, _ = self.claim()
        self.module.AMOUNT = "1"
        self.admin("close")
        duplicate, fresh = self.claim()
        self.assertEqual(duplicate, original)
        self.assertFalse(fresh)
        self.rejected(409, lambda: self.claim(actor=45))
        self.rejected(409, lambda: self.claim(address="other-address"))

    def test_pending_and_uncertain_do_not_expire_after_rolling_window(self):
        self.admin("open")
        self.claim()
        self.rejected(429, lambda: self.claim("b" * 64))
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE telegram_claims SET state='uncertain'")
        self.rejected(429, lambda: self.claim("b" * 64))
        self.rejected(429, lambda: self.claim("b" * 64, now=186400))
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE telegram_claims SET state='failed'")
        self.claim("b" * 64, now=186400)

    def test_unknown_legacy_amount_is_not_reconstructed_or_erased(self):
        self.admin("open")
        self.claim()
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE telegram_claims SET amount_ngonka=NULL, state='confirmed', confirmed_at=created_at")
        self.module = load_module(self.path)
        self.rejected(503, lambda: self.claim("b" * 64))
        self.assertIsNone(self.claim()[0][4])
        self.claim("b" * 64, now=186400)
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM telegram_claims").fetchone()[0], 2)

    def test_pre_amount_schema_migrates_preserving_policy_and_intents(self):
        with sqlite3.connect(self.path) as db:
            db.execute("DROP TABLE telegram_claims")
            db.execute("CREATE TABLE telegram_claims (idempotency_key TEXT PRIMARY KEY, address TEXT, telegram_id INTEGER, created_at INTEGER, txhash TEXT, state TEXT)")
            db.execute("INSERT INTO telegram_claims VALUES (?, 'fixture-address', 44, 100000, NULL, 'uncertain')", ("a" * 64,))
            db.execute("DROP TABLE faucet_policy")
            db.execute("CREATE TABLE faucet_policy (id INTEGER PRIMARY KEY, open INTEGER)")
            db.execute("INSERT INTO faucet_policy VALUES (1, 1)")
        self.assertEqual(self.admin("list")["state"], "open")
        self.assertIsNone(self.claim()[0][4])
        self.rejected(503, lambda: self.claim("b" * 64))
        self.rejected(503, lambda: self.claim("b" * 64, now=186400))

    def test_public_amount_configuration_cannot_override_telegram_policy(self):
        self.admin("open")
        for actor, amount in enumerate(("0", "-1", "1.5", "01", str(2**63)), start=44):
            self.module.AMOUNT = amount
            row, _ = self.claim(str(actor).zfill(64), actor=actor)
            self.assertEqual(row[4], 100000000000)

    def test_http_admin_strict_private_contract(self):
        for body in (None, [], {"action": "open", "telegram_user_id": True},
                     {"action": "open", "telegram_user_id": 77, "extra": 1}):
            self.assertEqual(self.http("telegram_admin", body)[0], 400)
        self.assertEqual(self.http("telegram_admin", {"action": "list", "telegram_user_id": 77}, token="wrong")[0], 403)
        self.assertEqual(self.http("telegram_admin", {"action": "add", "telegram_user_id": 77, "administrator_id": 88})[1]["administrator_ids"], [77, 88])

    def test_http_uncertain_is_durable_and_never_rebroadcast(self):
        self.admin("open")
        body = {"address": "fixture-address", "telegram_user_id": 44}
        with patch.object(self.module, "valid_address", return_value=True), patch.object(self.module.time, "time", return_value=100000), patch.object(self.module, "submit", side_effect=TimeoutError) as signer:
            self.assertEqual(self.http("telegram_claim", body)[0], 503)
            self.assertEqual(self.http("telegram_claim", body)[1]["state"], "uncertain")
            self.assertEqual(signer.call_count, 1)
            self.assertEqual(self.http("telegram_claim", body, key="b" * 64)[0], 429)

    def test_http_pending_duplicate_never_rebroadcast(self):
        self.admin("open")
        self.claim()
        with patch.object(self.module, "valid_address", return_value=True), patch.object(self.module, "submit") as signer:
            response = self.http("telegram_claim", {"address": "fixture-address", "telegram_user_id": 44})
            self.assertEqual(response[0], 503)
            signer.assert_not_called()

    def test_observed_failed_transaction_can_release_amount_without_rebroadcast(self):
        self.admin("open")
        self.claim()
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE telegram_claims SET state='submitted', txhash=?", ("A" * 64,))
        with patch.object(self.module, "valid_address", return_value=True), patch.object(self.module, "transaction_observation", return_value=("failed", None)), patch.object(self.module, "submit") as signer:
            status, receipt = self.http("telegram_claim", {"address": "fixture-address", "telegram_user_id": 44})
            self.assertEqual((status, receipt["state"]), (200, "failed"))
            signer.assert_not_called()
        self.claim("b" * 64)

    def test_confirmation_requires_actual_code_and_matching_hash(self):
        self.module.CHAIN_REST_URL = "http://127.0.0.1:1"
        for body, expected in (({}, "pending"), ({"code": False, "txhash": "A" * 64}, "pending"),
                               ({"code": 0}, "pending"), ({"code": 1, "txhash": "B" * 64}, "pending"),
                               ({"code": 1, "txhash": "A" * 64}, "failed"),
                               ({"code": 0, "txhash": "A" * 64}, "pending"),
                               ({"code": 0, "txhash": "A" * 64, "timestamp": "2020-01-01T00:00:00Z"}, "confirmed")):
            response = io.BytesIO(json.dumps({"tx_response": body}).encode())
            with patch.object(self.module.urllib.request, "urlopen", return_value=response):
                self.assertEqual(self.module.transaction_confirmation("A" * 64), expected)

    def test_malformed_chain_payload_is_pending_not_quota_release(self):
        self.module.CHAIN_REST_URL = "http://127.0.0.1:1"
        for body in (None, [], "invalid"):
            with patch.object(self.module.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(body).encode())):
                self.assertEqual(self.module.transaction_confirmation("A" * 64), "pending")

    def run_competitors(self, worker, arguments):
        ctx = multiprocessing.get_context("spawn")
        event, queue = ctx.Event(), ctx.Queue()
        processes = [ctx.Process(target=worker, args=(str(self.path), argument, event, queue)) for argument in arguments]
        for process in processes:
            process.start()
        event.set()
        results = [queue.get(timeout=15) for _ in processes]
        for process in processes:
            process.join(15)
            self.assertEqual(process.exitcode, 0)
        queue.close()
        return results

    def test_two_processes_cannot_overspend_amount_quota(self):
        self.admin("open")
        self.assertCountEqual(self.run_competitors(competing_claim, ["a" * 64, "b" * 64]), ["fresh", 429])

    def test_two_processes_same_update_only_one_durable_intent(self):
        self.admin("open")
        self.assertCountEqual(self.run_competitors(competing_claim, ["a" * 64, "a" * 64]), ["fresh", "duplicate"])

    def test_concurrent_admin_removals_preserve_last_administrator(self):
        self.admin("add", 88)
        self.assertCountEqual(self.run_competitors(competing_remove, [77, 88]), [200, 409])

    def test_user_status_exposes_only_own_quota_and_unknown_chain_state(self):
        self.admin("open")
        self.claim()
        with patch.object(self.module.time, "time", return_value=100001):
            status = self.admin("status", actor=44)
        self.assertFalse(status["admin"])
        self.assertEqual(status["remaining_ngonka"], "0")
        self.assertIsNone(status["next_eligible_at"])  # unresolved reservation has no promised expiry
        self.assertNotIn("administrator_ids", status)
        self.assertEqual(status["chain_service_state"], "unverified")
        self.rejected(403, lambda: self.admin("list", actor=44))

    def test_private_policy_audit_is_durable_and_noop_does_not_duplicate(self):
        self.admin("open")
        self.admin("open")
        self.admin("add", 88)
        self.module = load_module(self.path)
        with self.module.database() as db:
            rows = db.execute("SELECT actor, created_at, before_json, after_json FROM faucet_policy_events ORDER BY id").fetchall()
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(row[0] == 77 and row[1] > 0 for row in rows))
        self.assertEqual(json.loads(rows[0][2])["open"], 0)
        self.assertEqual(json.loads(rows[1][3])["administrator_ids"], [77, 88])

    def test_close_between_reservation_and_final_dispatch_prevents_signing(self):
        self.admin("open")
        self.claim()
        self.admin("close")
        with self.module.database() as db, patch.object(self.module, "submit") as signer:
            self.assertEqual(self.module.dispatch_telegram_claim(db, "a" * 64), (None, "cancelled"))
        signer.assert_not_called()
        self.admin("open")
        self.claim("b" * 64)

    def test_close_ack_waits_for_inflight_signer_then_fences_next_dispatch(self):
        self.admin("open")
        self.claim()
        ctx = multiprocessing.get_context("spawn")
        started, release, requested, acknowledged = [ctx.Event() for _ in range(4)]
        result = ctx.Queue()
        sending = ctx.Process(target=held_submission, args=(str(self.path), started, release, result))
        closing = ctx.Process(target=acknowledged_close, args=(str(self.path), requested, acknowledged))
        sending.start()
        try:
            self.assertTrue(started.wait(5))
            closing.start()
            self.assertTrue(requested.wait(5))
            self.assertFalse(acknowledged.wait(0.2))
        finally:
            release.set()
        self.assertEqual(result.get(timeout=10), ("A" * 64, "submitted"))
        self.assertTrue(acknowledged.wait(10))
        for process in (sending, closing):
            process.join(10)
            self.assertEqual(process.exitcode, 0)
        result.close()
        self.rejected(403, lambda: self.claim("b" * 64))

    def test_confirmation_timestamp_is_durable_and_rolling_clock_is_verified_block_time(self):
        self.admin("open")
        self.claim()
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE telegram_claims SET state='submitted', txhash=?", ("A" * 64,))
        with self.module.database() as db, patch.object(self.module.time, "time", return_value=250000), patch.object(self.module, "transaction_observation", return_value=("confirmed", 200000)):
            self.module.reconcile_telegram_user(db, 44)
        self.module = load_module(self.path)
        self.rejected(429, lambda: self.claim("b" * 64, now=286399))
        self.claim("b" * 64, now=286400)

    def test_unknown_migrated_uncertain_amount_never_expires_without_resolution(self):
        self.admin("open")
        self.claim()
        with sqlite3.connect(self.path) as db:
            db.execute("UPDATE telegram_claims SET state='uncertain', amount_ngonka=NULL")
        self.rejected(503, lambda: self.claim("b" * 64, now=1000000))

    def test_confirmation_without_aware_nonfuture_block_time_cannot_release_quota(self):
        self.module.CHAIN_REST_URL = "http://127.0.0.1:1"
        for timestamp in (None, "invalid", "2020-01-01T00:00:00", "2999-01-01T00:00:00Z"):
            body = {"tx_response": {"code": 0, "txhash": "A" * 64, "timestamp": timestamp}}
            with patch.object(self.module.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(body).encode())):
                self.assertEqual(self.module.transaction_observation("A" * 64), ("pending", None))

    def test_confirmed_http_receipt_retains_observed_block_time_after_restart(self):
        self.admin("open")
        body = {"address": "fixture-address", "telegram_user_id": 44}
        with patch.object(self.module, "valid_address", return_value=True), patch.object(self.module.time, "time", return_value=100000), patch.object(self.module, "submit", return_value="A" * 64), patch.object(self.module, "transaction_observation", return_value=("confirmed", 99999)):
            original = self.http("telegram_claim", body)
        self.module = load_module(self.path)
        with patch.object(self.module, "valid_address", return_value=True), patch.object(self.module, "submit") as signer, patch.object(self.module, "transaction_observation", return_value=("unavailable", None)):
            duplicate = self.http("telegram_claim", body)
        self.assertEqual(original, duplicate)
        self.assertEqual(duplicate[1]["confirmed_at"], 99999)
        signer.assert_not_called()

    def test_explicit_checktx_rejection_releases_amount_without_rebroadcast(self):
        self.admin("open")
        self.claim()
        with self.module.database() as db, patch.object(self.module, "submit", side_effect=self.module.DefinitelyRejected) as signer:
            self.assertEqual(self.module.dispatch_telegram_claim(db, "a" * 64), (None, "failed"))
        signer.assert_called_once()
        self.claim("b" * 64)

    def test_submit_does_not_call_a_nonzero_checktx_receipt_submitted(self):
        result = type("Result", (), {"returncode": 0, "stdout": json.dumps({"code": 5, "txhash": "A" * 64}), "stderr": ""})()
        with patch.object(self.module.subprocess, "run", return_value=result), self.assertRaises(self.module.DefinitelyRejected):
            self.module.submit("fixture-address", "100")

    def test_crashed_inflight_worker_keeps_pending_intent_and_quota(self):
        self.admin("open")
        self.claim()
        ctx = multiprocessing.get_context("spawn")
        started, release, result = ctx.Event(), ctx.Event(), ctx.Queue()
        worker = ctx.Process(target=held_submission, args=(str(self.path), started, release, result))
        worker.start()
        try:
            self.assertTrue(started.wait(5))
        finally:
            worker.terminate()
            worker.join(10)
            result.close()
        self.module = load_module(self.path)
        row, fresh = self.claim()
        self.assertFalse(fresh)
        self.assertEqual(row[3], "pending")
        self.rejected(429, lambda: self.claim("b" * 64, now=1000000))

    def check_fair_reconciliation(self, younger_state):
        self.admin("limit", 50000000000)
        self.admin("open")
        self.claim()
        self.admin("limit", 100000000000)
        self.claim("b" * 64, now=100001)
        with sqlite3.connect(self.path) as db:
            for key, txhash in (("a", "A"), ("b", "B")):
                db.execute("UPDATE telegram_claims SET state='submitted', txhash=? WHERE idempotency_key=?", (txhash * 64, key * 64))
        observed = []

        def observe(txhash):
            observed.append(txhash)
            return ("pending", None) if txhash == "A" * 64 else (younger_state, 200000 if younger_state == "confirmed" else None)

        with self.module.database() as db, patch.object(self.module, "transaction_observation", side_effect=observe):
            self.module.reconcile_telegram_user(db, 44)
        self.module = load_module(self.path)  # Fair selection is durable, not an in-process cursor.
        with self.module.database() as db, patch.object(self.module, "transaction_observation", side_effect=observe):
            self.module.reconcile_telegram_user(db, 44)
        row, _ = self.claim("c" * 64, now=1000000)
        self.assertEqual(observed, ["A" * 64, "B" * 64])
        self.assertEqual(row[4], 50000000000)  # Older unresolved50 stays reserved.

    def test_oldest_pending_cannot_starve_younger_confirmed_transfer(self):
        self.check_fair_reconciliation("confirmed")

    def test_oldest_pending_cannot_starve_younger_failed_transfer(self):
        self.check_fair_reconciliation("failed")

    def test_fair_reconciliation_round_robin_survives_restart_and_frozen_clock(self):
        self.admin("open")
        for index in range(3):
            self.admin("limit", (index + 1) * 50000000000)
            self.claim(chr(97 + index) * 64, now=100000 + index)
        with sqlite3.connect(self.path) as db:
            for index in range(3):
                db.execute("UPDATE telegram_claims SET state='submitted', txhash=? WHERE idempotency_key=?", (chr(65 + index) * 64, chr(97 + index) * 64))
        observed = []
        for index in range(6):
            if index == 3:
                self.module = load_module(self.path)
            with self.module.database() as db, patch.object(self.module.time, "time", return_value=1000000), patch.object(self.module, "transaction_observation", side_effect=lambda txhash: observed.append(txhash) or ("pending", None)):
                self.module.reconcile_telegram_user(db, 44)
        self.assertEqual(observed, [letter * 64 for letter in "ABCABC"])


if __name__ == "__main__":
    unittest.main()
