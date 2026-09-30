"""Local chain history of one group size change run, served at any past height; `bug` plants a defect."""

import copy
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

API = "/chain-api/productscience/inference/inference"
SETTLE = "/inference.inference.MsgSettleDevshardEscrow"
EPOCH, START, LENGTH = 8000, 600000, 330
CREATOR = "gonka1" + "c" * 38
HOSTS = ["gonka1" + ("%02d" % i) * 19 for i in range(6)]
MODULE = "gonka1" + "m" * 38
AMOUNT = 1000000000
FEES = 10000


class FakeRun:
    def __init__(self, bug=None, group_size=5, created_in_epoch=6, creator_settlements=2):
        self.bug = bug
        self.start_size = group_size
        self.created_in_epoch = created_in_epoch
        self.creator_settlements = creator_settlements
        self.head = START + 400
        self.change = {"id": 30, "submit": START + 23, "applied": START + 29, "size": 9}
        self.rollback = {"id": 31, "submit": START + 40, "applied": START + 47, "size": group_size}
        late = bug == "late"
        self.escrows = {
            101: {"created": START + 21, "slots": [HOSTS[0], HOSTS[1], HOSTS[2], HOSTS[0], HOSTS[3]],
                  "settled": START + 355 if late else START + 35, "costs": [300, 0, 120, 0, 0],
                  "signed": [0, 1] if bug == "few_signatures" else [0, 1, 2, 3]},
            102: {"created": START + 31, "slots": [HOSTS[i % 5] for i in range(5 if bug == "b5" else 9)],
                  "settled": START + 38, "costs": [0] * (5 if bug == "b5" else 9), "signed": list(range(8))},
        }
        self.requests = []
        self.lock = threading.Lock()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, args=(0.05,), daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()

    # --- chain state by height ---
    def group_size(self, height):
        if self.change["applied"] <= height < self.rollback["applied"]:
            return self.change["size"]
        if height >= self.rollback["applied"] and self.bug == "no_rollback":
            return self.change["size"]
        return self.start_size

    def params(self, height):
        extra = self.bug == "extra_param" and height >= self.change["applied"]
        return {
            "epoch_params": {"epoch_length": str(LENGTH), "poc_stage_duration": "4"},
            "devshard_escrow_params": {"group_size": self.group_size(height),
                                       "max_escrows_per_epoch": 25 if extra else 20,
                                       "allowed_creator_addresses": [CREATOR], "min_amount": "1000000000"},
            "fee_params": {"minimum_fee": "1"},
        }

    def epoch(self, height):
        # The epoch number switches at the end of P+19.
        return EPOCH + (height >= START + LENGTH + 20) - (height < START + 20)

    def payouts(self, escrow_id):
        """(per-address payout, refund) as the chain computes it; the `divisor` bug splits fees by 9."""
        escrow = self.escrows[escrow_id]
        slots = self.settle_slots(escrow_id)
        divisor = 9 if self.bug == "divisor" and escrow_id == 101 else len(slots)
        share, remainder = divmod(FEES, divisor)
        paid = {}
        for slot, cost in enumerate(escrow["costs"]):
            extra = 1 if remainder > 0 else 0
            remainder -= extra
            paid[slots[slot]] = paid.get(slots[slot], 0) + cost + share + extra
        return paid, AMOUNT - sum(paid.values())

    def settle_slots(self, escrow_id):
        slots = self.escrows[escrow_id]["slots"]
        return [HOSTS[5]] + slots[1:] if self.bug == "slots" and escrow_id == 101 else slots

    def settles(self, escrow_id):
        return not (self.bug == "rejected" and escrow_id == 101)

    def in_epoch(self, escrow_id):
        return self.epoch(self.escrows[escrow_id]["settled"] - 1) == self.epoch(self.escrows[escrow_id]["created"])

    def escrow_doc(self, escrow_id, height):
        escrow = self.escrows.get(escrow_id)
        if escrow is None or height < escrow["created"]:
            return {"found": False}
        settled = self.settles(escrow_id) and height >= escrow["settled"]
        slots = self.settle_slots(escrow_id) if settled else escrow["slots"]
        return {"found": True, "escrow": {"id": str(escrow_id), "epoch_index": str(self.epoch(escrow["created"])),
                                          "creator": CREATOR, "amount": str(AMOUNT), "model_id": "Qwen/Qwen3-0.6B",
                                          "slots": slots, "settled": settled}}

    def participant(self, address, height):
        coins = 0
        for escrow_id, escrow in self.escrows.items():
            if self.settles(escrow_id) and self.in_epoch(escrow_id) and height >= escrow["settled"]:
                coins += self.payouts(escrow_id)[0].get(address, 0)
        return {"participant": {"address": address, "status": "ACTIVE", "coin_balance": str(1000 + coins),
                                "current_epoch_stats": {"earned_coins": str(coins)}}}

    # --- transactions and proposals ---
    def settle_hash(self, escrow_id):
        return "%064X" % (0x5E7 * 1000 + escrow_id)

    def settle_tx(self, escrow_id):
        escrow = self.escrows[escrow_id]
        slots = self.settle_slots(escrow_id)
        msg = {"@type": SETTLE, "escrow_id": str(escrow_id), "settler": CREATOR, "fees": str(FEES), "nonce": "12",
               "state_root_and_protocol_version": "v5",
               "host_stats": [{"slot_id": i, "cost": str(cost), "missed": 0} for i, cost in enumerate(escrow["costs"])],
               "signatures": [{"slot_id": i, "signature": "c2ln"} for i in escrow["signed"]]}
        if not self.settles(escrow_id):
            return {"tx": {"body": {"messages": [msg]}}, "tx_response": {
                "height": str(escrow["settled"]), "code": 1105, "events": [],
                "raw_log": "insufficient quorum: 4 slot votes, need 7"}}
        paid, refund = self.payouts(escrow_id)
        events = []
        if not self.in_epoch(escrow_id):
            for address in slots:
                if paid.pop(address, 0):
                    events.append(self._transfer(address, self.payouts(escrow_id)[0][address]))
        events.append(self._transfer(CREATOR, refund - (self.bug == "refund")))
        total = AMOUNT - refund
        events.append({"type": "devshard_escrow_settled", "attributes": [
            {"key": "escrow_id", "value": str(escrow_id)}, {"key": "total_payout", "value": str(total)},
            {"key": "fees", "value": str(FEES)}, {"key": "remainder", "value": str(refund)},
            {"key": "msg_index", "value": "0"}]})
        events.append({"type": "transfer", "attributes": [
            {"key": "recipient", "value": "gonka1feecollector"}, {"key": "sender", "value": CREATOR},
            {"key": "amount", "value": "5ngonka"}]})
        return {"tx": {"body": {"messages": [msg]}},
                "tx_response": {"height": str(escrow["settled"]), "code": 0, "raw_log": "", "events": events}}

    @staticmethod
    def _transfer(recipient, amount):
        return {"type": "transfer", "attributes": [
            {"key": "recipient", "value": recipient}, {"key": "sender", "value": MODULE},
            {"key": "amount", "value": "%dngonka" % amount}, {"key": "msg_index", "value": "0"}]}

    def proposal(self, proposal_id):
        item = self.change if proposal_id == self.change["id"] else self.rollback
        params = self.params(item["applied"] - 1)
        params["devshard_escrow_params"]["group_size"] = item["size"]
        if self.bug == "extra_param" and item is self.change:
            params["devshard_escrow_params"]["max_escrows_per_epoch"] = 25
        rejected = self.bug == "no_rollback" and item is self.rollback
        return {"proposal": {"id": str(proposal_id), "title": "Group size %d" % item["size"],
                             "status": "PROPOSAL_STATUS_REJECTED" if rejected else "PROPOSAL_STATUS_PASSED",
                             "voting_end_time": "2026-10-01T10:00:30Z", "final_tally_result": {"yes_count": "383"},
                             "messages": [{"@type": "/inference.inference.MsgUpdateParams", "params": params}]}}

    def tx_search(self, query):
        def found(txs, total=None):
            return {"result": {"txs": txs, "total_count": str(len(txs) if total is None else total)}}
        match = re.fullmatch(r"devshard_escrow_created\.escrow_id='(\d+)'", query)
        if match and int(match.group(1)) in self.escrows:
            escrow_id = int(match.group(1))
            return found([{"hash": "%064X" % escrow_id, "height": str(self.escrows[escrow_id]["created"]),
                           "tx_result": {"code": 0, "events": []}}])
        match = re.fullmatch(r"devshard_escrow_settled\.escrow_id='(\d+)'", query)
        if match and int(match.group(1)) in self.escrows and self.settles(int(match.group(1))):
            escrow_id = int(match.group(1))
            return found([{"hash": self.settle_hash(escrow_id), "height": str(self.escrows[escrow_id]["settled"]),
                           "tx_result": {"code": 0, "events": []}}])
        match = re.fullmatch(r"submit_proposal\.proposal_id='(\d+)'", query)
        if match:
            item = self.change if int(match.group(1)) == self.change["id"] else self.rollback
            return found([{"hash": "%064X" % item["id"], "height": str(item["submit"]), "tx_result": {"code": 0}}])
        if re.fullmatch(r"tx\.height=\d+ AND message\.action='%s'" % re.escape(SETTLE), query):
            return found([], 1)
        if re.fullmatch(r"devshard_escrow_created\.epoch_index='\d+'", query):
            return found([], self.created_in_epoch)
        if query.startswith("message.sender="):
            return found([], self.creator_settlements)
        return found([])

    def reply(self, method, target, height):
        path, query = urlsplit(target).path, parse_qs(urlsplit(target).query)
        if method != "GET":
            return 405, {"error": "GET only"}
        if height is not None and height > self.head:
            return 400, {"code": 2, "message": "cannot query with height in the future"}
        at = self.head if height is None else height
        if path == "/chain-rpc/status":
            return 200, {"result": {"sync_info": {"latest_block_height": str(self.head)}}}
        if path == API + "/params":
            return 200, {"params": self.params(at)}
        if path == API + "/get_current_epoch":
            return 200, {"epoch": str(self.epoch(at))}
        if path == API + "/epoch_info":
            cycle = START + LENGTH * ((at - START) // LENGTH)
            return 200, {"block_height": str(at), "latest_epoch": {"index": str(self.epoch(at)),
                                                                   "poc_start_block_height": str(cycle)},
                         "params": {"epoch_params": {"epoch_length": str(LENGTH)}}}
        if path == "%s/epoch_group_data/%d" % (API, EPOCH):
            return 200, {"epoch_group_data": {"epoch_index": str(EPOCH), "poc_start_block_height": str(START)}}
        match = re.fullmatch(API + r"/devshard_escrow/(\d+)", path)
        if match:
            return 200, self.escrow_doc(int(match.group(1)), at)
        match = re.fullmatch(API + r"/participant/(gonka1\w+)", path)
        if match:
            return 200, self.participant(match.group(1), at)
        if path == "/chain-rpc/tx_search":
            return 200, self.tx_search(query["query"][0].strip('"'))
        match = re.fullmatch(r"/chain-api/cosmos/tx/v1beta1/txs/([0-9A-F]{64})", path)
        if match:
            for escrow_id in self.escrows:
                if match.group(1) == self.settle_hash(escrow_id):
                    return 200, self.settle_tx(escrow_id)
            return 404, {"code": 5, "message": "tx not found"}
        match = re.fullmatch(r"/chain-api/cosmos/gov/v1/proposals/(\d+)", path)
        if match:
            return 200, self.proposal(int(match.group(1)))
        if path == "/chain-api/cosmos/gov/v1/params/voting":
            return 200, {"params": {"voting_period": "30s", "quorum": "0.334", "threshold": "0.5",
                                    "min_deposit": [{"denom": "ngonka", "amount": "1000000"}]}}
        if path == "/chain-api/cosmos/staking/v1beta1/validators":
            return 200, {"validators": [{"operator_address": "gonkavaloper1" + "a" * 38, "tokens": "300"},
                                        {"operator_address": "gonkavaloper1" + "b" * 38, "tokens": "200"}]}
        if path == "/a/v1/status":
            return 200, {"devshards": [{"id": "101", "active": True, "phase": "active", "chain_phase": "Inference"}],
                         "capacity": {"total_weight": 100}}
        return 404, {"code": 5, "message": "unknown path %s" % path}

    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def _serve(self, method):
                raw = self.headers.get("x-cosmos-block-height")
                height = int(raw) if raw else None
                with fake.lock:
                    fake.requests.append({"method": method, "path": self.path, "height": height,
                                          "authorization": self.headers.get("Authorization")})
                    status, body = fake.reply(method, self.path, height)
                    body = copy.deepcopy(body)
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self._serve("GET")

            def do_POST(self):
                self._serve("POST")

        return Handler
