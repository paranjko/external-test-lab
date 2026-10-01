"""gcheck gateway-load stress: the upstream gateway session with G in-process hosts, measured nonce by nonce."""

import json
import os
import re
import shutil
import subprocess

from .gotest import GO_TEST, TEST_FILE, TEST_NAME

REPO = "https://github.com/gonka-ai/gonka.git"
TAG = "devshard/v5.0.2"
TAG_COMMIT = "eddae498572a43408232b22f2da25e64d30b9669"
SPARSE = ("devshard", "common", "inference-chain")
GO_VERSION = (1, 25, 9)
GO_IMAGE = "golang:1.25.9-alpine3.23"
EVENT = re.compile(r"^\s*GCHECK (\{.*\})\s*$")


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


def go_test_args(compile_only=False):
    pattern = "^$" if compile_only else "^%s$" % TEST_NAME
    return ["test", "./user/", "-tags", "stress", "-run", pattern, "-count=1", "-v", "-timeout", "0"]


def command(runner, source, cache_dir, env, name, compile_only=False):
    """(argv, cwd, process env) for one go test run."""
    env = dict(env, CGO_ENABLED="0", GOTOOLCHAIN="local")
    if runner == "go":
        return ["go"] + go_test_args(compile_only), os.path.join(source, "devshard"), dict(os.environ, **env)
    cache = os.path.join(cache_dir, "go")
    os.makedirs(cache, mode=0o700, exist_ok=True)
    env.update(HOME="/cache/home", GOPATH="/cache/gopath", GOMODCACHE="/cache/mod", GOCACHE="/cache/build")
    argv = ["docker", "run", "--rm", "--name", name, "--user", "%d:%d" % (os.getuid(), os.getgid()),
            "-v", "%s:/src" % source, "-v", "%s:/cache" % cache, "-w", "/src/devshard"]
    for key in sorted(env):
        argv += ["-e", "%s=%s" % (key, env[key])]
    return argv + [GO_IMAGE, "go"] + go_test_args(compile_only), None, None


def run_one(argv, cwd, env, log_path, on_event=None):
    """Run go test, keep its output in log_path; (exit code, events, interrupted)."""
    events = []
    with open(log_path, "w", encoding="utf-8") as log, subprocess.Popen(
            argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1) as proc:
        try:
            for line in proc.stdout:
                log.write(line)
                log.flush()
                match = EVENT.match(line)
                if match:
                    events.append(json.loads(match.group(1)))
                    if on_event:
                        on_event(events[-1])
            return proc.wait(), events, False
        except KeyboardInterrupt:
            proc.terminate()
            proc.wait()
            return proc.returncode, events, True


def tail(path, lines=6):
    with open(path, encoding="utf-8") as handle:
        return " | ".join(line.strip() for line in handle.read().splitlines()[-lines:] if line.strip())


def judge(hosts, code, events, interrupted, log_path):
    """One verdict per group size from the go test outcome."""
    started = any(event.get("kind") == "start" for event in events)
    summary = next((event for event in events if event.get("kind") == "summary"), None)
    check = "stress_g%d" % hosts
    if interrupted:
        value, reason = "INCONCLUSIVE", "interrupted after %d checkpoints" % sum(
            event.get("kind") == "checkpoint" for event in events)
    elif code == 0 and summary:
        value, reason = "PASS", "%d nonces, finalize %.1f s, %d signatures; settlement verified" % (
            summary["nonces"], summary["finalize_s"], summary["signatures"])
    elif not started:
        value, reason = "BLOCKED", "go test did not start: %s" % tail(log_path)
    else:
        value, reason = "FAIL", "go test exit %s: %s" % (code, tail(log_path))
    return {"check": check, "maps": [], "verdict": value, "reason": reason, "records": []}
