"""gcheck gateway-load stress: the upstream gateway session with G in-process hosts, measured nonce by nonce."""

import collections
import json
import os
import re
import shutil
import subprocess
import time

from .gotest import GO_TEST, TEST_FILE, TEST_NAME

REPO = "https://github.com/gonka-ai/gonka.git"
TAG = "devshard/v5.0.2"
TAG_COMMIT = "eddae498572a43408232b22f2da25e64d30b9669"
SPARSE = ("devshard", "common", "inference-chain")
GO_VERSION = (1, 25, 9)
GO_IMAGE = "golang:1.25.9-alpine3.23"
EVENT = re.compile(r"^\s*GCHECK (\{.*\})\s*$")
KEEP_LINES = 2000
LINE_CHARS = 2000


class StressError(Exception):
    pass


def git(args, cwd=None):
    reply = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True)
    if reply.returncode != 0:
        raise StressError("git %s: %s" % (" ".join(args[:3]), (reply.stderr or reply.stdout).strip()[-300:]))
    return reply.stdout.strip()


def prepare_source(cache_dir, tag=TAG, repo=REPO, pinned=TAG_COMMIT):
    """Sparse checkout of the tag in cache_dir/gonka; returns (path, commit). Refuses a moved pinned tag."""
    path = os.path.join(cache_dir, "gonka")
    if not os.path.isdir(os.path.join(path, ".git")):
        os.makedirs(cache_dir, mode=0o700, exist_ok=True)
        git(["clone", "--quiet", "--filter=blob:none", "--no-checkout", repo, path])
        git(["-C", path, "sparse-checkout", "init", "--cone"])
        git(["-C", path, "sparse-checkout", "set"] + list(SPARSE))
    git(["-C", path, "fetch", "--quiet", "--no-tags", "origin", "+refs/tags/%s:refs/tags/%s" % (tag, tag)])
    git(["-C", path, "checkout", "--quiet", "--force", "--detach", "refs/tags/%s" % tag])
    commit = git(["-C", path, "rev-parse", "HEAD"])
    if tag == TAG and pinned and commit != pinned:
        raise StressError("tag %s points to %s, expected %s" % (tag, commit, pinned))
    with open(os.path.join(path, TEST_FILE), "w", encoding="utf-8") as handle:
        handle.write(GO_TEST)
    return path, commit


def go_version(text):
    match = re.search(r"go(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    return tuple(int(part or 0) for part in match.groups()) if match else None


def pick_runner(choice):
    """("go", version) for a local go of GO_VERSION or newer, else ("docker", GO_IMAGE)."""
    local = shutil.which("go") if choice in ("auto", "go") else None
    if local:
        text = subprocess.run([local, "env", "GOVERSION"], capture_output=True, text=True).stdout.strip()
        if (go_version(text) or (0,)) >= GO_VERSION:
            return "go", text
        if choice == "go":
            raise StressError("%s is older than go%s" % (text or "go", ".".join(map(str, GO_VERSION))))
    if choice in ("auto", "docker") and shutil.which("docker"):
        return "docker", GO_IMAGE
    raise StressError("needs go%s or newer, or docker" % ".".join(map(str, GO_VERSION)))


BINARY = "gateway-load.test"


def machine_memory_gb():
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2 ** 30
    except (ValueError, OSError, AttributeError):
        return None


def default_memory_gb():
    total = machine_memory_gb()
    return round(total * 0.75 * 2) / 2 if total else None


def go_env(memory_gb):
    env = {"CGO_ENABLED": "0", "GOTOOLCHAIN": "local"}
    if memory_gb:
        env["GOMEMLIMIT"] = "%dMiB" % int(memory_gb * 1024 * 0.9)
    return env


def _docker(source, cache_dir, name, env, workdir, memory_gb):
    cache = os.path.join(cache_dir, "go")
    os.makedirs(cache, mode=0o700, exist_ok=True)
    env = dict(env, HOME="/cache/home", GOPATH="/cache/gopath", GOMODCACHE="/cache/mod", GOCACHE="/cache/build")
    argv = ["docker", "run", "--rm", "--name", name, "--log-driver", "none",
            "--user", "%d:%d" % (os.getuid(), os.getgid())]
    if memory_gb:
        argv += ["--memory", "%dm" % int(memory_gb * 1024), "--memory-swap", "%dm" % int(memory_gb * 1024)]
    argv += ["-v", "%s:/src" % source, "-v", "%s:/cache" % cache, "-w", workdir]
    for key in sorted(env):
        argv += ["-e", "%s=%s" % (key, env[key])]
    return argv + [GO_IMAGE]


def build_command(runner, source, cache_dir, name):
    """(argv, cwd, env) that compiles the test once into the cache, so no go process stays resident during runs."""
    if runner == "go":
        out = os.path.join(cache_dir, "bin", BINARY)
        os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
        argv = ["go", "test", "-c", "-tags", "stress", "-o", out, "./user/"]
        return argv, os.path.join(source, "devshard"), dict(os.environ, **go_env(None))
    argv = _docker(source, cache_dir, name, go_env(None), "/src/devshard", None)
    return argv + ["go", "test", "-c", "-tags", "stress", "-o", "/cache/bin/%s" % BINARY, "./user/"], None, None


def command(runner, source, cache_dir, env, name, memory_gb=None):
    """(argv, cwd, process env) that runs the prebuilt test for one group size."""
    flags = ["-test.run", "^%s$" % TEST_NAME, "-test.count=1", "-test.v", "-test.timeout", "0"]
    env = dict(env, **go_env(memory_gb))
    if runner == "go":
        binary = os.path.join(cache_dir, "bin", BINARY)
        return [binary] + flags, os.path.join(source, "devshard", "user"), dict(os.environ, **env)
    argv = _docker(source, cache_dir, name, env, "/src/devshard/user", memory_gb)
    return argv + ["/cache/bin/%s" % BINARY] + flags, None, None


def shorten(line, chars=LINE_CHARS):
    body = line.rstrip("\n")
    return line if len(body) <= chars else "%s ... [%d characters cut]\n" % (body[:chars], len(body) - chars)


def remove_container(name):
    """docker rm -f; quiet when the container is already gone or docker is absent."""
    try:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        pass


def disk_guard(paths, floor=0.05):
    """A stop reason when a file system holding one of paths has less than floor of its space free."""
    for path in paths:
        try:
            usage = shutil.disk_usage(path)
        except OSError:
            continue
        if usage.total and usage.free / usage.total < floor:
            return "disk below %d%% free at %s" % (round(floor * 100), path)
    return None


def run_one(argv, cwd, env, log_path, on_event=None, guard=None, every_s=10.0):
    """Run go test; log its GCHECK lines and the last KEEP_LINES other lines; (exit code, events, stop or False)."""
    events, rest, stop, checked = [], collections.deque(maxlen=KEEP_LINES), False, time.monotonic()
    with open(log_path, "w", encoding="utf-8") as log, subprocess.Popen(
            argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1) as proc:
        try:
            for line in proc.stdout:
                match = EVENT.match(line)
                if not match:
                    rest.append(shorten(line))
                else:
                    log.write(line)
                    log.flush()
                    events.append(json.loads(match.group(1)))
                    if on_event:
                        on_event(events[-1])
                if guard and time.monotonic() - checked >= every_s:
                    checked = time.monotonic()
                    stop = guard() or False
                    if stop:
                        proc.terminate()
                        break
            code = proc.wait()
        except KeyboardInterrupt:
            proc.terminate()
            code, stop = proc.wait(), "interrupted"
        except OSError as error:
            proc.terminate()
            code, stop = proc.wait(), "stopped: %s" % error
        try:
            log.write("".join(rest))
        except OSError:
            pass
    return code, events, stop


def tail(path, lines=6):
    with open(path, encoding="utf-8") as handle:
        return " | ".join(line.strip() for line in handle.read().splitlines()[-lines:] if line.strip())


def judge(hosts, code, events, interrupted, log_path):
    """One verdict per group size from the go test outcome."""
    started = any(event.get("kind") == "start" for event in events)
    summary = next((event for event in events if event.get("kind") == "summary"), None)
    check = "stress_g%d" % hosts
    if interrupted:
        value, reason = "INCONCLUSIVE", "%s after %d checkpoints" % (
            interrupted if isinstance(interrupted, str) else "interrupted",
            sum(event.get("kind") == "checkpoint" for event in events))
    elif code == 0 and summary:
        value, reason = "PASS", "%d nonces, finalize %.1f s, %d signatures; settlement verified" % (
            summary["nonces"], summary["finalize_s"], summary["signatures"])
    elif not started:
        value, reason = "BLOCKED", "go test did not start: %s" % tail(log_path)
    elif code in (137, -9):
        value, reason = "FAIL", "killed (exit %s), most likely out of memory under the limit, after %d checkpoints" % (
            code, sum(event.get("kind") == "checkpoint" for event in events))
    else:
        value, reason = "FAIL", "go test exit %s: %s" % (code, tail(log_path))
    return {"check": check, "maps": [], "verdict": value, "reason": reason, "records": []}
