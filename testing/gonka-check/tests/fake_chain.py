"""Local stand-in for a chain REST and RPC node, fed by recorded mainnet reads of epoch 408."""

import base64
import copy
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

API = "/chain-api/productscience/inference/inference"
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "escrow-408.json")


def load_fixture():
    with open(FIXTURE, encoding="utf-8") as handle:
        return json.load(handle)


class FakeChain:
    """poc_ahead: the PoC of the next epoch runs, so epoch_info shows it while escrows still go to this epoch."""

    def __init__(self, busy_first=0, fail_paths=(), epoch_switch_after=None, base64_events=False,
                 extra_members=0, poc_ahead=False, error_body=None):
        self.data = load_fixture()
        self.epoch = int(self.data["root"]["epoch_index"])
        self.height = int(self.data["epoch_info"]["block_height"])
        self.busy_first = busy_first
        self.fail_paths = tuple(fail_paths)
        self.epoch_switch_after = epoch_switch_after
        self.base64_events = base64_events
        self.poc_ahead = poc_ahead
        self.error_body = error_body or {"error": "failing on purpose"}
        self.epoch_reads = 0
        self.requests = []
        self.lock = threading.Lock()
        if extra_members:
            group = self.data["models"]["MiniMaxAI/MiniMax-M2.7"]
            for i in range(extra_members):
                group["validation_weights"].append({"member_address": "gonka1fake%034d" % i, "weight": "0"})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, args=(0.05,), daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()

    def reply(self, method, target):
        parts = urlsplit(target)
        path, query = parts.path, parse_qs(parts.query)
        if method != "GET":
            return 405, {"error": "GET only"}
        if len(self.requests) <= self.busy_first:
            return 503, {"error": "busy"}
        if any(fragment in target for fragment in self.fail_paths):
            return 500, self.error_body
        if path == "/chain-api/cosmos/base/tendermint/v1beta1/node_info":
            return 200, {"application_version": {"version": "v0.2.15",
                                                 "git_commit": "4d687ed6782bcea3931d2d9135bf322f84e190ab"}}
        if path == API + "/get_current_epoch":
            self.epoch_reads += 1
            switched = self.epoch_switch_after is not None and self.epoch_reads > self.epoch_switch_after
            return 200, {"epoch": str(self.epoch + switched)}
        if path == API + "/epoch_info":
            self.height += 1
            body = copy.deepcopy(self.data["epoch_info"])
            body["block_height"] = str(self.height)
            if self.poc_ahead:
                body["latest_epoch"]["index"] = str(self.epoch + 1)
            return 200, body
        if path == API + "/params":
            return 200, {"params": {"devshard_escrow_params": {"group_size": self.data["group_size"]}}}
        match = re.fullmatch(API + r"/epoch_group_data/(\d+)", path)
        if match:
            return self.group(int(match.group(1)), query.get("model_id", [""])[0])
        if path == "%s/excluded_participants/%d" % (API, self.epoch):
            return 200, {"items": self.data["excluded"]}
        match = re.fullmatch(API + r"/devshard_escrow/(\d+)", path)
        if match:
            for escrow in self.data["escrows"]:
                if int(escrow["id"]) == int(match.group(1)):
                    return 200, {"escrow": escrow, "found": True}
            return 200, {"found": False}
        if path == "/chain-rpc/tx_search":
            return 200, self.tx_search(query)
        return 404, {"code": 5, "message": "unknown path %s" % path}

    def group(self, epoch, model):
        if epoch == self.epoch:
            group = self.data["root"] if not model else self.data["models"].get(model)
            return (200, {"epoch_group_data": group}) if group else (404, {"code": 5, "message": "no such model"})
        if epoch == self.epoch + 1 and self.poc_ahead:
            # The next epoch's groups exist from its PoC start, still without weights.
            empty = {"epoch_index": str(epoch), "total_weight": "0", "validation_weights": [],
                     "sub_group_models": [] if model else list(self.data["models"]), "model_id": model}
            return 200, {"epoch_group_data": empty}
        return 404, {"code": 5, "message": "no epoch group %d" % epoch}

    def tx_search(self, query):
        wanted = re.search(r"epoch_index='(\d+)'", query["query"][0]).group(1)
        found = [escrow for escrow in self.data["escrows"] if escrow["epoch_index"] == wanted]
        found.sort(key=lambda escrow: int(escrow["id"]), reverse='"desc"' in query.get("order_by", [""]))

        def text(value):
            return base64.b64encode(value.encode()).decode() if self.base64_events else value
        txs = [{"hash": "F" * 64, "tx_result": {"events": [{"type": "devshard_escrow_created", "attributes": [
            {"key": text("escrow_id"), "value": text(escrow["id"])},
            {"key": text("epoch_index"), "value": text(escrow["epoch_index"])}]}]}} for escrow in found[:1]]
        return {"jsonrpc": "2.0", "id": -1, "result": {"txs": txs, "total_count": str(len(found))}}

    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def _serve(self, method):
                with fake.lock:
                    fake.requests.append({"method": method, "path": self.path,
                                          "authorization": self.headers.get("Authorization")})
                    status, body = fake.reply(method, self.path)
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
