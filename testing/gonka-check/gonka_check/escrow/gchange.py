"""Escrow settlement across a group_size change: readiness, evidence read at the heights that matter, verdicts."""

import json
import os
from urllib.parse import quote, urlencode

from ..checks import MAPS, verdict
from ..record import utc_now
from ..source import SourceError
from .snapshot import API, _text

GOV = "/chain-api/cosmos/gov/v1"
STAKING = "/chain-api/cosmos/staking/v1beta1"
TXS = "/chain-api/cosmos/tx/v1beta1/txs/"
SETTLE = "/inference.inference.MsgSettleDevshardEscrow"
FORMAT = 1
GCHANGE_CHECKS = (
    ("a_created", ["TF1", "TF2"]),
    ("g_changed", ["TF3", "TF4"]),
    ("b_created", ["TF5", "AC3"]),
    ("a_settled_after", ["TF6", "AC1"]),
    ("own_group", ["TF7", "AC2"]),
    ("same_epoch", ["AC4"]),
    ("accounting", ["AC5"]),
    ("rolled_back", []),
)
MAPS.update(dict(GCHANGE_CHECKS))


def quorum(slots):
    """Slot votes a settlement needs: 2*G/3+1 of the escrow's own slots."""
    return 2 * slots // 3 + 1


def _ngonka(text):
    total = 0
    for part in str(text or "").split(","):
        if part.endswith("ngonka") and part[:-len("ngonka")].isdigit():
            total += int(part[:-len("ngonka")])
    return total


def _attributes(event):
    return {_text(item.get("key")): _text(item.get("value")) for item in event.get("attributes") or []}


def _events(events, kind):
    return [_attributes(event) for event in events or [] if event.get("type") == kind]


def params_diff(before, after, path=""):
    """Leaves that differ between two parameter documents, as (dotted path, old, new)."""
    if isinstance(before, dict) and isinstance(after, dict):
        found = []
        for key in sorted(set(before) | set(after)):
            found += params_diff(before.get(key), after.get(key), path + "." + key if path else key)
        return found
    return [] if before == after else [(path, before, after)]


class Reads:
    """GET-only chain reads, at the head or at a past height; every body also goes to the sink."""

    def __init__(self, source, sink):
        self.source = source
        self.sink = sink

    def json(self, path, kind, key="", height=None):
        body = self.source.get_json(path, kind, height=height)
        self.sink(kind, key, body, height)
        return body

    def head(self):
        body = self.json("/chain-rpc/status", "status")
        try:
            return int(body["result"]["sync_info"]["latest_block_height"])
        except (KeyError, TypeError, ValueError):
            raise SourceError("status: unexpected body")

    def params(self, height=None):
        body = self.json(API + "/params", "params", height=height)
        if not isinstance(body.get("params"), dict) or "devshard_escrow_params" not in body["params"]:
            raise SourceError("params: no devshard_escrow_params")
        return body["params"]

    def current_epoch(self, height=None):
        body = self.json(API + "/get_current_epoch", "current_epoch", height=height)
        try:
            return int(body["epoch"])
        except (KeyError, TypeError, ValueError):
            raise SourceError("get_current_epoch: unexpected body")

    def epoch_info(self):
        body = self.json(API + "/epoch_info", "epoch_info")
        try:
            return {"height": int(body["block_height"]), "epoch": int(body["latest_epoch"]["index"]),
                    "start": int(body["latest_epoch"]["poc_start_block_height"]),
                    "length": int(body["params"]["epoch_params"]["epoch_length"])}
        except (KeyError, TypeError, ValueError):
            raise SourceError("epoch_info: unexpected body")

    def epoch_start(self, epoch):
        body = self.json("%s/epoch_group_data/%d" % (API, epoch), "epoch_group", str(epoch))
        try:
            return int(body["epoch_group_data"]["poc_start_block_height"])
        except (KeyError, TypeError, ValueError):
            raise SourceError("epoch_group_data %d: unexpected body" % epoch)

    def escrow(self, escrow_id, height=None):
        body = self.json("%s/devshard_escrow/%d" % (API, escrow_id), "escrow", str(escrow_id), height)
        if not body.get("found") or not isinstance(body.get("escrow"), dict):
            raise SourceError("escrow %d is not found at height %s" % (escrow_id, height or "head"))
        return body["escrow"]

    def participant(self, address, height):
        body = self.json("%s/participant/%s" % (API, address), "participant", address, height)
        participant = body.get("participant") or {}
        stats = participant.get("current_epoch_stats") or {}
        try:
            return {"status": participant.get("status"), "coin_balance": int(participant.get("coin_balance") or 0),
                    "earned_coins": int(stats.get("earned_coins") or 0)}
        except (TypeError, ValueError):
            raise SourceError("participant %s: unexpected body" % address)

    def txs(self, query, per_page=10):
        """(transactions, total) from the tx index, oldest first."""
        path = "/chain-rpc/tx_search?" + urlencode({"query": '"%s"' % query, "per_page": per_page, "page": 1,
                                                    "order_by": '"asc"'}, quote_via=quote)
        body = self.json(path, "tx_search", query)
        try:
            result = body["result"]
            found = [{"hash": tx["hash"], "height": int(tx["height"]), "code": int(tx["tx_result"].get("code") or 0),
                      "events": tx["tx_result"].get("events") or []} for tx in result["txs"]]
            return found, int(result["total_count"])
        except (KeyError, TypeError, ValueError):
            raise SourceError("tx_search: unexpected body")

    def tx(self, tx_hash):
        body = self.json(TXS + tx_hash, "tx", tx_hash)
        try:
            response = body["tx_response"]
            return {"hash": tx_hash, "height": int(response["height"]), "code": int(response.get("code") or 0),
                    "raw_log": response.get("raw_log") or "", "events": response.get("events") or [],
                    "messages": body["tx"]["body"]["messages"]}
        except (KeyError, TypeError, ValueError):
            raise SourceError("tx %s: unexpected body" % tx_hash)

    def proposal(self, proposal_id):
        body = self.json("%s/proposals/%d" % (GOV, proposal_id), "proposal", str(proposal_id))
        if not isinstance(body.get("proposal"), dict):
            raise SourceError("proposal %d: unexpected body" % proposal_id)
        return body["proposal"]


def _group_size(params):
    return int(params["devshard_escrow_params"]["group_size"])


def settle_evidence(reads, escrow_id, tx_hash):
    tx = reads.tx(tx_hash)
    height = tx["height"]
    item = {"tx": tx_hash, "height": height, "code": tx["code"], "raw_log": tx["raw_log"][:300]}
    msg = next((m for m in tx["messages"] if m.get("@type") == SETTLE), {})
    item["msg"] = {"settler": msg.get("settler"), "fees": int(msg.get("fees") or 0),
                   "nonce": int(msg.get("nonce") or 0), "version": msg.get("state_root_and_protocol_version"),
                   "host_stats": [{"slot_id": int(hs.get("slot_id") or 0), "cost": int(hs.get("cost") or 0),
                                   "missed": int(hs.get("missed") or 0)} for hs in msg.get("host_stats") or []],
                   "signature_slots": [int(sig.get("slot_id") or 0) for sig in msg.get("signatures") or []]}
    # State during the settlement transaction is the state after the previous block.
    item["group_size"] = _group_size(reads.params(height - 1))
    item["epoch"] = reads.current_epoch(height - 1)
    if tx["code"] != 0:
        return item
    events = [e for e in _events(tx["events"], "devshard_escrow_settled") if e.get("escrow_id") == str(escrow_id)]
    item["event"] = events[0] if events else None
    # Payouts carry msg_index; the transaction fee, charged before the message runs, does not.
    transfers = [e for e in _events(tx["events"], "transfer") if "msg_index" in e]
    item["transfers"] = [{"recipient": e.get("recipient"), "sender": e.get("sender"),
                          "amount": _ngonka(e.get("amount"))} for e in transfers]
    item["escrow"] = reads.escrow(escrow_id, height)
    item["participants"] = {}
    for address in sorted(set(item["escrow"].get("slots") or [])):
        item["participants"][address] = {"before": reads.participant(address, height - 1),
                                         "after": reads.participant(address, height)}
    _found, item["settlements_in_block"] = reads.txs("tx.height=%d AND message.action='%s'" % (height, SETTLE), 1)
    return item


def escrow_evidence(reads, escrow_id, attempt=None):
    created, _total = reads.txs("devshard_escrow_created.escrow_id='%d'" % escrow_id, 1)
    if not created:
        raise SourceError("escrow %d: no creation in the tx index" % escrow_id)
    height = created[0]["height"]
    item = {"id": escrow_id, "create": {"tx": created[0]["hash"], "height": height}}
    item["escrow"] = reads.escrow(escrow_id, height)
    item["group_size_at_create"] = _group_size(reads.params(height - 1))
    epoch = int(item["escrow"]["epoch_index"])
    item["epoch"] = {"index": epoch, "start": reads.epoch_start(epoch)}
    settled, _total = reads.txs("devshard_escrow_settled.escrow_id='%d'" % escrow_id, 1)
    tx_hash = settled[0]["hash"] if settled else attempt
    item["settle"] = settle_evidence(reads, escrow_id, tx_hash) if tx_hash else None
    return item


def first_height(reads, low, high, target):
    """First height in (low, high] whose group_size equals target; group_size(low) must differ."""
    if high <= low or _group_size(reads.params(high)) != target:
        return None
    while high - low > 1:
        middle = (low + high) // 2
        if _group_size(reads.params(middle)) == target:
            high = middle
        else:
            low = middle
    return high


def proposal_evidence(reads, proposal_id, upper):
    proposal = reads.proposal(proposal_id)
    new = next((m.get("params") for m in proposal.get("messages") or []
                if str(m.get("@type", "")).endswith("MsgUpdateParams")), None)
    submitted, _total = reads.txs("submit_proposal.proposal_id='%d'" % proposal_id, 1)
    item = {"id": proposal_id, "status": proposal.get("status"), "title": proposal.get("title"),
            "voting_end_time": proposal.get("voting_end_time"), "tally": proposal.get("final_tally_result"),
            "submit_height": submitted[0]["height"] if submitted else None,
            "group_size": _group_size(new) if isinstance(new, dict) and "devshard_escrow_params" in new else None}
    if item["status"] != "PROPOSAL_STATUS_PASSED" or item["group_size"] is None or item["submit_height"] is None:
        return item
    item["group_size_before"] = _group_size(reads.params(item["submit_height"] - 1))
    if item["group_size_before"] == item["group_size"]:
        return item
    if upper < item["submit_height"]:
        item["problem"] = "the search ends at height %d, before it was submitted at %d" % (upper, item["submit_height"])
        return item
    applied = first_height(reads, item["submit_height"] - 1, upper, item["group_size"])
    item["applied_height"] = applied
    if applied is not None:
        item["params_before"] = reads.params(applied - 1)
        item["params_after"] = reads.params(applied)
        item["diff"] = [list(entry) for entry in params_diff(item["params_before"], item["params_after"])]
    return item


def collect(reads, escrows, proposals, attempts, log):
    """Evidence for the escrows and proposals of one run, read at the heights that matter."""
    evidence = {"format": FORMAT, "taken_at": utc_now(), "head": reads.head(), "escrows": {}, "proposals": {}}
    for role, escrow_id in sorted(escrows.items()):
        log("escrow   %s = %d" % (role, escrow_id))
        evidence["escrows"][role] = escrow_evidence(reads, escrow_id, attempts.get(role))
    rollback_submit = None
    if "rollback" in proposals:
        submitted, _total = reads.txs("submit_proposal.proposal_id='%d'" % proposals["rollback"], 1)
        rollback_submit = submitted[0]["height"] if submitted else None
    for role in ("change", "rollback"):
        if role in proposals:
            log("proposal %s = %d" % (role, proposals[role]))
            upper = rollback_submit if role == "change" and rollback_submit else evidence["head"]
            evidence["proposals"][role] = proposal_evidence(reads, proposals[role], upper)
    return evidence


def expected_payouts(slots, msg, divisor=None):
    """Chain rule: slot cost plus fees split by the slot count, the remainder 1 per slot in host_stats order."""
    divisor = divisor or len(slots)
    if not divisor:
        return {}
    share, remainder = divmod(msg["fees"], divisor)
    payouts = {}
    for hs in msg["host_stats"]:
        address = slots[hs["slot_id"]] if 0 <= hs["slot_id"] < len(slots) else "slot %d" % hs["slot_id"]
        extra = 1 if remainder > 0 else 0
        remainder -= extra
        payouts[address] = payouts.get(address, 0) + hs["cost"] + share + extra
    return payouts


def observed_payouts(settle):
    """Per address: a direct transfer, or the coin balance credit of an active participant in the same epoch."""
    found = {}
    for address, states in settle["participants"].items():
        sent = sum(t["amount"] for t in settle["transfers"] if t["recipient"] == address)
        found[address] = {"amount": sent, "via": "transfer"} if sent else {
            "amount": states["after"]["coin_balance"] - states["before"]["coin_balance"], "via": "coin_balance",
            "earned": states["after"]["earned_coins"] - states["before"]["earned_coins"]}
    return found


def _nonzero(amounts):
    return {address: amount for address, amount in amounts.items() if amount}


def _escrow_text(role, item):
    return "%s (escrow %d)" % (role.upper(), item["id"])


def check_created(name, role, item, change=None):
    slots, size = len(item["escrow"].get("slots") or []), item["group_size_at_create"]
    where = "%s: %d slots, group_size %d at creation height %d" % (_escrow_text(role, item), slots, size,
                                                                     item["create"]["height"])
    if change is not None:
        applied = change.get("applied_height")
        if applied is None or item["create"]["height"] < applied:
            return verdict(name, "INCONCLUSIVE", "%s: created before the change took effect" % where)
        if size != change["group_size"]:
            return verdict(name, "FAIL", "%s; the change set %d" % (where, change["group_size"]))
    return verdict(name, "PASS" if slots == size else "FAIL", where)


def check_changed(change):
    if change["status"] != "PROPOSAL_STATUS_PASSED":
        return verdict("g_changed", "INCONCLUSIVE", "proposal %d is %s: nothing changed"
                       % (change["id"], change["status"]))
    if change.get("group_size_before") == change["group_size"]:
        return verdict("g_changed", "INCONCLUSIVE", "proposal %d keeps group_size at %s: nothing changed"
                       % (change["id"], change["group_size"]))
    if change.get("problem"):
        return verdict("g_changed", "INCONCLUSIVE", "proposal %d: %s" % (change["id"], change["problem"]))
    if change.get("applied_height") is None:
        return verdict("g_changed", "FAIL", "proposal %d passed but group_size never became %s"
                       % (change["id"], change["group_size"]))
    other = [entry[0] for entry in change["diff"] if entry[0] != "devshard_escrow_params.group_size"]
    where = "proposal %d: group_size %s at height %d" % (change["id"], change["group_size"], change["applied_height"])
    if other:
        return verdict("g_changed", "FAIL", "%s; it also changed %s" % (where, ", ".join(other)))
    return verdict("g_changed", "PASS", "%s; no other parameter changed" % where)


def check_settled_after(a, change):
    settle = a["settle"]
    if settle is None:
        return verdict("a_settled_after", "INCONCLUSIVE", "%s has no settlement on chain" % _escrow_text("a", a))
    if settle["code"] != 0:
        return verdict("a_settled_after", "FAIL", "%s: settlement %s rejected: %s"
                       % (_escrow_text("a", a), settle["tx"], settle["raw_log"]))
    if settle["group_size"] != change.get("group_size"):
        return verdict("a_settled_after", "INCONCLUSIVE", "%s settled at height %d while group_size was %d"
                       % (_escrow_text("a", a), settle["height"], settle["group_size"]))
    return verdict("a_settled_after", "PASS", "%s settled at height %d while group_size was %d"
                   % (_escrow_text("a", a), settle["height"], settle["group_size"]))


def check_own_group(role, item):
    settle = item["settle"]
    if settle is None or settle["code"] != 0:
        return verdict("own_group", "INCONCLUSIVE", "%s has no accepted settlement" % _escrow_text(role, item))
    created, settled = item["escrow"].get("slots") or [], settle["escrow"].get("slots") or []
    if not created:
        return verdict("own_group", "INCONCLUSIVE", "%s: the evidence has no slots" % _escrow_text(role, item))
    size = len(created)
    signed = settle["msg"]["signature_slots"]
    where = "%s: %d of %d slot signatures, quorum %d" % (_escrow_text(role, item), len(set(signed)), size, quorum(size))
    if settled != created:
        return verdict("own_group", "FAIL", "%s; its slots changed between creation and settlement" % where)
    if any(not 0 <= slot < size for slot in signed) or len(set(signed)) < quorum(size):
        return verdict("own_group", "FAIL", "%s; signatures outside the escrow's own quorum" % where)
    observed = _nonzero({address: found["amount"] for address, found in observed_payouts(settle).items()})
    if observed != _nonzero(expected_payouts(created, settle["msg"])):
        live = settle["group_size"]
        if live != size and observed == _nonzero(expected_payouts(created, settle["msg"], live)):
            return verdict("own_group", "FAIL", "%s; fees were split by %d, not by its %d slots" % (where, live, size))
        return verdict("own_group", "FAIL", "%s; payouts do not match fees split by %d" % (where, size))
    return verdict("own_group", "PASS", "%s; fees %d split by %d while group_size was %d"
                   % (where, settle["msg"]["fees"], size, settle["group_size"]))


def check_same_epoch(items):
    parts, value = [], "PASS"
    for role, item in items:
        settle = item["settle"]
        if settle is None or settle["code"] != 0:
            parts.append("%s not settled" % _escrow_text(role, item))
            value = "INCONCLUSIVE" if value == "PASS" else value
            continue
        offset = settle["height"] - item["epoch"]["start"]
        parts.append("%s in epoch %d at P+%d" % (_escrow_text(role, item), settle["epoch"], offset))
        if settle["epoch"] != item["epoch"]["index"]:
            value = "FAIL"
    return verdict("same_epoch", value, "; ".join(parts))


def _accounting_problems(item):
    settle = item["settle"]
    problems = []
    expected = expected_payouts(item["escrow"].get("slots") or [], settle["msg"])
    observed = observed_payouts(settle)
    for address in sorted(set(expected) | set(observed)):
        amount = expected.get(address, 0)
        found = observed.get(address, {"amount": 0, "via": "none"})
        if found["amount"] != amount:
            problems.append("%s got %d via %s, expected %d" % (address[-6:], found["amount"], found["via"], amount))
        elif found["via"] == "coin_balance" and found["earned"] != amount:
            problems.append("%s earned_coins moved by %d, coin_balance by %d" % (address[-6:], found["earned"], amount))
    total = sum(expected.values())
    amount = int(item["escrow"]["amount"])
    event = settle["event"] or {}
    if str(total) != event.get("total_payout") or str(amount - total) != event.get("remainder"):
        problems.append("event total_payout %s, remainder %s; expected %d and %d"
                        % (event.get("total_payout"), event.get("remainder"), total, amount - total))
    refund = sum(t["amount"] for t in settle["transfers"] if t["recipient"] == item["escrow"]["creator"])
    if refund != amount - total:
        problems.append("refund to the creator %d, expected %d" % (refund, amount - total))
    if settle["escrow"].get("settled") is not True:
        problems.append("escrow not marked settled")
    return problems, total


def check_accounting(items):
    parts, value = [], "PASS"
    for role, item in items:
        settle = item["settle"]
        if settle is None or settle["code"] != 0:
            parts.append("%s not settled" % _escrow_text(role, item))
            value = "INCONCLUSIVE" if value == "PASS" else value
            continue
        if not item["escrow"].get("slots"):
            parts.append("%s: the evidence has no slots" % _escrow_text(role, item))
            value = "INCONCLUSIVE" if value == "PASS" else value
            continue
        problems, total = _accounting_problems(item)
        if not problems:
            parts.append("%s: payouts %d and refund match" % (_escrow_text(role, item), total))
            continue
        # Another settlement in the same block also moves coin balances.
        shared = settle.get("settlements_in_block", 1) > 1
        value = "FAIL" if not shared else ("INCONCLUSIVE" if value == "PASS" else value)
        parts.append("%s: %s%s" % (_escrow_text(role, item), "; ".join(problems),
                                   " (another settlement in the same block)" if shared else ""))
    return verdict("accounting", value, "; ".join(parts))


def check_rolled_back(rollback, change):
    if rollback["status"] != "PROPOSAL_STATUS_PASSED" or rollback.get("applied_height") is None:
        return verdict("rolled_back", "FAIL", "proposal %d is %s, group_size not restored"
                       % (rollback["id"], rollback["status"]))
    where = "proposal %d: group_size %d at height %d" % (rollback["id"], rollback["group_size"],
                                                         rollback["applied_height"])
    if change is None or change.get("applied_height") is None:
        return verdict("rolled_back", "PASS", where)
    left = params_diff(change["params_before"], rollback["params_after"])
    if left:
        return verdict("rolled_back", "FAIL", "%s; differs from before the change: %s"
                       % (where, ", ".join(entry[0] for entry in left)))
    return verdict("rolled_back", "PASS", "%s; parameters equal those before the change" % where)


def evaluate(evidence):
    escrows, proposals = evidence["escrows"], evidence["proposals"]
    a, b = escrows["a"], escrows.get("b")
    change, rollback = proposals.get("change"), proposals.get("rollback")
    settled = [(role, escrows[role]) for role in ("a", "b") if role in escrows]
    found = [check_created("a_created", "a", a)]
    if change:
        found.append(check_changed(change))
    if b:
        found.append(check_created("b_created", "b", b, change))
    if change:
        found.append(check_settled_after(a, change))
    found += [check_own_group("a", a), check_same_epoch(settled), check_accounting(settled)]
    if rollback:
        found.append(check_rolled_back(rollback, change))
    return found


def write_evidence(path, evidence):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(evidence, handle, indent=1, sort_keys=True)
        handle.write("\n")


def load_evidence(path):
    if os.path.isdir(path):
        path = os.path.join(path, "evidence.json")
    with open(path, encoding="utf-8") as handle:
        evidence = json.load(handle)
    if evidence.get("format") != FORMAT or "a" not in evidence.get("escrows", {}):
        raise ValueError("%s: not a group size change evidence file" % path)
    return evidence, path


def preflight(reads, status_reply, start_size, need):
    """READY when a run can start: group_size as expected, free escrow places, a routable gateway on the allowlist."""
    reasons, notes = [], []
    params = reads.params()
    escrow_params = params["devshard_escrow_params"]
    info = reads.epoch_info()
    epoch = reads.current_epoch()
    _found, created = reads.txs("devshard_escrow_created.epoch_index='%d'" % epoch, 1)
    facts = {"height": info["height"], "epoch": epoch, "latest_epoch": info["epoch"], "cycle_start": info["start"],
             "epoch_length": info["length"], "group_size": _group_size(params),
             "max_escrows": int(escrow_params["max_escrows_per_epoch"]), "escrows_created": created}
    if facts["group_size"] != start_size:
        reasons.append("group_size is %d, the run starts from %d" % (facts["group_size"], start_size))
    if facts["max_escrows"] - created < need:
        reasons.append("epoch %d has %d of %d escrows; the run needs %d free" % (epoch, created, facts["max_escrows"],
                                                                               need))
    blocker, doc = status_reply
    if blocker:
        reasons.append("gateway: %s" % blocker)
    shards = [shard for shard in (doc or {}).get("devshards") or [] if isinstance(shard, dict) and shard.get("id")]
    creator = None
    for shard in shards:
        try:
            creator = reads.escrow(int(shard["id"])).get("creator")
            break
        except (SourceError, ValueError):
            continue
    facts["creator"] = creator
    if creator is None:
        reasons.append("gateway: no escrow of its own on chain to read the creator from")
    elif creator not in (escrow_params.get("allowed_creator_addresses") or []):
        reasons.append("gateway creator %s is not in allowed_creator_addresses" % creator)
    else:
        _found, facts["creator_settlements"] = reads.txs("message.sender='%s' AND message.action='%s'"
                                                         % (creator, SETTLE), 1)
        if not facts["creator_settlements"]:
            notes.append("the gateway has settled no escrow on chain yet: run the control first")
    voting = reads.json(GOV + "/params/voting", "gov_params").get("params") or {}
    facts["gov"] = {key: voting.get(key) for key in ("voting_period", "quorum", "threshold", "min_deposit")}
    body = reads.json(STAKING + "/validators?" + urlencode({"status": "BOND_STATUS_BONDED",
                                                            "pagination.limit": 100}), "validators")
    tokens = {item.get("operator_address"): int(item.get("tokens") or 0) for item in body.get("validators") or []}
    total = sum(tokens.values()) or 1
    facts["validators"] = sorted(([address, amount / total] for address, amount in tokens.items()),
                                 key=lambda entry: -entry[1])
    return facts, reasons, notes


def _cell(value):
    return "–" if value is None else str(value)


def markdown(evidence, verdicts):
    escrows, proposals = evidence["escrows"], evidence["proposals"]
    roles = [role for role in ("a", "b") if role in escrows]
    lines = ["# Escrow settlement across a group_size change", "",
             "Evidence read %s from public chain data, head %d. Every value is read at the height where it applies: "
             "group_size before the creation block, balances before and after the settlement block."
             % (evidence["taken_at"][:19].replace("T", " "), evidence["head"]), "", "## Checks", "",
             "| check | maps | verdict | reason |", "|---|---|---|---|"]
    for item in verdicts:
        lines.append("| %s | %s | %s | %s |" % (item["check"], ", ".join(item["maps"]) or "–", item["verdict"],
                                               item["reason"].replace("|", "/")))
    lines += ["", "## Escrows", "", "| | " + " | ".join(role.upper() for role in roles) + " |",
              "|---|" + "---:|" * len(roles)]
    rows = [("id", lambda i: i["id"]), ("created at height", lambda i: i["create"]["height"]),
            ("group_size at creation", lambda i: i["group_size_at_create"]),
            ("slots", lambda i: len(i["escrow"].get("slots") or [])),
            ("epoch", lambda i: i["epoch"]["index"]),
            ("settled at height", lambda i: i["settle"] and i["settle"]["height"]),
            ("settlement epoch", lambda i: i["settle"] and i["settle"]["epoch"]),
            ("group_size during settlement", lambda i: i["settle"] and i["settle"]["group_size"]),
            ("slot signatures / quorum", lambda i: i["settle"] and "%d / %d" % (
                len(set(i["settle"]["msg"]["signature_slots"])), quorum(len(i["escrow"].get("slots") or [])))),
            ("fees", lambda i: i["settle"] and i["settle"]["msg"]["fees"])]
    for name, value in rows:
        lines.append("| %s | %s |" % (name, " | ".join(_cell(value(escrows[role])) for role in roles)))
    for role in roles:
        item = escrows[role]
        settle = item["settle"]
        if not settle or settle["code"] != 0:
            continue
        slots = item["escrow"].get("slots") or []
        expected = expected_payouts(slots, settle["msg"])
        observed = observed_payouts(settle)
        lines += ["", "### Payouts of %s" % role.upper(), "", "| address | slots | expected | observed | via |",
                  "|---|---:|---:|---:|---|"]
        for address in sorted(set(expected) | set(observed)):
            found = observed.get(address, {"amount": 0, "via": "none"})
            lines.append("| …%s | %d | %d | %d | %s |" % (address[-6:], slots.count(address),
                                                          expected.get(address, 0), found["amount"], found["via"]))
    if proposals:
        lines += ["", "## Proposals", "", "| | id | status | submitted | group_size | applied at | other changes |",
                  "|---|---:|---|---:|---:|---:|---|"]
        for role in ("change", "rollback"):
            item = proposals.get(role)
            if item:
                other = [entry[0] for entry in item.get("diff") or []
                         if entry[0] != "devshard_escrow_params.group_size"]
                lines.append("| %s | %d | %s | %s | %s | %s | %s |" % (
                    role, item["id"], item["status"], _cell(item["submit_height"]), _cell(item["group_size"]),
                    _cell(item.get("applied_height")), ", ".join(other) or "none"))
    return "\n".join(lines) + "\n"
