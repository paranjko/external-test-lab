"""gcheck escrow preflight, record and verdict against a local chain history of a group size change run."""

import json
import os

from gonka_check.escrow import gchange
from tests.fake_gchange import API, CREATOR, EPOCH, HOSTS, START, FakeRun
from tests.test_escrow import EscrowHarness

SETTLE_A = "%064X" % (0x5E7 * 1000 + 101)


class GroupSizeChange(EscrowHarness):
    def record(self, fake, *extra, roles=("--a", "101", "--b", "102", "--change", "30", "--rollback", "31")):
        code = self.gcheck("escrow", "record", "--source", fake.url, *roles, *extra)
        self.assertEqual(code, 0, self.out + self.err)
        return self.out.rsplit("records  ", 1)[1].strip()

    def verdict(self, run_dir):
        code = self.gcheck("escrow", "verdict", run_dir)
        with open(os.path.join(run_dir, "report", "verdicts.json"), encoding="utf-8") as handle:
            found = json.load(handle)
        return code, {item["check"]: item for item in found["verdicts"]}

    def test_clean_run_passes_every_check(self):
        with FakeRun() as fake:
            run_dir = self.record(fake)
        code, checks = self.verdict(run_dir)
        self.assertEqual(code, 0, checks)
        self.assertEqual(list(checks), ["a_created", "g_changed", "b_created", "a_settled_after", "own_group",
                                        "same_epoch", "accounting", "rolled_back"])
        self.assertEqual({item["verdict"] for item in checks.values()}, {"PASS"})
        self.assertIn("4 of 5 slot signatures, quorum 4", checks["own_group"]["reason"])
        self.assertIn("split by 5 while group_size was 9", checks["own_group"]["reason"])
        self.assertIn("group_size 9 at height %d" % (START + 29), checks["g_changed"]["reason"])
        with open(os.path.join(run_dir, "evidence.json"), encoding="utf-8") as handle:
            evidence = json.load(handle)
        self.assertEqual(evidence["proposals"]["rollback"]["applied_height"], START + 47)
        with open(os.path.join(run_dir, "report", "report.md"), encoding="utf-8") as handle:
            report = handle.read()
        self.assertIn("| slot signatures / quorum | 4 / 4 | 8 / 7 |", report)
        self.assertIn("| group_size during settlement | 9 | 9 |", report)

    def test_values_are_read_at_the_heights_that_apply(self):
        with FakeRun() as fake:
            self.record(fake)
        reads = [(request["path"].split("?")[0], request["height"]) for request in fake.requests]
        self.assertIn((API + "/params", START + 20), reads)  # before escrow A was created
        self.assertIn((API + "/params", START + 34), reads)  # during the settlement of A
        self.assertIn((API + "/participant/" + HOSTS[0], START + 34), reads)  # balance before the settlement
        self.assertIn((API + "/participant/" + HOSTS[0], START + 35), reads)  # and after it
        self.assertIn((API + "/devshard_escrow/101", START + 35), reads)
        self.assertTrue(all(request["method"] == "GET" and request["authorization"] is None
                            for request in fake.requests))
        self.assertTrue(all(request["path"].startswith(("/chain-api/", "/chain-rpc/")) for request in fake.requests))

    def test_fees_split_by_the_new_group_size_fail(self):
        with FakeRun(bug="divisor") as fake:
            run_dir = self.record(fake)
        code, checks = self.verdict(run_dir)
        self.assertEqual(code, 1)
        self.assertEqual(checks["own_group"]["verdict"], "FAIL")
        self.assertIn("fees were split by 9, not by its 5 slots", checks["own_group"]["reason"])
        self.assertEqual(checks["accounting"]["verdict"], "FAIL")

    def test_slots_changed_at_settlement_fail(self):
        with FakeRun(bug="slots") as fake:
            run_dir = self.record(fake)
        _code, checks = self.verdict(run_dir)
        self.assertIn("slots changed between creation and settlement", checks["own_group"]["reason"])

    def test_rejected_settlement_is_reported_with_the_chain_error(self):
        with FakeRun(bug="rejected") as fake:
            run_dir = self.record(fake, "--attempt", "a=" + SETTLE_A.lower())
        code, checks = self.verdict(run_dir)
        self.assertEqual(code, 1)
        self.assertEqual(checks["a_settled_after"]["verdict"], "FAIL")
        self.assertIn("insufficient quorum: 4 slot votes, need 7", checks["a_settled_after"]["reason"])
        self.assertEqual(checks["own_group"]["verdict"], "INCONCLUSIVE")

    def test_settlement_in_the_next_epoch_fails_same_epoch_only(self):
        with FakeRun(bug="late") as fake:
            run_dir = self.record(fake)
        _code, checks = self.verdict(run_dir)
        self.assertEqual(checks["same_epoch"]["verdict"], "FAIL")
        self.assertIn("in epoch %d" % (EPOCH + 1), checks["same_epoch"]["reason"])
        self.assertEqual(checks["accounting"]["verdict"], "PASS")
        self.assertEqual(checks["own_group"]["verdict"], "PASS")

    def test_b_with_the_old_size_fails(self):
        with FakeRun(bug="b5") as fake:
            run_dir = self.record(fake)
        _code, checks = self.verdict(run_dir)
        self.assertEqual(checks["b_created"]["verdict"], "FAIL")

    def test_proposal_with_other_changes_fails(self):
        with FakeRun(bug="extra_param") as fake:
            run_dir = self.record(fake)
        _code, checks = self.verdict(run_dir)
        self.assertEqual(checks["g_changed"]["verdict"], "FAIL")
        self.assertIn("devshard_escrow_params.max_escrows_per_epoch", checks["g_changed"]["reason"])
        self.assertEqual(checks["rolled_back"]["verdict"], "FAIL")

    def test_missing_rollback_fails(self):
        with FakeRun(bug="no_rollback") as fake:
            run_dir = self.record(fake)
        _code, checks = self.verdict(run_dir)
        self.assertEqual(checks["rolled_back"]["verdict"], "FAIL")

    def test_accepted_settlement_below_quorum_fails(self):
        with FakeRun(bug="few_signatures") as fake:
            run_dir = self.record(fake)
        _code, checks = self.verdict(run_dir)
        self.assertEqual(checks["own_group"]["verdict"], "FAIL")
        self.assertIn("2 of 5 slot signatures, quorum 4", checks["own_group"]["reason"])

    def test_short_refund_fails_accounting(self):
        with FakeRun(bug="refund") as fake:
            run_dir = self.record(fake)
        _code, checks = self.verdict(run_dir)
        self.assertEqual(checks["accounting"]["verdict"], "FAIL")
        self.assertIn("refund to the creator", checks["accounting"]["reason"])

    def test_control_run_checks_only_escrow_a(self):
        with FakeRun() as fake:
            run_dir = self.record(fake, roles=("--a", "101"))
        code, checks = self.verdict(run_dir)
        self.assertEqual(code, 0)
        self.assertEqual(list(checks), ["a_created", "own_group", "same_epoch", "accounting"])

    def test_verdict_is_offline_and_repeatable(self):
        with FakeRun() as fake:
            run_dir = self.record(fake)
        self.verdict(run_dir)
        with open(os.path.join(run_dir, "report", "report.md"), encoding="utf-8") as handle:
            first = handle.read()
        self.verdict(run_dir)
        with open(os.path.join(run_dir, "report", "report.md"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), first)

    def test_preflight_ready_and_blocked(self):
        with FakeRun() as fake:
            self.assertEqual(self.gcheck("escrow", "preflight", "--source", fake.url), 0, self.out)
            self.assertIn("ready    READY", self.out)
            self.assertIn("creator %s, 2 settlements" % CREATOR, self.out)
            self.assertEqual(self.gcheck("escrow", "preflight", "--source", fake.url, "--from", "9"), 3)
            self.assertIn("group_size is 5, the run starts from 9", self.out)
        with FakeRun(created_in_epoch=19, creator_settlements=0) as fake:
            self.assertEqual(self.gcheck("escrow", "preflight", "--source", fake.url), 3)
            self.assertIn("has 19 of 20 escrows; the run needs 2 free", self.out)
            self.assertIn("note     the gateway has settled no escrow on chain yet", self.out)

    def test_preflight_and_record_refuse_mainnet_writes_and_bad_input(self):
        self.assertEqual(self.gcheck("escrow", "preflight", "--source", "mainnet"), 4)
        self.assertEqual(self.gcheck("escrow", "record", "--source", "mainnet", "--a", "1", "--attempt", "a=xyz"), 4)
        self.assertEqual(self.gcheck("escrow", "verdict", os.path.join(self.tmp.name, "missing")), 4)


class PayoutRule(EscrowHarness):
    def test_fee_remainder_goes_one_per_slot_in_host_stats_order(self):
        msg = {"fees": 10000, "host_stats": [{"slot_id": i, "cost": 0} for i in (3, 0, 1, 2, 4, 5, 6, 7, 8)]}
        slots = ["h%d" % (i % 5) for i in range(9)]
        payouts = gchange.expected_payouts(slots, msg)
        self.assertEqual(sum(payouts.values()), 10000)
        self.assertEqual(payouts["h3"], 1111 + 1 + 1111)
        self.assertEqual(gchange.quorum(5), 4)
        self.assertEqual(gchange.quorum(9), 7)
        self.assertEqual(gchange.quorum(16), 11)

    def test_params_diff_names_every_changed_leaf(self):
        before = {"a": {"b": 1, "c": [1, 2]}, "d": "x"}
        after = {"a": {"b": 2, "c": [1, 2]}, "d": "x", "e": 1}
        self.assertEqual(gchange.params_diff(before, after), [("a.b", 1, 2), ("e", None, 1)])
