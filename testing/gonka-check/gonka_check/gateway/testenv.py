"""gcheck gateway-load testenv: the v5 gateway against real devshardd hosts in the upstream devshard/testenv."""

import copy
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import time

from . import stand, stress

PREFIX = "gcheck-tenv"
SPARSE = stress.SPARSE + ("versioned", "versiond-router", "router-runtime")
VERSION = stand.VERSION
MODEL = "test-model"
ESCROW_ID = 1
MAX_NONCE = 20000
ROUTING_STOP = 19800
AMOUNT = 10_000_000_000
VALIDATION_RATE = 1000
POLL_INTERVAL = "60s"
CATALOG_POLL_S = "15"
GATEWAY_PORT = 38081
SUBNET_OCTET = 77
WARM_CHATS = 20
DRY_CHATS = 3
ROUTED_STOP = "routing stopped at the nonce cap"
CAP_LINE = "exceeds active cap"
DEAD_LINE = "heartbeat host dead"
CAPACITY = b"no live host capacity"
ARCHES = {"x86_64": ("amd64", "0"), "amd64": ("amd64", "0"), "aarch64": ("arm64", "1"), "arm64": ("arm64", "1")}
IMAGES = {"devshardd": ("devshard/Dockerfile", "runtime", ""),
          "devshardctl": ("devshard/Dockerfile", "devshardctl-runtime", ""),
          "versiond": ("versioned/Dockerfile", None, "versioned"),
          "versiond-router": ("versiond-router/Dockerfile", None, ""),
          "mock-chain": ("devshard/testenv/Dockerfile.mock-chain", None, ""),
          "mock-dapi": ("devshard/testenv/Dockerfile.mockdapi", None, ""),
          "mock-openai": ("devshard/testenv/Dockerfile.mockopenai", None, "")}
SERVICE_IMAGES = ("devshardctl", "versiond", "versiond-router", "mock-chain", "mock-dapi", "mock-openai")
MOCK_OPENAI_ANCHOR = "COPY devshard/ .\n"
# Alternatives whose bytes do not spell the token make every host log a warning per streamed token.
MOCK_OPENAI_FIX = ("RUN grep -q 'utf8CodeUnits(alt)' testenv/mockopenai/config.go"
                   " && sed -i '/\"bytes\": *utf8CodeUnits(alt),/d' testenv/mockopenai/config.go"
                   " && ! grep -q 'utf8CodeUnits(alt)' testenv/mockopenai/config.go\n")
LOGGING = {"driver": "local", "options": {"max-size": "20m", "max-file": "3"}}
CADENCE = re.compile(r'^devshard_gateway_heightsync_cadence_events_total\{([^}]*)\}\s+([0-9.eE+-]+)\s*$', re.M)
LABEL = '{{.Label "com.docker.compose.project"}}'


class TestenvError(stand.StandError):
    pass


def arch_of(machine=None):
    """(GOARCH, BLST_PORTABLE) for this machine."""
    machine = machine or platform.machine()
    if machine.lower() not in ARCHES:
        raise TestenvError("no build for machine %s; needs x86_64 or aarch64" % machine)
    return ARCHES[machine.lower()]


def binary_version(tag):
    return tag.rsplit("/", 1)[-1]


def image(name, commit):
    return "%s-%s:%s" % (PREFIX, name, commit[:12])


def mock_openai_dockerfile(text):
    if MOCK_OPENAI_ANCHOR not in text:
        raise TestenvError("Dockerfile.mockopenai has no %r line" % MOCK_OPENAI_ANCHOR.strip())
    return text.replace(MOCK_OPENAI_ANCHOR, MOCK_OPENAI_ANCHOR + MOCK_OPENAI_FIX, 1)


def build_argv(name, source, commit, goarch, blst, version, dockerfile=None):
    path, target, context = IMAGES[name]
    argv = ["docker", "build", "--platform", "linux/" + goarch, "-t", image(name, commit),
            "-f", dockerfile or os.path.join(source, path)]
    if target:
        argv += ["--target", target]
    args = {}
    if name == "devshardd":
        args = {"GOOS": "linux", "GOARCH": goarch, "BLST_PORTABLE": blst, "DEVSHARD_VERSION": VERSION,
                "DEVSHARD_BINARY_VERSION": version, "DEVSHARD_BUILD_TAGS": ""}
    elif name == "devshardctl":
        args = {"DEVSHARD_VERSION": VERSION}
    for key, value in sorted(args.items()):
        argv += ["--build-arg", "%s=%s" % (key, value)]
    return argv + [os.path.join(source, context) if context else source]


def build_images(source, commit, cache_dir, log_path, tag=stress.TAG, machine=None):
    """Build every image once per commit, extract devshardd for the versiond bind mount; (devshardd, built)."""
    goarch, blst = arch_of(machine)
    work = os.path.join(cache_dir, "testenv")
    os.makedirs(work, mode=0o700, exist_ok=True)
    patched = os.path.join(work, "Dockerfile.mockopenai-%s" % commit[:12])
    with open(os.path.join(source, IMAGES["mock-openai"][0]), encoding="utf-8") as handle:
        text = mock_openai_dockerfile(handle.read())
    with open(patched, "w", encoding="utf-8") as handle:
        handle.write(text)
    built = []
    with open(log_path, "a", encoding="utf-8") as log:
        for name in IMAGES:
            if stand.docker(["image", "inspect", image(name, commit)], check=False).returncode == 0:
                continue
            argv = build_argv(name, source, commit, goarch, blst, binary_version(tag),
                              patched if name == "mock-openai" else None)
            log.write("$ %s\n" % " ".join(argv))
            log.flush()
            reply = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT,
                                   env=dict(os.environ, DOCKER_BUILDKIT="1"))
            if reply.returncode != 0:
                raise TestenvError("docker build %s failed, see %s" % (image(name, commit), log_path))
            built.append(image(name, commit))
    binary = extract_devshardd(commit, work, goarch)
    check_stamp(binary, commit, binary_version(tag))
    return binary, built


def extract_devshardd(commit, work, goarch):
    """devshardd from the runtime stage; it runs inside versiond, which has the libgcc that stage lacks."""
    path = os.path.join(work, "devshardd-%s-%s" % (commit[:12], goarch))
    if os.path.isfile(path):
        return path
    name = "%s-extract-%s" % (PREFIX, secrets.token_hex(2))
    stand.docker(["create", "--name", name, image("devshardd", commit)])
    try:
        stand.docker(["cp", name + ":/usr/local/bin/devshardd", path + ".part"])
    finally:
        stand.docker(["rm", "-f", name], check=False)
    os.chmod(path + ".part", 0o755)
    os.replace(path + ".part", path)
    return path


def check_stamp(binary, commit, version):
    for flag, want in (("--print-protocol-version", VERSION), ("--print-binary-version", version)):
        reply = stand.docker(["run", "--rm", "--name", "%s-stamp-%s" % (PREFIX, secrets.token_hex(2)),
                              "--log-driver", "none", "--entrypoint", "/opt/devshard/devshardd",
                              "-v", "%s:/opt/devshard/devshardd:ro" % binary, image("versiond", commit), flag],
                             timeout=120)
        if reply.stdout.strip() != want:
            raise TestenvError("devshardd %s says %r, expected %r" % (flag, reply.stdout.strip(), want))


def skeleton(groups, hosts, devshardd, version, octet=SUBNET_OCTET):
    """config.yaml before gencompose, as JSON (YAML reads it); TODO keys get fresh test keys."""
    base = "172.30.%d" % octet
    return {"chain_id": "gonka-test", "block_height": 150,
            "epoch": {"index": 1, "poc_start_block_height": 100, "epoch_length": 400},
            "params": {"devshard_requests_enabled": True, "max_nonce": MAX_NONCE, "validation_rate": VALIDATION_RATE},
            "mock_chain": {"grpc_port": 39090, "rpc_port": 36657, "testenv_port": 39191},
            "mock_dapi": {"grpc_port": 39400, "http_port": 39100}, "mock_openai": {"http_port": 38088},
            "versiond": {"mode": "multi", "version_name": VERSION, "binary_version": version,
                         "host_binary_mount": devshardd, "poll_interval": POLL_INTERVAL},
            "versiond_router": {"port": 38080}, "devshardctl": {"port": GATEWAY_PORT}, "postgres": {"enabled": True},
            "network": {"subnet": base + ".0/24", "base_ip": base}, "escrow": {"slots": groups},
            "hosts": [{"id": "versiond-%d" % i, "private_key_hex": "TODO", "key_name": "versiond-%d" % i}
                      for i in range(hosts)],
            "user": {"private_key_hex": "TODO"}, "warm_grantee": {"private_key_hex": "TODO"},
            "escrows": [{"id": ESCROW_ID, "model_id": MODEL, "amount": AMOUNT, "validation_rate": VALIDATION_RATE}],
            "grantees": [{"granter_address": "", "message_type_url": "/inference.inference.MsgStartInference",
                          "grantees": [""]}]}


def _section(lines, name):
    start = None
    for i, line in enumerate(lines):
        if line.rstrip() == name + ":":
            start = i
        elif start is not None and line and not line[0].isspace() and not line.startswith("-"):
            return start, i
    if start is None:
        raise TestenvError("config.yaml has no %s section" % name)
    return start, len(lines)


def direct_urls(text):
    """Every participant gets its own host URL instead of the router, which would send all slots to one host.

    Returns (config text, host addresses in host order)."""
    lines = text.split("\n")
    start, end = _section(lines, "hosts")
    ids, current = {}, None
    for line in lines[start:end]:
        match = re.match(r"^\s*- id: (\S+)\s*$", line)
        if match:
            current = match.group(1)
            continue
        match = re.match(r"^\s+address: (\S+)\s*$", line)
        if match and current:
            ids[match.group(1)] = current
    start, end = _section(lines, "participants")
    patched, address = 0, None
    for i in range(start, end):
        match = re.match(r"^\s*- address: (\S+)\s*$", lines[i])
        if match:
            address = match.group(1)
            continue
        match = re.match(r"^(\s+)inference_url: \S+\s*$", lines[i])
        if match and address in ids:
            lines[i] = "%sinference_url: http://%s:8080" % (match.group(1), ids[address])
            patched += 1
    if not ids or patched != len(ids):
        raise TestenvError("config.yaml: %d participant URLs for %d hosts" % (patched, len(ids)))
    return "\n".join(lines), list(ids)


def patch_compose(spec, project, commit, uid, gateway_cpus=None, host_cpus=None):
    """The compose model of gencompose, for prebuilt images, solo hosts and loopback ports."""
    spec = copy.deepcopy(spec)
    spec["name"] = project
    services = spec["services"]
    # Solo hosts keep their sessions in sqlite; multi mode only needs Postgres in the config.
    services.pop("devshard-postgres", None)
    for name, service in services.items():
        kind = "versiond" if re.match(r"^versiond-\d+$", name) else name
        if kind not in SERVICE_IMAGES:
            raise TestenvError("compose has an unknown service %s" % name)
        service.pop("build", None)
        service.pop("ports", None)
        service.update(image=image(kind, commit), container_name="%s-%s" % (project, name), logging=LOGGING,
                       restart="no")
        depends = service.get("depends_on")
        if isinstance(depends, dict):
            depends.pop("devshard-postgres", None)
        elif isinstance(depends, list) and "devshard-postgres" in depends:
            depends.remove("devshard-postgres")
        cpus = gateway_cpus if name == "devshardctl" else host_cpus
        if cpus:
            service["cpuset"] = cpus
        env = service.setdefault("environment", {})
        if kind == "versiond":
            env.update(DEVSHARD_LOG_LEVEL="warn", VERSIOND_POLL_INTERVAL=POLL_INTERVAL)
            if name != "versiond-0":
                for network in (service.get("networks") or {}).values():
                    if isinstance(network, dict):
                        network.pop("aliases", None)
    for name in ("devshardctl", "versiond-router", "mock-dapi"):
        if name not in services:
            raise TestenvError("compose has no %s service" % name)
    gateway = services["devshardctl"]
    gateway["environment"].update(DEVSHARD_ADMIN_API_KEY=stand.ADMIN_KEY, DEVSHARD_ESCROW_ROTATION_ENABLED="false",
                                  DEVSHARD_LOG_LEVEL="info")
    gateway["user"] = uid
    gateway["ports"] = [{"target": GATEWAY_PORT, "host_ip": "127.0.0.1", "protocol": "tcp"}]
    # With more than one host in its pool the router marks every request HA and sqlite hosts refuse them.
    services["versiond-router"]["environment"].update(GONKA_HA="", VERSIOND_ROUTING_ACTIVATION_MIN_READY="1",
                                                      VERSIOND_ROUTING_CATALOG_POLL_SECONDS=CATALOG_POLL_S)
    services["mock-dapi"]["environment"].update(MOCK_DAPI_VERSION_NAME=VERSION,
                                                MOCK_DAPI_VERSION_BINARY="file:///opt/devshard/devshardd",
                                                MOCK_DAPI_VERSION_SHA256="0" * 64)
    return spec


def remove_tree(path, run=None):
    """Remove path; what the containers wrote there as root goes through a throwaway container."""
    run = run or stand.docker
    if not os.path.exists(path):
        return
    try:
        shutil.rmtree(path)
        return
    except OSError:
        pass
    parent, name = os.path.split(os.path.abspath(path))
    run(["run", "--rm", "--name", "%s-rm-%s" % (PREFIX, secrets.token_hex(2)), "--log-driver", "none",
         "-v", "%s:/w" % parent, "--entrypoint", "rm", stress.GO_IMAGE, "-rf", "/w/" + name], check=False, timeout=300)
    shutil.rmtree(path, ignore_errors=True)


def _stamp(seconds):
    return "%d.%09d" % (int(seconds), int((seconds - int(seconds)) * 1e9))


class Stack:
    """One compose project: mocks, N versiond hosts, the router and the gateway."""

    def __init__(self, run_id, groups, hosts, work_root):
        self.project = "%s-%s-g%d" % (PREFIX, run_id[-4:], groups)
        self.groups, self.hosts = groups, hosts
        self.work = os.path.join(work_root, self.project)
        self.compose_file = os.path.join(self.work, "compose.json")
        self.gateway_data = os.path.join(self.work, "data", "devshardctl")
        self.services, self.addresses = [], []

    def container(self, service):
        return "%s-%s" % (self.project, service)

    @property
    def gateway(self):
        return self.container("devshardctl")

    @property
    def router(self):
        return self.container("versiond-router")

    def host(self, i):
        return self.container("versiond-%d" % i)

    def compose(self, args, check=True, timeout=600):
        files = ["-f", self.compose_file] if os.path.isfile(self.compose_file) else []
        try:
            return stand.docker(["compose", "-p", self.project] + files + args, check=check, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise TestenvError("docker compose %s took over %d s" % (args[0], timeout)) from None

    def generate(self, source, cache_dir, devshardd, commit, version, log_path, octet=SUBNET_OCTET,
                 gateway_cpus=None, host_cpus=None):
        for sub in ["binaries", os.path.join("data", "devshardctl")] + [
                os.path.join("data", "versiond-%d" % i) for i in range(self.hosts)]:
            os.makedirs(os.path.join(self.work, sub), mode=0o700, exist_ok=True)
        config = os.path.join(self.work, "config.yaml")
        with open(config, "w", encoding="utf-8") as handle:
            json.dump(skeleton(self.groups, self.hosts, devshardd, version, octet), handle, indent=2)
        argv = stress._docker(source, cache_dir, self.project + "-gencompose", stress.go_env(None),
                              "/src/devshard/testenv", None)
        argv[-1:-1] = ["-v", "%s:/work" % self.work]
        argv += ["go", "run", "./cmd/gencompose", "-config", "/work/config.yaml", "-out", "/work/docker-compose.yml"]
        with open(log_path, "a", encoding="utf-8") as log:
            log.write("$ %s\n" % " ".join(argv))
            log.flush()
            reply = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=3600)
        if reply.returncode != 0:
            raise TestenvError("gencompose failed, see %s" % log_path)
        with open(config, encoding="utf-8") as handle:
            text, self.addresses = direct_urls(handle.read())
        with open(config, "w", encoding="utf-8") as handle:
            handle.write(text)
        model = stand.docker(["compose", "-p", self.project, "--project-directory", self.work, "-f",
                              os.path.join(self.work, "docker-compose.yml"), "config", "--format", "json"],
                             timeout=120).stdout
        spec = patch_compose(json.loads(model), self.project, commit, "%d:%d" % (os.getuid(), os.getgid()),
                             gateway_cpus, host_cpus)
        self.services = sorted(spec["services"])
        with open(self.compose_file, "w", encoding="utf-8") as handle:
            json.dump(spec, handle, indent=2)

    def _ok(self, args, timeout=30):
        try:
            return stand.docker(args, check=False, timeout=timeout).returncode == 0
        except subprocess.TimeoutExpired:
            return False

    def up(self):
        """Start the stack; returns the gateway base URL on 127.0.0.1."""
        self.compose(["up", "-d", "--no-build", "--wait"] + [s for s in self.services if s != "devshardctl"],
                     timeout=900)
        what = "router catalog admission of %s" % VERSION
        healthy = ["exec", self.router, "curl", "-sf", "-o", "/dev/null", "http://127.0.0.1:8080/%s/healthz" % VERSION]
        try:
            stand.wait(what, lambda: self._ok(healthy), 240, step_s=2)
        except stand.StandError:
            # HAProxy's watchdog aborts its worker on a starved CPU and leaves the master without a listener.
            self.compose(["restart", "versiond-router"], timeout=120)
            stand.wait(what, lambda: self._ok(healthy), 240, step_s=2)
        self.compose(["up", "-d", "--no-build", "--wait", "devshardctl"], timeout=600)
        published = stand.docker(["port", self.gateway, "%d/tcp" % GATEWAY_PORT]).stdout.strip().splitlines()
        if not published:
            raise TestenvError("gateway port is not published")
        base = "http://127.0.0.1:%s" % published[0].rsplit(":", 1)[1]
        stand.wait("gateway", lambda: stand.http("GET", base + "/v1/status", timeout=5)[0] == 200, 120)
        return base

    def down(self):
        self.compose(["down", "--volumes", "--remove-orphans", "--timeout", "10"], check=False)
        remove_tree(self.work)

    def containers(self):
        return [self.container(name) for name in self.services]

    def exited(self):
        return stand.stopped(self.containers()) if self.services else []

    def logs(self, service, tail=2000):
        return stand.logs(self.container(service), tail=tail)

    def gateway_log(self, since, until):
        try:
            reply = stand.docker(["logs", "--since", _stamp(since), "--until", _stamp(until), self.gateway],
                                 check=False, timeout=60)
        except subprocess.TimeoutExpired:
            return ""
        return reply.stdout + reply.stderr

    def stats(self):
        try:
            reply = stand.docker(["stats", "--no-stream", "--format",
                                  "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}",
                                  self.gateway] + [self.host(i) for i in range(self.hosts)], check=False, timeout=60)
        except subprocess.TimeoutExpired:
            return {}
        return parse_stats(reply.stdout)

    def diffs(self, i, low, high):
        """Nonces of the diffs host i stored between low and high, read from inside the compose network."""
        url = "http://versiond-%d:8080/sessions/%d/diffs?from=%d&to=%d" % (i, ESCROW_ID, low, high)
        try:
            reply = stand.docker(["exec", self.router, "curl", "-s", "-m", "30", url], check=False, timeout=60)
        except subprocess.TimeoutExpired:
            return None
        return diff_nonces(reply.stdout) if reply.returncode == 0 else None


def parse_stats(text):
    """docker stats lines: name, CPU %, memory, network and block I/O."""
    out = {}
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) != 5 or "/" not in parts[3] or "/" not in parts[4]:
            continue
        try:
            cpu = float(parts[1].strip().rstrip("%"))
        except ValueError:
            cpu = None
        rx, tx = (stand.to_bytes(part) or 0 for part in parts[3].split("/")[:2])
        read, write = (stand.to_bytes(part) or 0 for part in parts[4].split("/")[:2])
        out[parts[0]] = {"cpu_pct": cpu, "mem_mb": (stand.to_bytes(parts[2].split("/")[0]) or 0) / 2 ** 20,
                         "rx_mb": rx / 1e6, "tx_mb": tx / 1e6, "read_mb": read / 1e6, "write_mb": write / 1e6}
    return out


def diff_nonces(text):
    """Nonces in a host's GET /sessions/<id>/diffs reply, or None when it is not one."""
    try:
        records = json.loads(text)
    except ValueError:
        return None
    if not isinstance(records, list):
        return None
    out = []
    for record in records:
        try:
            out.append(int(record["diff"]["nonce"]))
        except (KeyError, TypeError, ValueError):
            continue
    return out


def host_last(fetch, nonce, known=None, window=500, step=1000):
    """Highest diff nonce a host stored: from what it had last time, or back from the gateway nonce."""
    low = known if known is not None else max(0, nonce - window)
    high = max(nonce, low) + window
    while True:
        found = fetch(low, high)
        if found is None:
            return known
        if found:
            return max(found)
        if known is not None or low == 0:
            return known
        low, high = max(0, low - step), low


def cadence(text):
    """Height-sync cadence events of the gateway from /metrics, summed over escrows."""
    out = {}
    for labels, value in CADENCE.findall(text):
        match = re.search(r'event="([^"]+)"', labels)
        if match:
            out[match.group(1)] = out.get(match.group(1), 0) + int(float(value))
    return out


def count_lines(text):
    """(lines with the active cap refusal, lines with a dead heartbeat host)."""
    lines = text.splitlines()
    return sum(CAP_LINE in line for line in lines), sum(DEAD_LINE in line for line in lines)


class Sampler:
    """Gateway, hosts and heartbeats every few seconds; host diffs only when asked."""

    def __init__(self, stack, base, started):
        self.stack, self.base, self.started = stack, base, started
        self.samples, self.known = [], {}
        self.since, self.cap_lines, self.dead_lines = time.time(), 0, 0

    def take(self, phase, diffs=False):
        _code, text = stand.http("GET", self.base + "/metrics", timeout=10)
        text = text.decode("utf-8", "replace")
        nonce = stand.nonce_of(self.base)
        usage = self.stack.stats()
        now = time.time()
        cap, dead = count_lines(self.stack.gateway_log(self.since, now))
        self.since, self.cap_lines, self.dead_lines = now, self.cap_lines + cap, self.dead_lines + dead
        events = cadence(text)
        gateway = usage.get(self.stack.gateway, {})
        item = {"phase": phase, "t_s": round(time.monotonic() - self.started, 1), "nonce": nonce,
                "cpu_s": stand.metric(text, "process_cpu_seconds_total"),
                "rss_mb": (stand.metric(text, "process_resident_memory_bytes") or 0) / 2 ** 20,
                "cpu_pct": gateway.get("cpu_pct"), "mem_mb": gateway.get("mem_mb"), "rx_mb": gateway.get("rx_mb"),
                "tx_mb": gateway.get("tx_mb"), "write_mb": gateway.get("write_mb"),
                "storage_mb": stand.tree_bytes(self.stack.gateway_data) / 2 ** 20,
                "heartbeats": events.get("heartbeat_opened"), "abandoned": events.get("turn_abandoned"),
                "no_height": events.get("skipped_no_height"), "cap_lines": self.cap_lines,
                "dead_lines": self.dead_lines, "hosts": []}
        for i in range(self.stack.hosts):
            if diffs and nonce is not None:
                self.known[i] = host_last(lambda low, high, i=i: self.stack.diffs(i, low, high), nonce,
                                          self.known.get(i))
            row = usage.get(self.stack.host(i), {})
            item["hosts"].append({"host": i, "cpu_pct": row.get("cpu_pct"), "mem_mb": row.get("mem_mb"),
                                  "write_mb": row.get("write_mb"), "last_diff": self.known.get(i) if diffs else None})
        lasts = [row["last_diff"] for row in item["hosts"] if row["last_diff"] is not None]
        item.update(hosts_cpu_pct=sum(row["cpu_pct"] or 0 for row in item["hosts"]),
                    hosts_mem_mb=sum(row["mem_mb"] or 0 for row in item["hosts"]),
                    host_last_min=min(lasts) if lasts else None, host_last_max=max(lasts) if lasts else None)
        self.samples.append(item)
        return nonce


class Drive(stand.Load):
    """Unique chats in flight until the gateway nonce reaches the target; clears quarantined hosts when needed."""

    def __init__(self, base, concurrency, target, run_tag, participants=()):
        super().__init__(base, concurrency, target, run_tag)
        self.participants, self.unquarantines, self.cleared = list(participants), 0, None

    def one(self, number):
        body = {"model": MODEL, "max_tokens": 32,
                "messages": [{"role": "user", "content": "gcheck testenv %s chat %d" % (self.tag, number)}]}
        started = time.monotonic()
        code, reply = stand.http("POST", self.base + "/v1/chat/completions", body)
        capacity = code == 503 and CAPACITY in reply
        with self.lock:
            self.codes[code] = self.codes.get(code, 0) + 1
            self.latencies.append(time.monotonic() - started)
            if not capacity:
                self.failed_in_row = 0 if code == 200 else self.failed_in_row + 1
            failing = self.failed_in_row >= 50
        if code != 200 and b"high_nonce" in reply:
            self.finish(ROUTED_STOP)
        elif capacity:
            self.unquarantine()
            time.sleep(1)
        elif failing:
            self.finish("50 failed requests in a row, last %s" % code)
        return code

    def unquarantine(self, every_s=15):
        with self.lock:
            now = time.monotonic()
            if self.cleared is not None and now - self.cleared < every_s:
                return
            self.cleared, self.unquarantines = now, self.unquarantines + 1
        for key in self.participants:
            stand.http("POST", self.base + "/v1/admin/participants/unquarantine", {"participant_key": key},
                       timeout=30)


def warm_up(base, count, run_tag, participants=()):
    """Sequential unique chats, so the escrow gets the host-signed floor that heartbeats need."""
    warm = Drive(base, 1, 0, run_tag, participants)
    for number in range(count):
        warm.one(number)
    if not warm.codes.get(200):
        raise TestenvError("warm-up: no chat answered 200 of %d: %s" % (count, warm.codes))
    return warm


def quiet(sample, minutes, every_s, guard=None):
    """Sample the idle escrow for minutes; returns why it ended."""
    end = time.monotonic() + minutes * 60
    while True:
        sample()
        reason = guard() if guard else None
        if reason:
            return reason
        left = end - time.monotonic()
        if left <= 0:
            return None
        time.sleep(min(every_s, left))


def finalize(base, groups, path=None):
    """POST /v1/finalize; saves the reply with its code, time and signature weight to path."""
    started = time.monotonic()
    code, body = stand.http("POST", base + "/v1/finalize", {}, timeout=3600)
    out = {"code": code, "seconds": round(time.monotonic() - started, 3), "bytes": len(body),
           "quorum": stand.quorum(groups), "weight": None, "signatures": None, "host_stats": None, "nonce": None,
           "error": None}
    try:
        data = json.loads(body)
    except ValueError:
        data = None
    if isinstance(data, dict):
        signatures = data.get("signatures") or []
        out.update(signatures=len(signatures), host_stats=len(data.get("host_stats") or []), nonce=data.get("nonce"),
                   weight=len({item.get("slot_id") for item in signatures if isinstance(item, dict)}))
        failure = data.get("error")
        if code != 200:
            out["error"] = (failure.get("message") if isinstance(failure, dict) else failure) or str(data)[-300:]
    elif code != 200:
        out["error"] = body.decode("utf-8", "replace")[-300:]
    if path:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(dict(out, reply=data if data is not None else body.decode("utf-8", "replace")[-2000:]), handle,
                      indent=2)
            handle.write("\n")
    return out


def active_cap(groups):
    """Highest nonce a host accepts for diffs with completion-type txs: host/host.go at max_nonce − (G+1)."""
    return MAX_NONCE - (groups + 1)


def reached(drive, samples):
    return bool(drive and (drive.reason == ROUTED_STOP or any(
        (item.get("nonce") or 0) >= ROUTING_STOP for item in samples if item["phase"] == "drive")))


def quiet_rates(samples):
    """Nonces per minute and per heartbeat turn over samples of the idle escrow."""
    points = [item for item in samples if item.get("nonce") is not None]
    if len(points) < 2:
        return {"samples": len(points)}
    first, last = points[0], points[-1]
    span, moved = last["t_s"] - first["t_s"], last["nonce"] - first["nonce"]
    turns = (last.get("heartbeats") or 0) - (first.get("heartbeats") or 0)
    return {"samples": len(points), "minutes": round(span / 60, 1), "nonces": moved,
            "per_min": round(moved * 60 / span, 1) if span > 0 else None, "turns": turns,
            "per_turn": round(moved / turns, 1) if turns > 0 else None,
            "turn_s": round(span / turns, 1) if turns > 0 else None,
            "abandoned": (last.get("abandoned") or 0) - (first.get("abandoned") or 0),
            "cap_lines": (last.get("cap_lines") or 0) - (first.get("cap_lines") or 0),
            "dead_lines": (last.get("dead_lines") or 0) - (first.get("dead_lines") or 0)}


def _mean(values):
    values = [value for value in values if value is not None]
    return round(sum(values) / len(values), 1) if values else None


def _peak(values):
    values = [value for value in values if value is not None]
    return round(max(values), 1) if values else None


def summarize(groups, hosts, concurrency, mode, warm, drive, samples, final, error=None, stop=None, stopped=()):
    driven = [item for item in samples if item["phase"] == "drive" and item.get("nonce") is not None]
    rate = None
    if len(driven) >= 2 and driven[-1]["t_s"] > driven[0]["t_s"]:
        rate = round((driven[-1]["nonce"] - driven[0]["nonce"]) / (driven[-1]["t_s"] - driven[0]["t_s"]), 2)
    before = [item for item in samples if item["phase"] != "final"]
    last = before[-1] if before else {}
    with_diffs = [item for item in samples if item.get("host_last_max") is not None]
    lasts = with_diffs[-1] if with_diffs else {}
    end = samples[-1] if samples else {}
    codes = drive.codes if drive else {}
    per_host = []
    for i in range(hosts):
        rows = [row for item in samples for row in item.get("hosts", []) if row["host"] == i]
        per_host.append({"host": i, "slots": len(range(i, groups, hosts)), "cpu_mean_pct": _mean(
            row["cpu_pct"] for row in rows), "mem_peak_mb": _peak(row["mem_mb"] for row in rows),
            "last_diff": next((row["last_diff"] for row in reversed(rows) if row["last_diff"] is not None), None)})
    return {"groups": groups, "hosts": hosts, "concurrency": concurrency, "mode": mode,
            "warm_sent": sum(warm.codes.values()) if warm else 0, "warm_ok": warm.codes.get(200, 0) if warm else 0,
            "requests": sum(codes.values()), "ok": codes.get(200, 0),
            "codes": {str(code): count for code, count in sorted(codes.items())},
            "unquarantines": drive.unquarantines if drive else 0,
            "drive_nonce": max((item["nonce"] for item in driven), default=None), "nonces_per_s": rate,
            "reached": reached(drive, samples),
            "quiet": quiet_rates([item for item in samples if item["phase"] == "quiet"]),
            "gateway": {"cpu_mean_pct": _mean(item.get("cpu_pct") for item in samples),
                        "cpu_peak_pct": _peak(item.get("cpu_pct") for item in samples),
                        "rss_peak_mb": _peak(item.get("rss_mb") or item.get("mem_mb") for item in samples),
                        "rx_mb": end.get("rx_mb"), "tx_mb": end.get("tx_mb"), "write_mb": end.get("write_mb"),
                        "storage_mb": end.get("storage_mb")},
            "per_host": per_host, "nonce": last.get("nonce"), "host_last_min": lasts.get("host_last_min"),
            "host_last_max": lasts.get("host_last_max"), "active_cap": active_cap(groups),
            "cap_lines": end.get("cap_lines"), "dead_lines": end.get("dead_lines"), "finalize": final,
            "stop": stop or error or (drive.reason if drive else None), "error": error, "stopped": list(stopped)}


def _num(value, digits=1):
    return "?" if value is None else ("%%.%df" % digits) % value if isinstance(value, float) else str(value)


def judge(summary):
    check = "testenv_g%d" % summary["groups"]
    final = summary["finalize"] or {}
    settled = final.get("code") == 200 and (final.get("weight") or 0) >= final.get("quorum", 1)
    gateway_down = [item for item in summary["stopped"] if "-devshardctl " in item]
    quiet_part = summary["quiet"]
    if summary.get("error"):
        value, reason = "BLOCKED", summary["error"]
    elif summary["stop"] == "interrupted":
        value, reason = "INCONCLUSIVE", "interrupted at nonce %s" % summary["nonce"]
    elif gateway_down:
        value, reason = "FAIL", "gateway stopped at nonce %s: %s" % (summary["nonce"], gateway_down[0])
    elif summary["stopped"]:
        value, reason = "INCONCLUSIVE", "stack stopped at nonce %s: %s" % (summary["nonce"],
                                                                           "; ".join(summary["stopped"]))
    elif summary["mode"] == "dry-run":
        missing = []
        if summary["warm_ok"] < summary["warm_sent"] or not summary["warm_sent"]:
            missing.append("%d of %d chats answered 200" % (summary["warm_ok"], summary["warm_sent"]))
        if not settled:
            missing.append("finalize answered %s %s, weight %s of %s" % (
                final.get("code"), final.get("error") or "", final.get("weight"), final.get("quorum")))
        if summary["host_last_max"] is None:
            missing.append("no host diffs readable through the router")
        value = "FAIL" if missing else "PASS"
        reason = "; ".join(missing) or "%d chats, hosts hold diffs up to %s, finalize %s s, weight %s of %s" % (
            summary["warm_ok"], summary["host_last_max"], final["seconds"], final["weight"], final["quorum"])
    elif summary["mode"] == "quiet-only":
        if quiet_part.get("samples", 0) < 2:
            value, reason = "INCONCLUSIVE", "no quiet samples: %s" % summary["stop"]
        else:
            gateway = summary["gateway"]
            value, reason = "PASS", (
                "quiet %s nonces/min, %s per turn over %s turns (G+1 = %d), %s abandoned; gateway CPU %s%%, "
                "RSS peak %s MB; finalize %s" % (
                    _num(quiet_part.get("per_min")), _num(quiet_part.get("per_turn")), quiet_part.get("turns"),
                    summary["groups"] + 1, quiet_part.get("abandoned"), _num(gateway["cpu_mean_pct"]),
                    _num(gateway["rss_peak_mb"], 0), final.get("code")))
    elif not summary["reached"]:
        value, reason = "INCONCLUSIVE", "drive stopped at nonce %s of %d: %s" % (
            summary["drive_nonce"], ROUTING_STOP, summary["stop"])
    elif settled:
        value, reason = "PASS", (
            "drive to %s, quiet %s min to nonce %s, hosts hold diffs up to %s, finalize %s s, weight %s of %s" % (
                summary["drive_nonce"], quiet_part.get("minutes"), summary["nonce"], summary["host_last_max"],
                final["seconds"], final["weight"], final["quorum"]))
    else:
        value, reason = "FAIL", (
            "finalize answered %s %s after %s s; gateway nonce %s, hosts' last diff %s..%s, active cap %d, "
            "%s refusals at the active cap in the gateway log" % (
                final.get("code"), final.get("error") or "", final.get("seconds"), summary["nonce"],
                summary["host_last_min"], summary["host_last_max"], summary["active_cap"], summary["cap_lines"]))
    return {"check": check, "maps": [], "verdict": value, "reason": reason.strip(), "records": []}


def _listing(run, args):
    reply = run(args, check=False)
    return [(line.split("\t") + [""])[:2] for line in reply.stdout.splitlines() if line.strip()]


def _ours(name, project=""):
    return name.startswith(PREFIX + "-") or project.startswith(PREFIX + "-")


def cleanup(roots, run=None):
    """Remove the containers, networks, volumes, work dirs and images of this mode, and nothing else."""
    run = run or stand.docker
    removed = {}
    for kind, listing, remove in (
            ("containers", ["ps", "-a", "--format", "{{.Names}}\t" + LABEL], ["rm", "-f"]),
            ("networks", ["network", "ls", "--format", "{{.Name}}\t" + LABEL], ["network", "rm"]),
            ("volumes", ["volume", "ls", "--format", "{{.Name}}\t" + LABEL], ["volume", "rm"])):
        removed[kind] = [name for name, project in _listing(run, listing) if _ours(name, project)]
        if removed[kind]:
            run(remove + removed[kind], check=False)
    removed["dirs"] = [root for root in roots if os.path.exists(root)]
    for root in removed["dirs"]:
        remove_tree(root, run)
    removed["images"] = [name for name, _ in _listing(run, ["images", "--format", "{{.Repository}}:{{.Tag}}"])
                         if name.startswith(PREFIX + "-")]
    if removed["images"]:
        run(["rmi"] + removed["images"], check=False)
    return removed
