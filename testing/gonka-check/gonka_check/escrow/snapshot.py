"""Snapshot of the effective epoch: weights per model, group size, exclusions and the real escrows of the epoch."""

import base64
import json
import os
from urllib.parse import quote, urlencode

from ..record import utc_now
from ..source import RequestCapReached, SourceError
from .slots import sorted_entries

API = "/chain-api/productscience/inference/inference"
NODE_INFO = "/chain-api/cosmos/base/tendermint/v1beta1/node_info"
FORMAT = 1
MAX_MISSES_IN_A_ROW = 3


class ChainReads:
    """Chain reads for the snapshot; every body also goes whole to the sink (chain.jsonl)."""

    def __init__(self, source, sink):
        self.source = source
        self.sink = sink

    def _json(self, path, kind, key=""):
        body = self.source.get_json(path, kind)
        self.sink(kind, key, body)
        return body

    def node_version(self):
        try:
            body = self._json(NODE_INFO, "node_info")
        except RequestCapReached:
            raise
        except SourceError:
            return {"version": None, "commit": None}
        app = body.get("application_version") or {}
        return {"version": app.get("version"), "commit": app.get("git_commit")}

    def epoch(self):
        """The effective epoch: the one CreateDevshardEscrow writes new escrows to."""
        body = self._json(API + "/get_current_epoch", "current_epoch")
        try:
            return int(body["epoch"])
        except (KeyError, TypeError, ValueError):
            raise SourceError("get_current_epoch: unexpected body")

    def epoch_info(self):
        body = self._json(API + "/epoch_info", "epoch_info")
        try:
            return {"height": int(body["block_height"]), "latest_epoch": int(body["latest_epoch"]["index"]),
                    "epoch_length": int(body["params"]["epoch_params"]["epoch_length"])}
        except (KeyError, TypeError, ValueError):
            raise SourceError("epoch_info: unexpected body")

    def group_size(self):
        body = self._json(API + "/params", "params")
        try:
            return int(body["params"]["devshard_escrow_params"]["group_size"])
        except (KeyError, TypeError, ValueError):
            raise SourceError("params: no devshard_escrow_params.group_size")

    def group(self, epoch, model=""):
        path = "%s/epoch_group_data/%d" % (API, epoch)
        if model:
            path += "?" + urlencode({"model_id": model})
        body = self._json(path, "epoch_group", model)
        try:
            data = body["epoch_group_data"]
            weights = {vw["member_address"]: int(vw["weight"]) for vw in data.get("validation_weights") or []}
            return {"epoch": int(data["epoch_index"]), "total_weight": int(data["total_weight"]),
                    "poc_start": int(data.get("poc_start_block_height") or 0),
                    "weights": weights, "models": list(data.get("sub_group_models") or [])}
        except (KeyError, TypeError, ValueError):
            raise SourceError("epoch_group_data %s: unexpected body" % (model or "root"))

    def excluded(self, epoch):
        body = self._json("%s/excluded_participants/%d" % (API, epoch), "excluded")
        return [{"address": item.get("address"), "reason": item.get("reason"),
                 "height": _int(item.get("exclusion_block_height"))} for item in body.get("items") or []]

    def escrow(self, escrow_id):
        """The escrow, or None when the chain answers found:false; anything else is an error."""
        reply = self.source.get("%s/devshard_escrow/%d" % (API, escrow_id))
        body = reply.json if isinstance(reply.json, dict) else None
        if reply.ok and body is not None and not body.get("found"):
            return None
        if not reply.ok or body is None or not isinstance(body.get("escrow"), dict):
            raise SourceError("devshard_escrow %d: HTTP %s" % (escrow_id, reply.status or reply.transport_error))
        self.sink("escrow", str(escrow_id), body)
        return body["escrow"]

    def escrow_edge(self, epoch, order):
        """(first or last escrow id created in the epoch, number created) from the tx index."""
        query = urlencode({"query": '"devshard_escrow_created.epoch_index=\'%d\'"' % epoch,
                           "per_page": 1, "page": 1, "order_by": '"%s"' % order}, quote_via=quote)
        try:
            body = self._json("/chain-rpc/tx_search?" + query, "tx_search", order)
        except RequestCapReached:
            raise
        except SourceError as error:
            raise SourceError("%s; without the tx index pass --escrow-ids FIRST-LAST" % error.reason)
        try:
            result = body["result"]
            ids = [int(value) for tx in result["txs"] for value in _event_values(tx, "escrow_id")]
            return (min(ids) if order == "asc" else max(ids)) if ids else None, int(result["total_count"])
        except (KeyError, TypeError, ValueError):
            raise SourceError("tx_search: unexpected body")


def _int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _text(value):
    # Older CometBFT returns event keys and values in base64.
    if value is None:
        return ""
    try:
        decoded = base64.b64decode(value, validate=True).decode()
        return decoded if decoded.isprintable() else value
    except (ValueError, UnicodeDecodeError):
        return value


def _event_values(tx, key):
    for event in (tx.get("tx_result") or {}).get("events") or []:
        if event.get("type") != "devshard_escrow_created":
            continue
        for attribute in event.get("attributes") or []:
            name = attribute.get("key")
            if name == key or _text(name) == key:
                raw = attribute.get("value")
                yield raw if str(raw).isdigit() else _text(raw)


def probe(chain):
    """A few reads that show whether a full snapshot can run: (facts, reasons)."""
    facts, reasons = {}, []
    try:
        facts.update(chain.node_version())
        facts["epoch"] = chain.epoch()
        facts.update(chain.epoch_info())
        facts["group_size"] = chain.group_size()
        first, count = chain.escrow_edge(facts["epoch"], "asc")
        facts.update(first_escrow=first, escrows_so_far=count)
        if first is None:
            reasons.append("no escrow created in epoch %d yet" % facts["epoch"])
        elif chain.escrow(first) is None:
            reasons.append("escrow %d from the tx index is not found" % first)
    except SourceError as error:
        reasons.append(error.reason)
    return facts, reasons


def check_budget(source, low, high):
    needed = high - low + 1 + 4
    left = source.max_requests - source.requests
    if needed > left:
        raise RequestCapReached("%d escrows need about %d more requests, the cap leaves %d; pass --last N or "
                                "--max-requests" % (high - low + 1, needed, left))


def capture(chain, escrow_ids=None, last=None, log=print):
    """Read the effective epoch. escrow_ids: explicit (first, last); last: keep only the newest N escrows.

    Weights failing to read is fatal; once they are read, any stop keeps what was read and sets snap["stopped"].
    """
    epoch = chain.epoch()
    start = chain.epoch_info()
    snap = {"format": FORMAT, "taken_at": utc_now(), "chain": chain.node_version(), "epoch": epoch,
            "latest_epoch_start": start["latest_epoch"], "epoch_length": start["epoch_length"],
            "height_start": start["height"], "group_size": chain.group_size()}
    root = chain.group(epoch)
    snap["poc_start"] = root["poc_start"]
    snap["root"] = {"total_weight": root["total_weight"], "members": sorted(root["weights"], key=str.encode)}
    snap["models"] = {}
    for model in root["models"]:
        group = chain.group(epoch, model)
        entries, _ = sorted_entries(group["weights"])
        snap["models"][model] = {"total_weight": group["total_weight"], "weights": group["weights"],
                                 "dropped_non_positive": len(group["weights"]) - len(entries)}
    snap["excluded"] = chain.excluded(epoch)
    indexes = {model: {address: i for i, address in enumerate(sorted(data["weights"], key=str.encode))}
               for model, data in snap["models"].items()}
    snap.update(escrows={}, escrows_missing=[], escrows_failed=[], escrows_other_epoch=[],
                escrow_ids_given=escrow_ids is not None, height_end=None, epoch_end=None)
    try:
        if escrow_ids is None:
            first, count = chain.escrow_edge(epoch, "asc")
            newest, _ = chain.escrow_edge(epoch, "desc")
            snap["escrows_indexed"] = count
            escrow_ids = (first, newest) if first is not None and newest is not None else None
        if escrow_ids is not None:
            _read_escrows(chain, snap, indexes, escrow_ids, last, log)
        snap["epoch_end"] = chain.epoch()
        snap["height_end"] = chain.epoch_info()["height"]
    except SourceError as error:
        snap["stopped"] = error.reason
    except KeyboardInterrupt:
        snap["stopped"] = "interrupted"
    return snap


def _read_escrows(chain, snap, indexes, escrow_ids, last, log):
    low, high = escrow_ids
    if last:
        low = max(low, high - last + 1)
    snap["escrow_range"] = [low, high]
    check_budget(chain.source, low, high)
    log("escrows  reading %d..%d (%d)" % (low, high, high - low + 1))
    misses = 0
    for escrow_id in range(low, high + 1):
        snap["escrow_range"][1] = escrow_id
        try:
            escrow = chain.escrow(escrow_id)
        except RequestCapReached:
            raise
        except SourceError as error:
            snap["escrows_failed"].append(escrow_id)
            misses += 1
            if misses >= MAX_MISSES_IN_A_ROW:
                raise SourceError("%d escrow reads in a row failed, last: %s" % (misses, error.reason))
            continue
        misses = 0
        if escrow is None:
            snap["escrows_missing"].append(escrow_id)
        elif int(escrow["epoch_index"]) != snap["epoch"] or escrow.get("model_id") not in snap["models"]:
            snap["escrows_other_epoch"].append(escrow_id)
        else:
            index = indexes[escrow["model_id"]]
            snap["escrows"].setdefault(escrow["model_id"], []).append(
                [escrow_id, escrow["app_hash"], [index.get(address, address) for address in escrow["slots"]]])
        if (escrow_id - low) % 200 == 199:
            log("escrows  %d of %d read" % (escrow_id - low + 1, high - low + 1))


def write_snapshot(path, snap):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(snap, handle, indent=1, sort_keys=True)
        handle.write("\n")


def load_snapshot(path):
    if os.path.isdir(path):
        path = os.path.join(path, "snapshot.json")
    with open(path, encoding="utf-8") as handle:
        snap = json.load(handle)
    if snap.get("format") != FORMAT:
        raise ValueError("%s: snapshot format %s, expected %d" % (path, snap.get("format"), FORMAT))
    return snap, path


def escrows_of(snap, model):
    """Real escrows of a model as (id, app_hash, slot addresses)."""
    members = sorted(snap["models"][model]["weights"], key=str.encode)
    for escrow_id, app_hash, slots in snap["escrows"].get(model, []):
        yield escrow_id, app_hash, [members[slot] if isinstance(slot, int) else slot for slot in slots]
