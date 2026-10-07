#!/usr/bin/env python3
"""Run the frozen two-pass document workload through explicit public TLS ingress."""
import argparse
import contextlib
import fcntl
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import time
from urllib.parse import urlsplit

SPEC = importlib.util.spec_from_file_location("transport", Path(__file__).with_name("devshard-transport.py"))
t = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(t)
w, require = t.workload, t.require
CHAIN = "gonka-devnet-community"
ARCHIVE = "fa9f30775abfc14c40ac8d8a9bae7159f6193cd820f3dfac06a60170cd8b48a1"
ARCHIVE_URL = "https://github.com/gonka-ai/gonka/releases/download/devshard/v5.0.2/devshardd.zip"


def get_json(base, path):
    parsed = urlsplit(base)
    require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password
            and not parsed.query and not parsed.fragment, "TLS observation base required")
    connection = http.client.HTTPSConnection(parsed.hostname, parsed.port or 443, timeout=5)
    try:
        connection.request("GET", parsed.path.rstrip("/") + path, headers={"Connection": "close"})
        response = connection.getresponse()
        body = response.read(t.MAX_BODY + 1)
        require(response.status == 200 and len(body) <= t.MAX_BODY, "observation HTTP/size failure")
        return w.decode(body)
    finally:
        connection.close()


def own_escrow(payload, creator):
    require(payload.get("found") is True and isinstance(payload.get("escrow"), dict), "chain escrow missing")
    escrow = payload["escrow"]
    require(escrow.get("creator") == creator and escrow.get("model_id") == w.MODEL,
            "wrong escrow owner/model")
    require(escrow.get("slots"), "chain escrow has no slots")
    return escrow


def eligible(status, admission):
    if admission.get("available") is not True:
        return False
    capacity = status.get("capacity", {}).get("models", {}).get(w.MODEL, {})
    if not (capacity.get("routable") is True and float(capacity.get("current_weight", 0)) > 0):
        return False
    active = [item for item in status.get("devshards", []) if item.get("active") is True]
    return bool(active) and any(
        item.get("phase") == "active" and item.get("requests_blocked") is False
        and item.get("chain_phase") == "Inference"
        and item.get("confirmation_poc_phase", "") in
        ("", "NORMAL_OPERATION", "CONFIRMATION_POC_INACTIVE", "CONFIRMATION_POC_COMPLETED")
        for item in active)


def execute(config, campaign, run_number, wall_seconds=1200):
    require(type(run_number) is int and run_number in (1, 2), "run must be 1 or 2")
    require(60 <= wall_seconds <= w.WALL_SECONDS, "finite wall deadline required")
    require(set(config["endpoints"]) == set(config["secret_files"]) == set(config["creators"]) == {"A", "B"},
            "explicit A/B bindings required")
    require(len(set(config["creators"].values())) == 2 and all(
        re.fullmatch(r"gonka1[a-z0-9]+", value) for value in config["creators"].values()), "distinct creator addresses required")
    transport = t.PublicTransport(config["endpoints"], config["secret_files"])
    campaign = Path(campaign)
    require(campaign.is_absolute() and campaign == campaign.resolve(), "absolute nonsymlink campaign required")
    require(campaign.parent.is_dir() and stat.S_IMODE(campaign.parent.stat().st_mode) == 0o700,
            "private campaign parent required")
    locks = Path(config["lock_directory"])
    require(locks.is_absolute() and locks == locks.resolve(), "absolute nonsymlink shared lock directory required")
    locks.mkdir(mode=0o700, exist_ok=True)
    require(not locks.is_symlink() and stat.S_IMODE(locks.stat().st_mode) == 0o700, "private lock directory required")
    bindings = {"endpoints": config["endpoints"], "creators": config["creators"], "chain_base": config["chain_base"],
                "lock_directory": str(locks),
                "corpus_sha256": w.CORPUS_HASH, "archive_sha256": ARCHIVE, "contract": "gdc-public-workload/1"}
    with contextlib.ExitStack() as stack:
        for endpoint in sorted(config["endpoints"].values()):
            path = locks / (hashlib.sha256(endpoint.encode()).hexdigest() + ".lock")
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            lock = stack.enter_context(os.fdopen(fd, "a+"))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        campaign.mkdir(mode=0o700, exist_ok=True)
        require(stat.S_IMODE(campaign.stat().st_mode) == 0o700, "private campaign required")
        manifest_path = campaign / "manifest.json"
        if manifest_path.exists():
            require(w.decode(manifest_path.read_bytes()) == bindings, "campaign binding drift")
        else:
            with manifest_path.open("x") as output:
                output.write(json.dumps(bindings, indent=2) + "\n")
        seen = set()
        if run_number == 2:
            previous = w.decode((campaign / "run-1/summary.json").read_bytes())
            require(previous["outcome"] == "PASS" and len(previous["requests"]) == 40, "first pass incomplete")
            seen.update(row["response"]["id"] for row in previous["requests"])
        directory = campaign / f"run-{run_number}"
        directory.mkdir(mode=0o700, exist_ok=False)
        events = stack.enter_context((directory / "events.jsonl").open("x"))

        def retain(kind, **fields):
            events.write(json.dumps({"kind": kind, "at": time.time(), **fields}, ensure_ascii=False) + "\n")
            events.flush()
            os.fsync(events.fileno())

        summary = {"run": run_number, "outcome": "INCONCLUSIVE", "scope": "external routing, response shape and attribution",
                   "factual_review": "PENDING", "requests": [], "automatic_retries": 0}
        deadline = time.monotonic() + wall_seconds
        wires = w.payloads()
        try:
            for name, address in config["creators"].items():
                retain("balance-before", gateway=name, value=get_json(config["chain_base"],
                    "/chain-api/cosmos/bank/v1beta1/balances/" + address + "/by_denom?denom=ngonka"))
            params = get_json(config["chain_base"], "/chain-api/productscience/inference/inference/params")
            retain("params", value=params)
            versions = params["params"]["devshard_escrow_params"]["approved_versions"]
            require([entry for entry in versions if entry.get("name") == "v5"] ==
                    [{"name": "v5", "binary": ARCHIVE_URL, "sha256": ARCHIVE}], "official v5 approval differs")
            for item in w.schedule(run_number):
                name = item["gateway"]
                base = config["endpoints"][name]
                while True:
                    require(time.monotonic() < deadline - 60, "run deadline; no new dispatch")
                    status = get_json(base, "/v1/status")
                    admission = get_json(base, "/v1/admission-status")
                    retain("preflight", request_id=item["request_id"], status=status, admission=admission)
                    if eligible(status, admission):
                        break
                    time.sleep(min(5, max(0, deadline - time.monotonic())))
                chain = get_json(config["chain_base"], "/chain-rpc/status")
                retain("chain", value=chain)
                require(chain["result"]["node_info"]["network"] == CHAIN and
                        chain["result"]["sync_info"]["catching_up"] is False, "wrong or catching-up chain")
                before = {}
                for runtime in status["devshards"]:
                    if runtime.get("active") is True:
                        identifier = str(runtime["id"])
                        require(identifier.isdecimal(), "invalid escrow ID")
                        value = get_json(config["chain_base"], "/chain-api/productscience/inference/inference/devshard_escrow/" + identifier)
                        retain("escrow-before", gateway=name, value=value)
                        before[identifier] = own_escrow(value, config["creators"][name])
                wire = wires[item["case"], item["stream"]]
                retain("intent", item=item, payload=w.decode(wire), payload_sha256=hashlib.sha256(wire).hexdigest())
                result = transport.send(name, wire, min(deadline, time.monotonic() + 60), item["request_id"])
                retain("response", request_id=item["request_id"], result=result)
                require(result["http_status"] == 200 and result["body_complete"] and not result["transport_error"],
                        "completion failed; retained, never retried")
                parsed = w.response(result["body"], item["stream"])
                require(parsed["id"] not in seen, "duplicate/cached response ID")
                seen.add(parsed["id"])
                identifier = parsed["escrow_id"]
                if identifier not in before:
                    value = get_json(config["chain_base"], "/chain-api/productscience/inference/inference/devshard_escrow/" + identifier)
                    retain("escrow-after", gateway=name, value=value)
                    own_escrow(value, config["creators"][name])
                header = result["response_headers"].get("X-Devshard-Id")
                require(header is None or header == identifier, "header/body escrow mismatch")
                row = {**item, "response": parsed, "elapsed_seconds": result["elapsed_seconds"],
                       "ttft_seconds": result["ttft_seconds"]}
                summary["requests"].append(row)
                retain("terminal", outcome="PASS", **row)
                print(json.dumps({"request": item["request_id"], "id": parsed["id"], "stream": item["stream"]}), flush=True)
            summary["outcome"] = "PASS"
            for name, address in config["creators"].items():
                retain("balance-after", gateway=name, value=get_json(config["chain_base"],
                    "/chain-api/cosmos/bank/v1beta1/balances/" + address + "/by_denom?denom=ngonka"))
        except Exception as error:
            summary.update(outcome="FAIL", reason=str(error), exception=type(error).__name__)
            retain("stop", **summary)
        finally:
            with (directory / "summary.json").open("x") as output:
                output.write(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
        return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--campaign", required=True, type=Path)
    parser.add_argument("--run", required=True, type=int, choices=(1, 2))
    parser.add_argument("--wall-seconds", type=int, default=1200)
    args = parser.parse_args()
    os.umask(0o077)
    result = execute(w.decode(args.config.read_bytes()), args.campaign, args.run, args.wall_seconds)
    print(json.dumps({key: value for key, value in result.items() if key != "requests"}))
    raise SystemExit(0 if result["outcome"] == "PASS" else 1)


if __name__ == "__main__":
    main()
