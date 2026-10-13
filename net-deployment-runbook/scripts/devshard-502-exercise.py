#!/usr/bin/env python3
"""Exercise create/query/register and client inference only on an owned mock chain."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


SPEC = importlib.util.spec_from_file_location("transport", Path(__file__).resolve().parents[1] / "04-ops/devshard-transport.py")
t = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(t)
w = t.workload
require = w.require
CHAIN = "gonka-test-ds502-isolated"
CLI_HASH = "8054d66ead3d9a5e69f2ef3888e0fbc5f71b4aca62a17c08f2d9f60a8bd21a97"


def record(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, sort_keys=True, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Exercise:
    def __init__(self, root, endpoints, chain, cli, evidence_name="create-use"):
        self.root, self.endpoints, self.chain, self.cli = root, endpoints, chain, cli
        require(root.is_dir() and (root / "started.json").is_file(), "started fixture required")
        receipt = w.decode((root / "prepared.json").read_bytes())
        require(receipt.get("two_gateways") is True and receipt["initial_version"] == "5.0.2", "fresh A/B fixture required")
        require(hashlib.sha256((root / "prepared.json").read_bytes()).hexdigest() ==
                w.decode((root / "started.json").read_bytes())["prepared_sha256"], "started preparation binding drift")
        for endpoint in (*endpoints.values(), chain):
            t.endpoint(endpoint)
        for name, endpoint in endpoints.items():
            body = (root / ("compose-" + name.lower() + ".json")).read_bytes()
            require(hashlib.sha256(body).hexdigest() == receipt["gateway_compose_sha256"][name.lower()], "gateway composition drift")
            port = int(w.decode(body)["services"]["gateway"]["environment"]["DEVSHARD_PORT"])
            require(t.endpoint(endpoint)[1] == port, "gateway port differs from prepared composition")
        require(hashlib.sha256(cli.read_bytes()).hexdigest() == CLI_HASH, "verified official query CLI required")
        self.secrets = {name: w.settings.instances.secrets(root / ("operator-" + name.lower()) / "gateway.env") for name in ("A", "B")}
        require(not set(self.secrets["A"]) & set(self.secrets["B"]), "independent A/B credentials required")
        require(evidence_name.startswith(("create-use", "smoke")) and Path(evidence_name).name == evidence_name,
                "private evidence basename required")
        self.output = root / evidence_name
        self.output.mkdir(mode=0o700)
        self.counter = 0

    def save(self, kind, value):
        self.counter += 1
        record(self.output / f"{self.counter:03d}-{kind}.json", value)

    def http(self, endpoint, method, path, key=None, payload=None):
        t.endpoint(endpoint)
        require(method == "GET" or (method == "POST" and path in
                ("/v1/admin/escrows", "/v1/admin/settings", "/v1/chat/completions")), "unsupported fixture operation")
        config = "" if key is None else f'header = "Authorization: Bearer {key}"\n'
        with tempfile.TemporaryDirectory() as directory:
            body = Path(directory) / "body"
            args = ["curl", "--silent", "--show-error", "--noproxy", "*", "--proto", "=http",
                    "--connect-timeout", "5", "--max-time", "60", "--max-filesize", str(t.MAX_BODY),
                    "--config", "-", "--request", method, "--output", str(body), "--write-out", "%{http_code}", endpoint + path]
            if payload is not None:
                wire = Path(directory) / "wire"
                wire.write_bytes(w.canonical(payload))
                args += ["--header", "Content-Type: application/json", "--data-binary", "@" + str(wire)]
            result = subprocess.run(args, input=config, text=True, capture_output=True, timeout=65)
            raw = body.read_bytes() if body.exists() else b""
        receipt = {"method": method, "path": path, "endpoint": endpoint, "returncode": result.returncode,
                   "status": result.stdout, "body": raw.decode("utf-8", errors="replace")}
        self.save("http", receipt)
        require(result.returncode == 0 and result.stdout == "200", "fixture HTTP outcome uncertain; no retry")
        return w.decode(raw)

    def query(self, escrow_id, grpc):
        require(str(escrow_id).isdigit(), "numeric escrow ID required")
        t.endpoint("http://" + grpc)
        result = subprocess.run([str(self.cli), "--home", "/tmp/ds502-query-home", "query", "inference",
                                 "show-devshard-escrow", str(escrow_id), "--grpc-addr", grpc,
                                 "--grpc-insecure", "--chain-id", CHAIN, "--output", "json"],
                                capture_output=True, text=True, timeout=15)
        self.save("chain-query", {"escrow_id": str(escrow_id), "returncode": result.returncode, "stdout": result.stdout,
                                  "stderr": result.stderr})
        require(result.returncode == 0, "escrow query failed; no replacement mint")
        return w.decode(result.stdout)

    def create(self, name, grpc):
        endpoint, key = self.endpoints[name], self.secrets[name][1]
        before = self.http(endpoint, "GET", "/v1/admin/devshards", key)
        require(not before["devshards"], "gateway already has escrow state; no replacement mint")
        settings = before["settings"]
        require(settings["escrow_rotation"]["enabled"] is False and
                settings["escrow_rotation"]["settlement_enabled"] is False, "automatic lifecycle enabled")
        payload = {"amount": 5000000000, "model_id": w.MODEL, "private_key_env": "DEVSHARD_PRIVATE_KEY",
                   "chain_id": CHAIN, "fee_denom": "ngonka", "fee_amount": 5000, "gas_limit": 400000,
                   "register": True, "route_prefix": "/devshard/v5"}
        record(self.root / ("create-" + name + "-intent.json"), {"time": time.time(), "payload": payload})
        created = self.http(endpoint, "POST", "/v1/admin/escrows", key, payload)
        require(created.get("registered") is True and created.get("creator") and created.get("tx_hash"), "unconfirmed create response")
        escrow = self.query(created["escrow_id"], grpc)
        require(escrow["found"] is True and escrow["escrow"]["creator"] == created["creator"] and
                str(escrow["escrow"]["id"]) == str(created["escrow_id"]) and escrow["escrow"]["model_id"] == w.MODEL,
                "chain escrow binding mismatch")
        after = self.http(endpoint, "GET", "/v1/admin/devshards", key)
        require(len(after["devshards"]) == 1 and str(after["devshards"][0]["id"]) == str(created["escrow_id"]),
                "registered escrow readback mismatch")
        self.save("created-" + name, {"creation": created, "chain": escrow, "registry": after})
        return created

    def run(self, grpc):
        status = self.http(self.chain, "GET", "/status")
        require(status["result"]["node_info"]["network"] == CHAIN, "only isolated mock-chain operations are permitted")
        require(not status["result"]["sync_info"]["catching_up"], "mock chain not ready")
        created = {name: self.create(name, grpc) for name in ("A", "B")}
        require(len({row["creator"] for row in created.values()}) == 2 and
                len({str(row["escrow_id"]) for row in created.values()}) == 2, "A/B identity collision")
        self.save("terminal", {"outcome": "PASS", "scope": "isolated create/query/register", "created": created,
                               "inference": "NOT RUN", "live_acceptance": "NOT PROVEN"})
        print(json.dumps({"outcome": "PASS", "scope": "isolated create/query/register", "live_acceptance": "NOT PROVEN"}))

    def smoke(self, grpc):
        status = self.http(self.chain, "GET", "/status")
        require(status["result"]["node_info"]["network"] == CHAIN, "only isolated mock-chain operations are permitted")
        creators, escrows = {}, {}
        for name in ("A", "B"):
            endpoint, key = self.endpoints[name], self.secrets[name][1]
            state = self.http(endpoint, "GET", "/v1/admin/devshards", key)
            require(len(state["devshards"]) == 1, "one confirmed escrow per gateway required")
            escrows[name] = str(state["devshards"][0]["id"])
            chain = self.query(escrows[name], grpc)
            require(chain["found"] is True and chain["escrow"]["model_id"] == w.MODEL, "chain model mismatch")
            creators[name] = chain["escrow"]["creator"]

            class Adapter:
                def request(inner, method, path, payload=None):
                    return self.http(endpoint, method, path, key, payload)

            preview = w.settings.configure(Adapter(), w.settings.Journal(self.output / ("settings-preview-" + name)), w.MODEL)
            w.settings.configure(Adapter(), w.settings.Journal(self.output / ("settings-apply-" + name)),
                                 w.MODEL, preview["before_sha256"], True)
        bindings = {"chain_id": CHAIN, "creators": creators, "spend_caps": {"A": 5000000000, "B": 5000000000}}
        locks = [self.root / ("operator-" + name.lower()) / ".workload.lock" for name in ("A", "B")]
        secret_paths = {name: self.root / ("operator-" + name.lower()) / "gateway.env" for name in ("A", "B")}
        transport = t.Transport(self.endpoints, secret_paths)
        with w.Campaign(self.root / "workload-campaign", bindings, locks) as campaign:
            for name in ("A", "B"):
                state = transport.observe(name, "/v1/admin/devshards", time.monotonic() + 10)["value"]
                runtime = state["devshards"][0]["runtime"]
                require(runtime["id"] == escrows[name] and runtime["session_version"] == "v5" and
                        runtime["chain_phase"] == "Inference" and runtime["requests_blocked"] is False and
                        runtime["active_requests"] == runtime["pending_race_cleanup"] == 0,
                        "isolated smoke runtime not ready")
                before = {"escrow_id": escrows[name], "nonce": runtime.get("nonce", 0), "balance": runtime.get("balance", 0),
                          "request_reserve": runtime.get("balance", 0)}
                require(w.integer(before["balance"], 1), "no smoke escrow balance")
                item = {"request_id": "smoke-" + name, "gateway": name, "case": "DOC-01", "stream": name == "B", "kind_of_work": "smoke"}
                wire = w.payloads()[(item["case"], item["stream"])]
                campaign.admit(item, before, wire, time.time())
                terminal = {"request_id": item["request_id"], "gateway": name, "outcome": "INCONCLUSIVE",
                            "charged": before["request_reserve"]}
                try:
                    response = transport.send(name, wire, time.monotonic() + 60, item["request_id"])
                    campaign.append("response", request_id=item["request_id"], result=response)
                    require(response["body_complete"] and response["transport_error"] is None and response["http_status"] == 200,
                            "incomplete smoke response")
                    parsed = w.response(response["body"], item["stream"])
                    if item["stream"]:
                        require(w.number(response["ttft_seconds"]) and
                                response["ttft_seconds"] <= response["elapsed_seconds"], "invalid smoke TTFT")
                    runtime = self.drain(transport, campaign, name, item["request_id"], escrows[name])
                    require(parsed["escrow_id"] == runtime["id"] == escrows[name] and
                            before["nonce"] < parsed["nonce"] == runtime["nonce"] <= 20000 and
                            runtime["active_requests"] == runtime["pending_race_cleanup"] == 0,
                            "smoke nonce/escrow/drain mismatch")
                    charge = before["balance"] - runtime["balance"]
                    require(0 <= charge <= before["request_reserve"], "smoke balance mismatch")
                    terminal.update(outcome="PASS", charged=charge, response=parsed,
                                    elapsed_seconds=response["elapsed_seconds"], ttft_seconds=response["ttft_seconds"])
                except (Exception, KeyboardInterrupt) as error:
                    terminal["reason"] = type(error).__name__
                campaign.append("terminal", **terminal)
                require(terminal["outcome"] == "PASS", "smoke failed; retain campaign, never retry")
        self.save("terminal", {"outcome": "PASS", "scope": "isolated A/B client JSON/SSE smoke",
                               "live_acceptance": "NOT PROVEN", "workload_runs": "NOT RUN"})
        print(json.dumps({"outcome": "PASS", "scope": "isolated A/B client JSON/SSE smoke", "workload_runs": "NOT RUN"}))

    def drain(self, transport, campaign, name, request_id, escrow_id, clock=time):
        deadline = clock.monotonic() + w.DRAIN_SECONDS
        while clock.monotonic() < deadline:
            try:
                receipt = transport.observe(name, "/v1/admin/devshards", min(deadline, clock.monotonic() + 10))
            except t.ObservationError as error:
                campaign.append("smoke-readback-error", request_id=request_id, receipt=error.receipt)
                raise
            campaign.append("smoke-readback", request_id=request_id, receipt=receipt)
            state = receipt["value"]
            require(len(state["devshards"]) == 1, "smoke registry changed")
            runtime = state["devshards"][0]["runtime"]
            require(runtime["id"] == escrow_id, "smoke escrow changed")
            require(all(w.integer(runtime[key]) for key in ("active_requests", "pending_race_cleanup")),
                    "invalid smoke drain counters")
            if runtime["active_requests"] == runtime["pending_race_cleanup"] == 0:
                return runtime
            clock.sleep(min(1, max(0, deadline - clock.monotonic())))
        raise TimeoutError("smoke drain deadline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--gateway-a", required=True)
    parser.add_argument("--gateway-b", required=True)
    parser.add_argument("--chain-rpc", required=True)
    parser.add_argument("--chain-grpc", required=True)
    parser.add_argument("--inferenced", type=Path, required=True)
    parser.add_argument("--create", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--evidence-name", default="create-use")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        require(args.create != args.smoke, "select exactly one isolated create or smoke operation")
        exercise = Exercise(args.root, {"A": args.gateway_a, "B": args.gateway_b}, args.chain_rpc,
                            args.inferenced, args.evidence_name)
        if args.create:
            exercise.run(args.chain_grpc)
        else:
            exercise.smoke(args.chain_grpc)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(f"INCONCLUSIVE: {type(error).__name__}; retain all receipts, never repeat creation blindly", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
