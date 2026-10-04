#!/usr/bin/env python3
"""Source-bound workload observations; adapters provide fresh read-only receipts."""

from datetime import datetime
import hashlib
import importlib.util
from pathlib import Path
import re
import time


SPEC = importlib.util.spec_from_file_location("transport", Path(__file__).with_name("devshard-transport.py"))
t = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(t)
w = t.workload
require = w.require


def uint(value, minimum=0):
    if isinstance(value, str):
        require(re.fullmatch(r"0|[1-9][0-9]*", value) is not None, "invalid decimal chain integer")
        value = int(value)
    require(w.integer(value, minimum), "invalid unsigned chain integer")
    return value


def block_intervals(blocks, chain_id, height, now):
    require(len(blocks) == 21, "twenty-one block headers required")
    timestamps = []
    for expected, block in zip(range(height - 20, height + 1), blocks):
        header = block["result"]["block"]["header"]
        require(header["chain_id"] == chain_id and uint(header["height"], 1) == expected,
                "block window chain/height mismatch")
        stamp = datetime.fromisoformat(header["time"].replace("Z", "+00:00"))
        require(stamp.tzinfo is not None and stamp.year >= 2020, "missing real block timestamp")
        timestamps.append(stamp.timestamp())
    intervals = [end - start for start, end in zip(timestamps, timestamps[1:])]
    require(all(w.number(n, .001) for n in intervals), "nonpositive block interval")
    require(w.number(now) and 0 <= now - timestamps[-1] <= max(w.FRESH_SECONDS, 2 * max(intervals)),
            "stale or future chain head")
    return intervals


def chain_state(status, epoch, chain_id):
    result = status["result"]
    require(result["node_info"]["network"] == chain_id and result["sync_info"]["catching_up"] is False,
            "wrong or catching-up chain")
    height = uint(result["sync_info"]["latest_block_height"], 1)
    epoch_height = uint(epoch["block_height"], 1)
    require(abs(height - epoch_height) <= 2, "epoch response is not current with chain")
    index = uint(epoch["latest_epoch"]["index"], 1)
    stages = epoch["epoch_stages"]
    require(uint(stages["epoch_index"], 1) == index, "epoch-stage identity mismatch")
    next_poc = uint(stages["next_poc_start"], 1)
    require(type(epoch["is_confirmation_poc_active"]) is bool, "unknown confirmation PoC state")
    phase = epoch["phase"]
    require(phase in ("Inference", "Voting", "PoCGenerate", "PoCGenerateWindDown",
                      "PoCValidate", "PoCValidateWindDown", "PoC"), "unknown chain phase")
    event = epoch.get("active_confirmation_poc_event")
    if event is not None:
        require(isinstance(event, dict) and event.get("phase") in
                ("CONFIRMATION_POC_INACTIVE", "CONFIRMATION_POC_GRACE_PERIOD", "CONFIRMATION_POC_GENERATION",
                 "CONFIRMATION_POC_VALIDATION", "CONFIRMATION_POC_COMPLETED"), "unknown confirmation PoC event")
    cpoc = epoch["is_confirmation_poc_active"] or bool(event and event["phase"] not in
                ("CONFIRMATION_POC_INACTIVE", "CONFIRMATION_POC_COMPLETED"))
    return {"chain_id": chain_id, "height": height, "epoch": index,
            "phase": "PoC" if phase.startswith("PoC") else phase, "cpoc": cpoc,
            "blocks_to_poc": max(0, next_poc - max(height, epoch_height))}


def measured_intervals(samples, chain_id, height, now):
    """Conservative transition bounds for the timestamp-free isolated mock only."""
    require(chain_id == "gonka-test-ds502-isolated", "measured mock intervals cannot qualify DevNet")
    require(isinstance(samples, list) and 22 <= len(samples) <= 1000, "bounded block samples required")
    previous, transitions = None, []
    for sample in samples:
        start, end = sample["started_at"], sample["observed_at"]
        require(w.number(start) and w.number(end) and 0 <= end - start <= w.FRESH_SECONDS,
                "invalid block observation bounds")
        result = sample["value"]["result"]
        require(result["node_info"]["network"] == chain_id and result["sync_info"]["catching_up"] is False,
                "block sample chain mismatch")
        current = uint(result["sync_info"]["latest_block_height"], 1)
        if previous is not None:
            require(start >= previous["observed_at"], "overlapping or reversed block observations")
            delta = current - previous["height"]
            require(delta in (0, 1), "missing or regressed block transition")
            if delta:
                transitions.append((previous["started_at"], end))
        previous = {"height": current, "started_at": start, "observed_at": end}
    require(previous["height"] == height and 0 <= now - previous["observed_at"] <= w.FRESH_SECONDS,
            "measured block head is stale or mismatched")
    require(len(transitions) >= 21, "twenty-one measured transitions required")
    transitions = transitions[-21:]
    intervals = [right[0] - left[1] for left, right in zip(transitions, transitions[1:])]
    require(all(w.number(n, .001) for n in intervals), "unresolved block interval lower bound")
    require(0 <= now - transitions[-1][1] <= w.FRESH_SECONDS, "measured chain has stopped progressing")
    return intervals


def isolated_chain_state(status, evidence, chain_id):
    require(chain_id == "gonka-test-ds502-isolated", "isolated phase evidence cannot qualify DevNet")
    result, stub, revision = status["result"], evidence["stub"], evidence["revision"]
    require(result["node_info"]["network"] == chain_id and result["sync_info"]["catching_up"] is False,
            "wrong or catching-up isolated chain")
    height, actual = uint(result["sync_info"]["latest_block_height"], 1), uint(revision["block_height"], 1)
    require(abs(height - actual) <= 2, "isolated revision is not current")
    require(uint(revision["params_block_height"], 1) == 1 and uint(revision["epoch_index"], 1) == 1 and
            uint(revision["next_poc_start_block_height"], 1) == 100000,
            "isolated revision changed; static stub no longer qualifies")
    require(uint(stub["block_height"], 1) == 150 and uint(stub["latest_epoch"]["index"], 1) == 1 and
            stub["phase"] == "Inference" and stub["is_confirmation_poc_active"] is False,
            "isolated phase stub differs")
    require(max(height, actual) < 100000, "isolated initial-epoch scope exhausted")
    return {"chain_id": chain_id, "height": height, "epoch": 1, "phase": "Inference", "cpoc": False,
            "blocks_to_poc": 100000 - max(height, actual), "phase_source": "isolated-static-stub-and-current-revision"}


def gateway_state(registry, queried, hosts, params, creator, chain, environment_kind):
    require(queried["found"] is True, "escrow not confirmed on chain")
    escrow = queried["escrow"]
    identifier = str(uint(escrow["id"], 1))
    require(escrow["creator"] == creator and escrow["model_id"] == w.MODEL and
            escrow.get("settled", False) is False, "chain escrow identity/settlement mismatch")
    entries = registry["devshards"]
    require(len(entries) == 1 and entries[0]["id"] == identifier, "one registered escrow required; no implicit selection")
    entry, settings = entries[0], registry["settings"]
    require(entry["model"] == w.MODEL and entry["route_prefix"] == "/devshard/v5", "gateway route/model drift")
    runtime = entry["runtime"]
    require(runtime["id"] == identifier and runtime["model"] == w.MODEL and runtime["session_version"] == "v5",
            "runtime identity mismatch")
    require(chain["phase"] != "Inference" or runtime["chain_phase"] == "Inference",
            "gateway/chain phase disagreement")
    require(runtime.get("confirmation_poc_phase", "CONFIRMATION_POC_INACTIVE") in
            ("CONFIRMATION_POC_INACTIVE", "CONFIRMATION_POC_COMPLETED") or chain["cpoc"],
            "gateway/chain confirmation PoC disagreement")
    require(settings["escrow_rotation"]["enabled"] is False and
            settings["escrow_rotation"]["settlement_enabled"] is False, "automatic lifecycle enabled")
    access = [row for row in settings["model_limits"] if row["model_id"] == w.MODEL]
    require(len(access) == 1 and access[0]["access_mode"] == "api_key" and
            settings["disabled"]["enabled"] is False and settings["default_model"] == w.MODEL,
            "selected-model client access differs")
    slots = escrow["slots"]
    require(isinstance(slots, list) and slots and all(isinstance(slot, str) and slot for slot in slots),
            "escrow Host slots required")
    require(set(slots) <= hosts.keys(), "missing actual Host execution/capacity evidence")
    capacities = []
    for slot in set(slots):
        host = hosts[slot]
        require(host["model"] == w.MODEL and host["artifact_sha256"] == w.ARTIFACT,
                "wrong Host artifact or served model")
        require(host["context_source"] == "serving-runtime" or
                (environment_kind == "lab-mock" and host["context_source"] == "mock-unbounded"),
                "actual serving context required; gateway output cap is not capacity")
        require(w.integer(host["context_tokens"], 1152), "insufficient serving context")
        require(isinstance(host["receipt_sha256"], str) and
                re.fullmatch(r"[0-9a-f]{64}", host["receipt_sha256"]), "Host readback receipt binding required")
        capacities.append(host["context_tokens"])
    policy = params["devshard_escrow_params"]
    require(policy["devshard_requests_enabled"] is True, "DevShard requests disabled on chain")
    max_nonce = uint(policy["max_nonce"], 1)
    require(max_nonce <= 20000, "unexpected nonce ceiling")
    # These two fields alone have omitempty in the pinned gateway runtimeStatus.
    nonce, balance = uint(runtime.get("nonce", 0)), uint(runtime.get("balance", 0))
    require(nonce < max_nonce and balance > 0, "escrow nonce/balance exhausted")
    capacity = registry["capacity"]["models"][w.MODEL]
    booleans = [entry["active"], runtime["active"], runtime["on_hold"], runtime["requests_blocked"],
                capacity["routable"], capacity["access_enabled"]]
    require(all(type(value) is bool for value in booleans), "invalid readiness flags")
    require(w.number(capacity["current_weight"]) and w.integer(capacity["routable_devshards"]),
            "invalid routable capacity")
    routable = (entry["active"] and runtime["active"] and not runtime["on_hold"] and
                not runtime["requests_blocked"] and capacity["routable"] and capacity["access_enabled"] and
                capacity["access_mode"] == "api_key" and capacity["current_weight"] > 0 and
                capacity["routable_devshards"] == 1)
    return {"creator": creator, "escrow_id": identifier, "model": w.MODEL, "protocol": "v5",
            "artifact_sha256": w.ARTIFACT, "nonce": nonce, "balance": balance, "max_nonce": max_nonce,
            "nonce_reserve": max_nonce - nonce, "request_reserve": balance,
            "active_requests": uint(runtime["active_requests"]), "pending_cleanup": uint(runtime["pending_race_cleanup"]),
            "rotation": False, "settlement": False, "context_tokens": min(capacities),
            "escrow_epoch": uint(escrow["epoch_index"], 1), "routable": routable}


class Collector:
    """Retain each source before parsing it; never renew stale receipts by wrapping them."""

    def __init__(self, read, retain, bindings, environment_kind, clock=time):
        require(environment_kind in ("lab-mock", "devnet"), "unknown environment kind")
        require(bindings["chain_id"] == ("gonka-test-ds502-isolated" if environment_kind == "lab-mock"
                                        else "gonka-devnet-community"), "environment/chain mismatch")
        self.read, self.retain, self.bindings, self.environment_kind, self.clock = read, retain, bindings, environment_kind, clock

    def observe(self, deadline):
        started = self.clock.time()
        deadline = min(deadline, self.clock.monotonic() + w.FRESH_SECONDS)
        receipts = []

        def read(kind, subject=None):
            require(self.clock.monotonic() < deadline, "observation collection deadline")
            try:
                receipt = self.read(kind, subject, deadline)
            except t.ObservationError as error:
                self.retain("source-error", source=kind, subject=subject, receipt=error.receipt)
                raise
            self.retain("source", source=kind, subject=subject, receipt=receipt)
            require(w.number(receipt["observed_at"]) and
                    0 <= self.clock.time() - receipt["observed_at"] <= w.FRESH_SECONDS,
                    "stale source receipt")
            require(receipt["ok"] is True, "source read failed")
            receipts.append(receipt)
            return receipt["value"]

        status, epoch = read("status"), read("epoch")
        project_chain = isolated_chain_state if self.environment_kind == "lab-mock" else chain_state
        chain = project_chain(status, epoch, self.bindings["chain_id"])
        headers = read("blocks", chain["height"])
        project_intervals = measured_intervals if self.environment_kind == "lab-mock" else block_intervals
        intervals = project_intervals(headers, chain["chain_id"], chain["height"], self.clock.time())
        params, hosts = read("params"), read("hosts")
        gateways = {}
        for name in ("A", "B"):
            registry = read("gateway", name)
            require(len(registry["devshards"]) == 1, "one registered escrow required")
            queried = read("escrow", str(uint(registry["devshards"][0]["id"], 1)))
            gateways[name] = gateway_state(registry, queried, hosts, params, self.bindings["creators"][name],
                                           chain, self.environment_kind)
        observed_at = min(started, *(receipt["observed_at"] for receipt in receipts))
        observation = {**chain, "observed_at": observed_at, "block_intervals": intervals, "gateways": gateways,
                       "environment_kind": self.environment_kind,
                       "sources_sha256": hashlib.sha256(w.canonical(receipts)).hexdigest()}
        require(self.clock.monotonic() < deadline, "observation collection deadline")
        w.eligibility(observation, self.clock.time(), self.bindings)
        return observation
