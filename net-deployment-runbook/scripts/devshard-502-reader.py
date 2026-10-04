#!/usr/bin/env python3
"""Read-only source adapter for the owned, timestamp-free 5.0.2 A/B fixture."""

import hashlib
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import json
import sys
import threading
import time


SPEC = importlib.util.spec_from_file_location("observe", Path(__file__).resolve().parents[1] / "04-ops/devshard-observe.py")
o = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(o)
w, t, require = o.w, o.t, o.require
CHAIN = "gonka-test-ds502-isolated"
CLI_HASH = "8054d66ead3d9a5e69f2ef3888e0fbc5f71b4aca62a17c08f2d9f60a8bd21a97"
HELPERS = {
    "mock-chain": "c2e848220fae7e8d717482f704a3770e926b5f4b1fe0a97996fb7ccf0da4b9f6",
    "mock-dapi": "addbeb7cafc2e1ca780c331f965ba3188645b7f752cac3db29f39b04d4f2760e",
    "mock-openai": "395ced7fae5913d37166ddbe35c3cd3d49bf8814a6be662840c09627ab5ef357",
}
HELPER_ARTIFACT_SETS = {
    "original": HELPERS,
    # Separate qualification of test helpers only, original runtime pins stay fixed
    "eddae498-go1.27.1": {
        "mock-chain": "0aa0df9a3260ec38073c44e88aaf88a485be26da51e5ae7d5c39322f75ea3fc6",
        "mock-dapi": "3be398e43f9f517b67eab08172a4dc2ca524b56b5f35f0ff70d0b0beec36ee5a",
        "mock-openai": "c03215bfb3615c87cc95213b8ba5648f0f183057f2ae231921308b229603c28a",
    },
}


class Reader:
    def __init__(self, root, prepared_sha256, cli, retain, context="default", helper_artifact_set="original"):
        self.root, self.cli, self.retain, self.context = Path(root), Path(cli), retain, context
        require(helper_artifact_set in HELPER_ARTIFACT_SETS, "unknown qualified helper artifact set")
        self.helper_artifact_set = helper_artifact_set
        self.helpers = dict(HELPER_ARTIFACT_SETS[helper_artifact_set])
        require(re.fullmatch(r"[a-zA-Z0-9_.-]+", context) is not None, "explicit Docker context required")
        raw = (self.root / "prepared.json").read_bytes()
        require(hashlib.sha256(raw).hexdigest() == prepared_sha256, "prepared fixture binding drift")
        self.prepared = w.decode(raw)
        require(all(self.prepared["helpers"].get(service.replace("-", "")) == digest
                    for service, digest in self.helpers.items()), "prepared helper artifact set differs")
        require(w.decode((self.root / "started.json").read_bytes())["prepared_sha256"] == prepared_sha256,
                "started fixture binding drift")
        require(self.prepared["two_gateways"] is True and self.prepared["initial_version"] == "5.0.2" and
                self.prepared["source"] == "eddae498572a43408232b22f2da25e64d30b9669",
                "fresh official-source A/B fixture required")
        self.project = self.prepared["project"]
        require(re.fullmatch(r"ds502-fixture-[a-f0-9]{12}", self.project) is not None, "invalid fixture owner")
        for path, expected in [("config.yaml", self.prepared["config_sha256"]),
                               ("compose.json", self.prepared["compose_sha256"]),
                               *( ("compose-" + name + ".json", digest)
                                  for name, digest in self.prepared["gateway_compose_sha256"].items())]:
            require(hashlib.sha256((self.root / path).read_bytes()).hexdigest() == expected, "fixture input drift")
        require(hashlib.sha256(self.cli.read_bytes()).hexdigest() == CLI_HASH, "verified official query CLI required")
        config = (self.root / "config.yaml").read_text()
        require("chain_id: " + CHAIN + "\n" in config and "    next_poc_start_block_height: 100000\n" in config,
                "unsupported isolated epoch configuration")
        slots = re.findall(r"^participants:\n    - address: (gonka1[a-z0-9]+)\n", config, re.MULTILINE)
        require(len(slots) == 1, "single fixture Host binding required")
        self.slot = slots[0]
        self.network = self.project + "_fixture"
        self.samples, self.sample_error = [], None
        self.mutex, self.stop, self.thread = threading.Lock(), threading.Event(), None
        self.addresses = {}
        self.transport = None

    def command(self, args, deadline, retain=True):
        started = time.time()
        remaining = deadline - time.monotonic()
        require(remaining > 0, "source command deadline")
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=remaining)
            receipt = {"started_at": started, "observed_at": time.time(), "command": args,
                       "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
        except subprocess.TimeoutExpired as error:
            receipt = {"started_at": started, "observed_at": time.time(), "command": args,
                       "error": "TimeoutExpired", "stdout": (error.stdout or b"").decode(errors="replace"),
                       "stderr": (error.stderr or b"").decode(errors="replace")}
        if retain:
            self.retain("read-command", receipt=receipt)
        if receipt.get("returncode") != 0:
            raise t.ObservationError(receipt)
        require(len(receipt["stdout"]) <= t.MAX_BODY, "source response too large")
        return receipt

    def docker(self, args, deadline):
        return self.command(["docker", "--context", self.context, *args], deadline)["stdout"].strip()

    def inspect(self, service, deadline):
        container = self.project + "-" + service + "-1"
        template = ('{"running":{{json .State.Running}},"image":{{json .Image}},'
                    '"owner":{{json (index .Config.Labels "org.gonka.test-lab.owner")}},'
                    '"scope":{{json (index .Config.Labels "org.gonka.test-lab.scope")}},'
                    '"networks":{{json .NetworkSettings.Networks}},'
                    '"fresh_inference":"{{range .Config.Env}}{{if eq . "DEVSHARD_CHAT_CACHE_MAX_BYTES=1"}}enabled{{end}}{{end}}"}')
        observed = w.decode(self.docker(["inspect", "--format", template, container], deadline))
        owner = self.project + ("-" + service[0] if service in ("a-gateway", "b-gateway") else "")
        require(observed["running"] is True and observed["owner"] == owner and observed["scope"] == "ds502-fixture",
                "fixture container ownership/running state differs")
        require(self.network in observed["networks"], "fixture network attachment missing")
        address = observed["networks"][self.network]["IPAddress"]
        t.endpoint("http://" + address + ":8081")
        if service in self.addresses:
            require(self.addresses[service] == address, "fixture container address changed")
        self.addresses[service] = address
        if service in ("a-gateway", "b-gateway", "versiond-0"):
            if service != "versiond-0" and self.prepared.get("fresh_inference"):
                require(observed.get("fresh_inference") == "enabled", "running fresh-inference policy differs")
            image = self.prepared["images"][1 if service == "versiond-0" else 0]["id"]
            require(observed["image"] == image, "fixture official image changed")
        if service in HELPERS:
            digest = self.docker(["exec", container, "sha256sum", "/proc/1/exe"], deadline).split()[0]
            require(digest == self.helpers[service], "running helper differs from qualified exact source")
        return container

    def get(self, service, port, path, deadline, retain=True):
        base = "http://" + self.addresses[service] + ":" + str(port)
        t.endpoint(base)
        remaining = deadline - time.monotonic()
        receipt = self.command(["curl", "--silent", "--show-error", "--noproxy", "*", "--proto", "=http",
                                "--connect-timeout", "5", "--max-time", str(max(.001, remaining)),
                                "--max-filesize", str(t.MAX_BODY), "--write-out", "\n%{http_code}", base + path],
                               deadline, retain)
        body, status = receipt["stdout"].rsplit("\n", 1)
        require(status == "200", "read-only fixture HTTP failed")
        return {"started_at": receipt["started_at"], "observed_at": receipt["observed_at"],
                "ok": True, "value": w.decode(body), "receipt": receipt}

    def query(self, query, deadline):
        receipt = self.command([str(self.cli), "--home", "/tmp/ds502-query-home", "query", "inference", *query,
                                "--grpc-addr", self.addresses["mock-chain"] + ":9090", "--grpc-insecure",
                                "--chain-id", CHAIN, "--output", "json"], deadline)
        return w.decode(receipt["stdout"])

    def __enter__(self):
        try:
            deadline = time.monotonic() + 30
            require(self.docker(["network", "inspect", "--format", "{{json .Internal}}", self.network], deadline) == "true",
                    "owned internal-only fixture network required")
            for service in (*HELPERS, "versiond-0", "a-gateway", "b-gateway"):
                self.inspect(service, deadline)
            self.transport = t.Transport({name: "http://" + self.addresses[name.lower() + "-gateway"] + ":8081"
                                          for name in ("A", "B")},
                                         {name: self.root / ("operator-" + name.lower()) / "gateway.env" for name in ("A", "B")})
            self.thread = threading.Thread(target=self.poll, daemon=True)
            self.thread.start()
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                with self.mutex:
                    if self.sample_error is not None:
                        raise self.sample_error
                    samples = list(self.samples)
                if samples:
                    height = o.uint(samples[-1]["value"]["result"]["sync_info"]["latest_block_height"], 1)
                    try:
                        o.measured_intervals(samples, CHAIN, height, time.time())
                    except ValueError:
                        pass
                    else:
                        return self
                self.stop.wait(.2)
            raise TimeoutError("isolated block-window warmup")
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *unused):
        self.stop.set()
        if self.thread is not None:
            self.thread.join(6)
            require(not self.thread.is_alive(), "block sampler did not stop")

    def poll(self):
        try:
            while not self.stop.is_set():
                sample = self.get("mock-chain", 26657, "/status", time.monotonic() + 3, retain=False)
                with self.mutex:
                    self.samples.append(sample)
                    self.samples = self.samples[-600:]
                self.stop.wait(.2)
        except Exception as error:
            with self.mutex:
                self.sample_error = error

    def read(self, kind, subject, deadline):
        started = time.time()
        if kind == "status":
            # A single poll snapshot binds the subsequent interval window to this height.
            with self.mutex:
                if self.sample_error is not None:
                    raise self.sample_error
                self.window = list(self.samples)
            require(self.window, "missing measured block window")
            return self.window[-1]
        if kind == "blocks":
            value, started = self.window, self.window[-1]["observed_at"]
        elif kind == "epoch":
            value = {"stub": self.get("mock-dapi", 9100, "/v1/epochs/latest", deadline)["value"],
                     "revision": self.get("mock-chain", 9191, "/testenv/revision", deadline)["value"]}
        elif kind == "params":
            value = self.query(["epoch-info"], deadline)["params"]
        elif kind == "escrow":
            value = self.query(["show-devshard-escrow", str(o.uint(subject, 1))], deadline)
        elif kind == "gateway":
            require(subject in ("A", "B"), "unknown gateway")
            self.inspect(subject.lower() + "-gateway", deadline)
            value = self.transport.observe(subject, "/v1/admin/devshards", deadline)["value"]
        elif kind == "hosts":
            for service in HELPERS:
                self.inspect(service, deadline)
            container = self.inspect("versiond-0", deadline)
            script = ('for p in /proc/[0-9]*/exe; do target=$(readlink "$p") || continue; '
                      'case "$target" in /opt/versiond/bin/v5/*/devshardd) sha256sum "$p";; esac; done')
            actual = self.docker(["exec", container, "sh", "-c", script], deadline).splitlines()
            require(len(actual) == 1 and actual[0].split()[0] == w.ARTIFACT, "one actual official v5 Host executable required")
            proof = {"time": started, "container": container, "executable": actual,
                     "helper_sha256": self.helpers, "helper_artifact_set": self.helper_artifact_set,
                     "prepared_sha256": hashlib.sha256(w.canonical(self.prepared)).hexdigest()}
            self.retain("host-proof", receipt=proof)
            value = {self.slot: {"model": w.MODEL, "artifact_sha256": w.ARTIFACT, "context_tokens": 1152,
                                "context_source": "mock-unbounded", "receipt_sha256": hashlib.sha256(w.canonical(proof)).hexdigest()}}
        else:
            raise ValueError("unsupported isolated source")
        return {"observed_at": started, "ok": True, "value": value}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--receipt-sha256", required=True)
    parser.add_argument("--inferenced", type=Path, required=True)
    parser.add_argument("--helper-artifact-set", choices=tuple(HELPER_ARTIFACT_SETS), default="original")
    parser.add_argument("--run", type=int, choices=(1, 2), required=True)
    args = parser.parse_args()
    try:
        root = args.root.absolute()
        require(root == root.resolve() and root.name.startswith("ds502-fixture-"), "exact fixture root required")
        journal = root / "workload-campaign/events.jsonl"
        require(journal.is_file() and journal == journal.resolve(), "existing nonsymlink smoke campaign required")
        with journal.open() as stream:
            first = w.decode(stream.readline(t.MAX_BODY))
        require(first["kind"] == "campaign" and first["bindings"]["chain_id"] == CHAIN,
                "only the original isolated smoke campaign may continue")
        bindings = first["bindings"]
        receipt = w.decode((root / "prepared.json").read_bytes())
        require(receipt.get("fresh_inference") is True, "fresh-inference fixture required, preserve cached campaign")
        locks = [root / ("operator-" + name) / ".workload.lock" for name in ("a", "b")]
        with w.Campaign(root / "workload-campaign", bindings, locks) as campaign:
            with Reader(root, args.receipt_sha256, args.inferenced, campaign.append,
                        helper_artifact_set=args.helper_artifact_set) as reader:
                collector = o.Collector(reader.read, campaign.append, bindings, "lab-mock")
                result = w.Runner(campaign, collector.observe, reader.transport.send).run(args.run)
        print(json.dumps(result, sort_keys=True))
        return 0 if result["automated_outcome"] == "PASS" else 3
    except (ValueError, OSError, KeyError, subprocess.SubprocessError):
        print("Connected isolated workload refused, retain all receipts and never replay uncertain requests", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
