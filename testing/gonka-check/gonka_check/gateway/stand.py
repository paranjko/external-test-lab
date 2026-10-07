"""gcheck gateway-load stand: the v5 gateway as its own process against stub hosts on the mock chain."""

import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.client import HTTPException

from . import keys

PREFIX = "gcheck-gw"
VERSION = "v5"
MODEL = "stub-model"
ADMIN_KEY = "gcheck-stand-admin"
ESCROW_ID = 1
CHAIN_ID = "gcheck-stand"
APP_HASH = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
AMOUNT = 100_000_000_000
# DevNet escrow values, read from node1.gonka-dev.net params on 2026-09-27, except the seal clock: a DevNet escrow
# ends before its records seal by the clock (3600 s), a stand of hours must not seal them either.
ESCROW = {"token_price": 1, "create_devshard_fee": 10000, "fee_per_nonce": 1000, "validation_rate": 1000,
          "vote_threshold_factor": 50, "inference_seal_grace_nonces": 50,
          "inference_seal_grace_seconds": 30 * 24 * 3600, "auto_seal_every_n_nonces": 150, "refusal_timeout": 60,
          "execution_timeout": 1920}
HOST_ENV = {"token_price": "TOKEN_PRICE", "create_devshard_fee": "CREATE_DEVSHARD_FEE",
            "fee_per_nonce": "FEE_PER_NONCE",
            "validation_rate": "VALIDATION_RATE", "vote_threshold_factor": "VOTE_THRESHOLD_FACTOR",
            "inference_seal_grace_nonces": "INFERENCE_SEAL_GRACE_NONCES",
            "inference_seal_grace_seconds": "INFERENCE_SEAL_GRACE_SECONDS",
            "auto_seal_every_n_nonces": "AUTO_SEAL_EVERY_N_NONCES", "refusal_timeout": "REFUSAL_TIMEOUT",
            "execution_timeout": "EXECUTION_TIMEOUT"}
IMAGES = {"chain": ("devshard/Dockerfile.mock-chain", None, {}),
          "host": ("devshard/Dockerfile.host", None, {"DEVSHARD_VERSION": VERSION}),
          "gateway": ("devshard/Dockerfile", "devshardctl-runtime", {"DEVSHARD_VERSION": VERSION})}
SIZE = re.compile(r"^\s*([\d.]+)\s*([kKMGT]?i?B)\s*$")
UNITS = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "KiB": 2 ** 10, "MiB": 2 ** 20,
         "GiB": 2 ** 30, "TiB": 2 ** 40}
MEMINFO = "/proc/meminfo"
NETEM_IMAGE = PREFIX + "-netem:alpine3.23"
NETEM_DOCKERFILE = "FROM alpine:3.23\nRUN apk add --no-cache iproute2\n"
NORMAL_STOPS = ("routing stopped at the nonce cap", "one request")
LOG_OPTS = ["--log-driver", "json-file", "--log-opt", "max-size=20m", "--log-opt", "max-file=2"]


class StandError(Exception):
    pass


def docker(args, check=True, timeout=None):
    reply = subprocess.run(["docker"] + args, capture_output=True, text=True, timeout=timeout)
    if check and reply.returncode != 0:
        raise StandError("docker %s: %s" % (args[0], (reply.stderr or reply.stdout).strip()[-300:]))
    return reply


def image(name, commit):
    return "%s-%s:%s" % (PREFIX, name, commit[:12])


def build_images(source, commit, log_path, netem=False):
    """Build the three images once per commit, and the netem helper when asked; existing tags are reused."""
    built = []
    with open(log_path, "a", encoding="utf-8") as log:
        if netem and docker(["image", "inspect", NETEM_IMAGE], check=False).returncode != 0:
            log.write("$ docker build -t %s -\n" % NETEM_IMAGE)
            log.flush()
            reply = subprocess.run(["docker", "build", "-t", NETEM_IMAGE, "-"], input=NETEM_DOCKERFILE.encode(),
                                   stdout=log, stderr=subprocess.STDOUT)
            if reply.returncode != 0:
                raise StandError("docker build %s failed, see %s" % (NETEM_IMAGE, log_path))
            built.append(NETEM_IMAGE)
        for name, (dockerfile, target, args) in IMAGES.items():
            tag = image(name, commit)
            if docker(["image", "inspect", tag], check=False).returncode == 0:
                continue
            argv = ["docker", "build", "-t", tag, "-f", os.path.join(source, dockerfile)]
            if target:
                argv += ["--target", target]
            for key, value in sorted(args.items()):
                argv += ["--build-arg", "%s=%s" % (key, value)]
            log.write("$ %s\n" % " ".join(argv + [source]))
            log.flush()
            reply = subprocess.run(argv + [source], stdout=log, stderr=subprocess.STDOUT,
                                   env=dict(os.environ, DOCKER_BUILDKIT="1"))
            if reply.returncode != 0:
                raise StandError("docker build %s failed, see %s" % (tag, log_path))
            built.append(tag)
    return built


class Names:
    def __init__(self, run_id, groups, hosts, concurrency):
        base = "%s-%s-g%d-h%d-c%d" % (PREFIX, run_id[-4:], groups, hosts, concurrency)
        self.network = base
        self.chain = base + "-chain"
        self.gateway = base + "-gateway"
        self.base = base

    def host(self, j):
        return "%s-host-%d" % (self.base, j)


def slot_hosts(groups, hosts):
    """Slot s belongs to host s mod H, so every host holds about G/H slots."""
    return [s % hosts for s in range(groups)]


def seed(groups, hosts, names):
    owners = slot_hosts(groups, hosts)
    escrow = dict(ESCROW, id=ESCROW_ID, creator=keys.USER_ADDRESS, amount=AMOUNT, epoch_index=1, app_hash=APP_HASH,
                  model_id=MODEL, slots=[keys.host(j)[1] for j in owners])
    return {"chain_id": CHAIN_ID, "block_height": 150, "epoch": {"index": 1, "poc_start_block_height": 100},
            "params": {"logprobs_mode": "raw", "devshard_requests_enabled": True, "max_nonce": 20000,
                       "validation_rate": ESCROW["validation_rate"],
                       "vote_threshold_factor": ESCROW["vote_threshold_factor"]},
            "participants": [{"address": keys.host(j)[1], "inference_url": "http://%s:8080" % names.host(j)}
                             for j in range(hosts)],
            "escrows": [escrow],
            "epoch_groups": [{"epoch_index": 1, "model_id": MODEL, "validation_threshold_value": 50,
                              "validation_threshold_exponent": 0}],
            "hosts": [{"private_key_hex": keys.host(j)[0]} for j in range(hosts)],
            "user": {"private_key_hex": keys.private_key(keys.USER_NUMBER)}}


def host_env(j, groups, hosts, names, delay_ms=0):
    owners = slot_hosts(groups, hosts)
    env = {"DEVSHARD_E2E": "1", "DEVSHARD_ALLOW_PRIVATE_ADDRESSES": "true", "DEVSHARD_ESCROW_ID": str(ESCROW_ID),
           "DEVSHARD_HOST_INDEX": str(j), "DEVSHARD_HOST_PRIVATE_KEYS": ",".join(keys.host(o)[0] for o in owners),
           "DEVSHARD_PEER_URLS": ",".join("http://%s:8080" % names.host(o) for o in owners),
           "DEVSHARD_USER_PRIVATE_KEY": keys.private_key(keys.USER_NUMBER), "DEVSHARD_ESCROW_AMOUNT": str(AMOUNT),
           "DEVSHARD_EPOCH_ID": "1", "DEVSHARD_STUB_INFERENCE_DELAY_MS": str(delay_ms)}
    env.update(("DEVSHARD_" + HOST_ENV[key], str(value)) for key, value in ESCROW.items())
    return env


def gateway_env(names):
    return {"DEVSHARD_E2E": "1", "DEVSHARD_ESCROW_ID": str(ESCROW_ID),
            "DEVSHARD_PRIVATE_KEY": keys.private_key(keys.USER_NUMBER),
            "DEVSHARD_CHAIN_GRPC": "%s:9090" % names.chain, "DEVSHARD_PUBLIC_API": "http://%s:9191" % names.chain,
            "DEVSHARD_PARAMS_SOURCE": "chain", "DEVSHARD_ADMIN_API_KEY": ADMIN_KEY, "DEVSHARD_API_KEYS": "",
            "DEVSHARD_STORAGE_DIR": "/data/gateway", "DEVSHARD_MODEL": MODEL, "GATEWAY_MAX_TOKENS_CAP": "4096",
            "DEVSHARD_ALLOW_PRIVATE_ADDRESSES": "true", "DEVSHARD_REQUIRE_HEIGHT_SEED": "false",
            "DEVSHARD_ESCROW_ROTATION_ENABLED": "false"}


def write_env(path, env):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("".join("%s=%s\n" % item for item in sorted(env.items())))


def up_commands(names, commit, config_dir, data_dir, hosts, gateway_cpus=None, host_cpus=None):
    """docker argv lists that start the stand, in order; the cpus pin the gateway and the rest to their own cores."""
    uid = "%d:%d" % (os.getuid(), os.getgid())
    rest = ["--cpuset-cpus", host_cpus] if host_cpus else []
    out = [["network", "create", names.network],
           ["run", "-d", "--name", names.chain, "--network", names.network] + LOG_OPTS + rest +
           ["-v", "%s:/app/seed.yaml:ro" % os.path.join(config_dir, "seed.yaml"),
            "-e", "MOCK_CHAIN_CONFIG=/app/seed.yaml", image("chain", commit)]]
    for j in range(hosts):
        out.append(["run", "-d", "--name", names.host(j), "--network", names.network] + LOG_OPTS + rest +
                   ["--env-file", os.path.join(config_dir, "host-%d.env" % j), image("host", commit)])
    out.append(["run", "-d", "--name", names.gateway, "--network", names.network, "--user", uid] + LOG_OPTS +
               (["--cpuset-cpus", gateway_cpus] if gateway_cpus else []) +
               ["--env-file", os.path.join(config_dir, "gateway.env"), "-v", "%s:/data" % data_dir,
                "-p", "127.0.0.1::8080", image("gateway", commit)])
    return out


def down(names, hosts):
    containers = [names.gateway, names.chain] + [names.host(j) for j in range(hosts)]
    docker(["rm", "-f"] + containers, check=False)
    docker(["network", "rm", names.network], check=False)


def wait(what, probe, timeout_s, step_s=0.5):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if probe():
            return
        time.sleep(step_s)
    raise StandError("%s not ready after %ds" % (what, timeout_s))


def http(method, url, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": "Bearer " + ADMIN_KEY}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            return reply.status, reply.read()
    except urllib.error.HTTPError as error:
        try:
            return error.code, error.read()
        except (OSError, HTTPException):
            return error.code, b""
    except (OSError, HTTPException) as error:
        return 0, str(error).encode()


def logs(name, tail=None):
    reply = docker(["logs"] + (["--tail", str(tail)] if tail else []) + [name], check=False)
    return reply.stdout + reply.stderr


def delay_commands(names, hosts, delay_ms):
    """Every packet a stub host sends waits delay_ms, so each gateway-to-host round trip gains that much."""
    return [["run", "--rm", "--network", "container:" + names.host(j), "--cap-add", "NET_ADMIN", NETEM_IMAGE,
             "tc", "qdisc", "add", "dev", "eth0", "root", "netem", "delay", "%dms" % delay_ms] for j in range(hosts)]


def start(names, commit, config_dir, data_dir, hosts, delay_ms=0, gateway_cpus=None, host_cpus=None):
    """Start the stand; returns the gateway base URL on 127.0.0.1."""
    for args in up_commands(names, commit, config_dir, data_dir, hosts, gateway_cpus, host_cpus):
        docker(args)
        if args[0] == "run" and args[3] == names.chain:
            wait("mock chain", lambda: "gRPC listening" in logs(names.chain), 60)
    for j in range(hosts):
        wait("host %d" % j, lambda j=j: docker(["exec", names.host(j), "curl", "-sf", "http://localhost:8080/health"],
                                                 check=False).returncode == 0, 120)
    for args in (delay_commands(names, hosts, delay_ms) if delay_ms else []):
        docker(args)
    published = docker(["port", names.gateway, "8080/tcp"]).stdout.strip().splitlines()
    if not published:
        raise StandError("gateway port is not published")
    base = "http://127.0.0.1:%s" % published[0].rsplit(":", 1)[1]
    wait("gateway", lambda: http("GET", base + "/v1/status", timeout=5)[0] == 200, 120)
    return base


def metric(text, name):
    match = re.search(r"^%s(?:\{[^}]*\})?\s+([0-9.eE+-]+)\s*$" % re.escape(name), text, re.M)
    return float(match.group(1)) if match else None


def to_bytes(text):
    match = SIZE.match(text)
    return float(match.group(1)) * UNITS.get(match.group(2), 1) if match else None


def stats(names, hosts):
    """Gateway traffic and the memory of the stub hosts together, from one docker stats call."""
    containers = [names.gateway] + [names.host(j) for j in range(hosts)]
    try:
        reply = docker(["stats", "--no-stream", "--format", "{{.Name}}\t{{.MemUsage}}\t{{.NetIO}}"] + containers,
                       check=False, timeout=60)
    except subprocess.TimeoutExpired:
        return {}
    out = {}
    for line in reply.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3 or "/" not in parts[2]:
            continue
        used = to_bytes(parts[1].split("/")[0]) or 0
        if parts[0] == names.gateway:
            rx, tx = (to_bytes(part) or 0 for part in parts[2].split("/")[:2])
            out.update(rx_mb=rx / 1e6, tx_mb=tx / 1e6)
        else:
            out["hosts_mem_mb"] = out.get("hosts_mem_mb", 0) + used / 2 ** 20
    return out


def exited(names, hosts):
    """Stand containers that are not running, with exit code and whether memory ran out."""
    return stopped([names.gateway, names.chain] + [names.host(j) for j in range(hosts)])


def stopped(containers):
    try:
        reply = docker(["inspect", "--format", "{{.Name}} {{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}"]
                       + containers, check=False, timeout=60)
    except subprocess.TimeoutExpired:
        return []
    out = []
    for line in reply.stdout.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[1] != "running":
            out.append("%s %s %s%s" % (parts[0].lstrip("/"), parts[1], parts[2],
                                       " (out of memory)" if parts[3] == "true" else ""))
    return out


def docker_root():
    """Where Docker keeps container logs, or None."""
    try:
        return docker(["info", "--format", "{{.DockerRootDir}}"], check=False, timeout=30).stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        return None


def memory_left():
    """Share of the machine memory still available, or None where /proc/meminfo is absent."""
    try:
        with open(MEMINFO, encoding="ascii") as handle:
            values = dict(line.split(":", 1) for line in handle if ":" in line)
        return int(values["MemAvailable"].split()[0]) / int(values["MemTotal"].split()[0])
    except (OSError, KeyError, ValueError, ZeroDivisionError):
        return None


def memory_guard(floor=0.05):
    left = memory_left()
    if left is not None and left < floor:
        return "machine memory below %d%%" % round(floor * 100)
    return None


def tree_bytes(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def nonce_of(base):
    code, body = http("GET", base + "/v1/status", timeout=10)
    try:
        return int(json.loads(body)["nonce"]) if code == 200 else None
    except (ValueError, KeyError, TypeError):
        return None


def sample(base, names, hosts, data_dir, started):
    _code, text = http("GET", base + "/metrics", timeout=10)
    text = text.decode("utf-8", "replace")
    usage = stats(names, hosts)
    return {"t_s": round(time.monotonic() - started, 1), "nonce": nonce_of(base),
            "cpu_s": metric(text, "process_cpu_seconds_total"),
            "rss_mb": (metric(text, "process_resident_memory_bytes") or 0) / 2 ** 20,
            "rx_mb": usage.get("rx_mb", 0.0), "tx_mb": usage.get("tx_mb", 0.0),
            "storage_mb": tree_bytes(data_dir) / 2 ** 20, "hosts_mem_mb": usage.get("hosts_mem_mb")}


class Load:
    """Threads that send unique chat completions until the escrow nonce reaches the target."""

    def __init__(self, base, concurrency, target, run_tag):
        self.base, self.concurrency, self.target, self.tag = base, concurrency, target, run_tag
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.codes, self.latencies, self.reason = {}, [], None
        self.sent, self.failed_in_row = 0, 0

    def one(self, number):
        body = {"model": MODEL, "max_tokens": 32,
                "messages": [{"role": "user", "content": "gcheck stand %s request %d" % (self.tag, number)}]}
        started = time.monotonic()
        code, reply = http("POST", self.base + "/v1/chat/completions", body)
        with self.lock:
            self.codes[code] = self.codes.get(code, 0) + 1
            self.latencies.append(time.monotonic() - started)
            self.failed_in_row = 0 if code == 200 else self.failed_in_row + 1
            failing = self.failed_in_row >= 50
        if code == 502 and b"high_nonce" in reply:
            self.finish("routing stopped at the nonce cap")
        elif failing:
            self.finish("50 failed requests in a row, last %s" % code)

    def finish(self, reason):
        with self.lock:
            if not self.reason:
                self.reason = reason
        self.stop.set()

    def worker(self):
        while not self.stop.is_set():
            with self.lock:
                self.sent += 1
                number = self.sent
            self.one(number)

    def run(self, on_sample=None, every_s=5.0, max_s=None, stall_s=600, guard=None):
        threads = [threading.Thread(target=self.worker, daemon=True) for _ in range(self.concurrency)]
        for thread in threads:
            thread.start()
        started = moved = time.monotonic()
        best = None
        try:
            while not self.stop.wait(every_s):
                nonce = on_sample() if on_sample else nonce_of(self.base)
                now = time.monotonic()
                if nonce is not None and (best is None or nonce > best):
                    best, moved = nonce, now
                reason = guard() if guard else None
                if reason:
                    self.finish(reason)
                elif nonce is not None and nonce >= self.target:
                    self.finish("nonce %d reached" % nonce)
                elif max_s and now - started > max_s:
                    self.finish("time limit")
                elif stall_s and now - moved > stall_s:
                    self.finish("no nonce progress for %d s" % stall_s)
        except KeyboardInterrupt:
            self.finish("interrupted")
        for thread in threads:
            thread.join(timeout=150)
        return self.reason


def quorum(groups):
    """Signature weight finalization needs: StateMachine.QuorumThreshold in devshard/state."""
    return 2 * groups // 3 + 1


def finalize(base, groups, path=None):
    """Finalize the session; the reply is the settlement payload, saved to path."""
    started = time.monotonic()
    code, body = http("POST", base + "/v1/finalize", {}, timeout=3600)
    out = {"code": code, "seconds": round(time.monotonic() - started, 3), "bytes": len(body),
           "quorum": quorum(groups), "signatures": None, "host_stats": None, "nonce": None}
    if path:
        with open(path, "wb") as handle:
            handle.write(body)
    try:
        data = json.loads(body)
        out.update(signatures=len(data.get("signatures") or []), host_stats=len(data.get("host_stats") or []),
                   nonce=data.get("nonce"))
    except (ValueError, AttributeError):
        if code != 200:
            out["error"] = body.decode("utf-8", "replace")[-300:]
    return out


def percentile(values, share):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))] if ordered else None


def summarize(groups, hosts, concurrency, load, samples, final, error=None, stop=None, stopped=()):
    first, last = (samples[0], samples[-1]) if samples else ({}, {})
    nonce = last.get("nonce") or 0
    span = (last.get("t_s") or 0) - (first.get("t_s") or 0)
    moved = nonce - (first.get("nonce") or 0)
    codes = load.codes if load else {}
    latencies = load.latencies if load else []
    ok = codes.get(200, 0)
    cpu = (last.get("cpu_s") or 0) - (first.get("cpu_s") or 0)
    hosts_mem = [s["hosts_mem_mb"] for s in samples if s.get("hosts_mem_mb") is not None]
    return {"groups": groups, "hosts": hosts, "concurrency": concurrency, "requests": sum(codes.values()),
            "ok": ok, "codes": {str(code): count for code, count in sorted(codes.items())}, "nonce": nonce,
            "nonces_per_request": round(nonce / ok, 2) if ok else None,
            "wall_s": round(span, 1), "nonces_per_s": round(moved / span, 2) if span and moved > 0 else None,
            "cpu_ms_per_nonce": round(cpu * 1000 / moved, 3) if moved > 0 else None,
            "peak_rss_mb": round(max((s.get("rss_mb") or 0) for s in samples), 1) if samples else None,
            "storage_mb": round(last.get("storage_mb") or 0, 1),
            "tx_kb_per_nonce": round((last.get("tx_mb") or 0) * 1000 / nonce, 2) if nonce else None,
            "rx_kb_per_nonce": round((last.get("rx_mb") or 0) * 1000 / nonce, 2) if nonce else None,
            "hosts_peak_mb": round(max(hosts_mem), 1) if hosts_mem else None,
            "p50_s": percentile(latencies, 0.5), "p95_s": percentile(latencies, 0.95),
            "finalize": final, "stop": stop or error or (load.reason if load else None), "error": error,
            "stopped": list(stopped)}


def judge(summary, target):
    check = "stand_g%d_h%d_c%d" % (summary["groups"], summary["hosts"], summary["concurrency"])
    errors = summary["requests"] - summary["ok"] - int(summary["codes"].get("502", 0))
    final = summary["finalize"] or {}
    stopped = summary.get("stopped") or []
    gateway_down = [item for item in stopped if "-gateway " in item]
    if summary.get("error"):
        value, reason = "BLOCKED", summary["error"]
    elif summary["stop"] == "interrupted":
        value, reason = "INCONCLUSIVE", "interrupted at nonce %d" % summary["nonce"]
    elif gateway_down:
        value, reason = "FAIL", "gateway stopped at nonce %d: %s" % (summary["nonce"], gateway_down[0])
    elif stopped:
        value, reason = "INCONCLUSIVE", "stand stopped at nonce %d: %s" % (summary["nonce"], "; ".join(stopped))
    elif (summary["stop"] or "").startswith("50 failed"):
        value, reason = "FAIL", "%s at nonce %d: %s" % (summary["stop"], summary["nonce"], summary["codes"])
    elif summary["nonce"] < target and summary["stop"] not in NORMAL_STOPS:
        value, reason = "INCONCLUSIVE", "stopped at nonce %d of %d: %s" % (summary["nonce"], target, summary["stop"])
    elif errors > max(10, summary["requests"] // 100):
        value, reason = "FAIL", "%d failed requests of %d: %s" % (errors, summary["requests"], summary["codes"])
    elif final.get("code") != 200:
        value, reason = "FAIL", ("finalize answered %s %s" % (final.get("code"), final.get("error", ""))).strip()
    elif (final.get("signatures") or 0) < final.get("quorum", 0):
        value, reason = "FAIL", "finalize returned %s signatures, quorum %d" % (final.get("signatures"),
                                                                              final["quorum"])
    else:
        value, reason = "PASS", "nonce %d, %.2f nonces per request, finalize %.1f s, %d signatures, quorum %d" % (
            summary["nonce"], summary["nonces_per_request"] or 0, final["seconds"], final["signatures"],
            final["quorum"])
    return {"check": check, "maps": [], "verdict": value, "reason": reason, "records": []}
