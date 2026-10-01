"""gcheck gateway-load: plan and stress (the upstream in-process gateway session at several group sizes)."""

import argparse
import datetime
import json
import os
import secrets
import subprocess
import sys
import time

from .. import __version__
from ..record import Recorder, utc_now
from ..scheduler import LockBusy, RunLock
from ..summary import EXIT_CODES, overall
from ..target import config_dir, data_dir
from . import report, stress

DEFAULT_GROUPS = "16,32,64"
DEFAULT_NONCES = 19800
DEFAULT_EVERY = 1000


def positive(text):
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("needs a positive number")
    return value


def add_parser(commands):
    gateway = commands.add_parser("gateway-load", help="gateway load at several group sizes; no Gonka network")
    sub = gateway.add_subparsers(dest="gateway_command", required=True)
    sub.add_parser("plan", help="what stress runs, where its code comes from and what it needs")
    stress_cmd = sub.add_parser("stress", help="upstream gateway session with G in-process hosts, measured per nonce")
    stress_cmd.add_argument("--groups", default=DEFAULT_GROUPS, help="group sizes (default %s)" % DEFAULT_GROUPS)
    stress_cmd.add_argument("--nonces", type=positive, default=DEFAULT_NONCES,
                            help="nonces per escrow (default %d)" % DEFAULT_NONCES)
    stress_cmd.add_argument("--every", type=positive, default=DEFAULT_EVERY,
                            help="nonces per checkpoint (default %d)" % DEFAULT_EVERY)
    stress_cmd.add_argument("--tag", default=stress.TAG, help="gonka-ai/gonka tag (default %s)" % stress.TAG)
    stress_cmd.add_argument("--runner", choices=("auto", "go", "docker"), default="auto",
                            help="local go or the %s image (default auto)" % stress.GO_IMAGE)
    stress_cmd.add_argument("--dry-run", action="store_true",
                            help="fetch the source and build the test; READY or BLOCKED")
    return gateway


def run(args):
    return {"plan": cmd_plan, "stress": cmd_stress}[args.gateway_command](args)


def log(message):
    sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


def groups_of(text):
    groups = sorted({int(part) for part in text.split(",") if part.strip()})
    if not groups or groups[0] < 1 or groups[-1] > 128:
        raise ValueError("--groups needs sizes from 1 to 128")
    return groups


def cmd_plan(_args):
    cache = os.path.join(data_dir(), "cache", "gateway-load")
    try:
        runner, detail = stress.pick_runner("auto")
        how = "%s (%s)" % (runner, detail)
    except stress.StressError as error:
        how = "none: %s" % error
    print("source   %s tag %s (commit %s), sparse: %s" % (stress.REPO, stress.TAG, stress.TAG_COMMIT[:12],
                                                         ", ".join(stress.SPARSE)))
    print("adds     %s, test %s" % (stress.TEST_FILE, stress.TEST_NAME))
    print("runs     one go test per group size (default %s), %d nonces each, one request at a time"
          % (DEFAULT_GROUPS, DEFAULT_NONCES))
    print("runner   %s" % how)
    print("network  github.com for the source and the Go module proxy; nothing to any Gonka network")
    print("cache    %s" % cache)
    print("writes   %s/<run>/: report.md, checkpoints.csv, gateway.svg, host.svg, go-test-g<G>.log" %
          os.path.join(data_dir(), "runs"))
    return 0


def _run_dir():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = "%s-gateway-stress-%s" % (stamp, secrets.token_hex(2))
    return run_id, os.path.join(data_dir(), "runs", run_id)


def minutes_left(previous, current, nonces):
    """Time per nonce grows with the live set; extrapolate the last slope to the end of the run."""
    left = nonces - current["nonce"]
    if left <= 0:
        return 0.0
    slope = 0.0
    if previous and current["nonce"] > previous["nonce"]:
        slope = max(0.0, (current["wall_ms"] - previous["wall_ms"]) / (current["nonce"] - previous["nonce"]))
    return (left * current["wall_ms"] + slope * left * left / 2) / 60000


def progress(nonces):
    last = {}

    def on_event(event):
        if event.get("kind") == "checkpoint":
            left = minutes_left(last.get(event["hosts"]), event, nonces)
            last[event["hosts"]] = event
            log("G=%d nonce %d: gateway %.2f ms, hosts %.2f ms per nonce, heap %.0f MB, %.0f s, about %.0f min left" % (
                event["hosts"], event["nonce"], event["gateway_ms"], event["host_ms"], event["heap_mb"],
                event["elapsed_s"], left))
        elif event.get("kind") == "summary":
            log("G=%d done: finalize %.1f s, state %.1f MB, diff log %.1f MB" % (
                event["hosts"], event["finalize_s"], event["state_mb"], event["diff_history_mb"]))
    return on_event


def cmd_stress(args):
    try:
        groups = groups_of(args.groups)
    except ValueError as error:
        sys.stderr.write("gcheck: %s\n" % error)
        return EXIT_CODES["GUARD_STOP"]
    run_id, run_dir = _run_dir()
    recorder = Recorder(run_dir)
    cache = os.path.join(data_dir(), "cache", "gateway-load")
    meta = {"tool": "gonka-check %s" % __version__, "run_id": run_id, "mode": "gateway-stress", "tag": args.tag,
            "groups": groups, "nonces": args.nonces, "every": args.every, "started_at": utc_now()}
    try:
        with RunLock(os.path.join(config_dir(), "gateway-load.lock")):
            runner, detail = stress.pick_runner(args.runner)
            log("source   %s %s" % (stress.REPO, args.tag))
            source, commit = stress.prepare_source(cache, args.tag)
            meta.update(commit=commit, runner="%s (%s)" % (runner, detail))
            recorder.write_json("manifest.json", meta)
            print("source   %s at %s" % (args.tag, commit[:12]))
            print("runner   %s" % meta["runner"])
            if args.dry_run:
                return _dry_run(runner, source, cache, run_id, run_dir, recorder)
            return _stress(args, groups, runner, source, cache, run_id, run_dir, recorder, meta)
    except LockBusy as error:
        print("ready    BLOCKED\n         lock: %s" % error)
        return EXIT_CODES["BLOCKED"]
    except stress.StressError as error:
        print("ready    BLOCKED\n         %s" % error)
        recorder.write_json("summary.json", {"mode": "gateway-stress", "overall": "BLOCKED", "reason": str(error)})
        return EXIT_CODES["BLOCKED"]


def _dry_run(runner, source, cache, run_id, run_dir, recorder):
    argv, cwd, env = stress.command(runner, source, cache, {}, "%s-build" % run_id, compile_only=True)
    log_path = os.path.join(run_dir, "go-test-build.log")
    code, _events, interrupted = stress.run_one(argv, cwd, env, log_path)
    state = "READY" if code == 0 and not interrupted else "BLOCKED"
    recorder.write_json("summary.json", {"mode": "gateway-stress-probe", "state": state, "exit": code})
    print("ready    %s" % state)
    if state != "READY":
        print("         %s" % stress.tail(log_path))
    print("records  %s" % run_dir)
    return 0 if state == "READY" else EXIT_CODES["BLOCKED"]


def _stress(args, groups, runner, source, cache, run_id, run_dir, recorder, meta):
    runs, verdicts = [], []
    for hosts in groups:
        name = "%s-g%d" % (run_id, hosts)
        env = {"GCHECK_HOSTS": str(hosts), "GCHECK_NONCES": str(args.nonces), "GCHECK_EVERY": str(args.every)}
        argv, cwd, proc_env = stress.command(runner, source, cache, env, name)
        log_path = os.path.join(run_dir, "go-test-g%d.log" % hosts)
        log("G=%d: %d nonces" % (hosts, args.nonces))
        code, events, interrupted = stress.run_one(argv, cwd, proc_env, log_path, progress(args.nonces))
        if interrupted and runner == "docker":
            subprocess.run(["docker", "stop", name], capture_output=True)
        result = stress.judge(hosts, code, events, interrupted, log_path)
        start = next((event for event in events if event.get("kind") == "start"), {})
        meta.setdefault("cpus", start.get("cpus"))
        runs.append({"hosts": hosts, "checkpoints": [event for event in events if event.get("kind") == "checkpoint"],
                     "summary": next((event for event in events if event.get("kind") == "summary"), None),
                     "verdict": result})
        verdicts.append(result)
        recorder.write("run", hosts=hosts, exit=code, verdict=result["verdict"], events=len(events))
        print("%-12s %-13s %s" % (result["verdict"], result["check"], result["reason"]))
        if interrupted:
            break
    result = overall(verdicts)
    files = report.write(run_dir, meta, runs, verdicts, result)
    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump({"mode": "gateway-stress", "overall": result, "verdicts": verdicts,
                   "summaries": [run["summary"] for run in runs], "finished_at": utc_now()}, handle, indent=2,
                  sort_keys=True)
        handle.write("\n")
    print("written  %s: %s" % (run_dir, ", ".join(files)))
    print("overall  %s (exit %d)" % (result, EXIT_CODES[result]))
    return EXIT_CODES[result]
