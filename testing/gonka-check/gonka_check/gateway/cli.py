"""gcheck gateway-load: plan and stress (the upstream in-process gateway session at several group sizes)."""

import argparse
import datetime
import json
import os
import secrets
import shutil
import subprocess
import sys
import time

from .. import __version__
from ..record import Recorder, utc_now
from ..scheduler import LockBusy, RunLock
from ..summary import EXIT_CODES, overall
from ..target import config_dir, data_dir
from . import keys, report, stand, stress

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
    stress_cmd.add_argument("--memory", type=float, default=None,
                            help="memory cap per run in GB (default 75%% of this machine; 0 turns it off)")
    stress_cmd.add_argument("--dry-run", action="store_true",
                            help="fetch the source and build the test; READY or BLOCKED")
    stand_cmd = sub.add_parser("stand", help="the gateway as its own process against stub hosts on the mock chain")
    stand_cmd.add_argument("--groups", default=DEFAULT_GROUPS, help="group sizes (default %s)" % DEFAULT_GROUPS)
    stand_cmd.add_argument("--hosts", default="7", help="stub host counts, G for one per slot (default 7)")
    stand_cmd.add_argument("--concurrency", default="8", help="requests in flight, a list (default 8)")
    stand_cmd.add_argument("--delay-ms", type=int, default=0,
                           help="netem delay on every packet a stub host sends (default 0)")
    stand_cmd.add_argument("--nonces", type=positive, default=DEFAULT_NONCES,
                           help="escrow nonce to reach (default %d)" % DEFAULT_NONCES)
    stand_cmd.add_argument("--every", type=float, default=5.0, help="seconds between samples (default 5)")
    stand_cmd.add_argument("--max-minutes", type=float, default=None, help="stop each stand after this long")
    stand_cmd.add_argument("--tag", default=stress.TAG, help="gonka-ai/gonka tag (default %s)" % stress.TAG)
    stand_cmd.add_argument("--dry-run", action="store_true",
                           help="build the images, bring up a small stand, send one request; READY or BLOCKED")
    return gateway


def run(args):
    return {"plan": cmd_plan, "stress": cmd_stress, "stand": cmd_stand}[args.gateway_command](args)


def log(message):
    sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


def groups_of(text):
    groups = sorted({int(part) for part in text.split(",") if part.strip()})
    if not groups or groups[0] < 1 or groups[-1] > 128:
        raise ValueError("--groups needs sizes from 1 to 128")
    return groups


def counts_of(text, flag, top):
    parts = [part.strip() for part in text.split(",") if part.strip()]
    if not parts or not all(part.isdigit() and 1 <= int(part) <= top for part in parts):
        raise ValueError("%s needs values from 1 to %d" % (flag, top))
    return sorted({int(part) for part in parts})


def hosts_of(text):
    """Stub host counts; G means one host per slot."""
    parts = [part.strip().upper() for part in text.split(",") if part.strip()]
    numbers = [part for part in parts if part != "G"]
    if not parts:
        raise ValueError("--hosts needs counts from 1 to %d or G" % len(keys.HOST_ADDRESSES))
    return (counts_of(",".join(numbers), "--hosts", len(keys.HOST_ADDRESSES)) if numbers else []) + (
        ["G"] if "G" in parts else [])


def stands_of(groups, hosts, concurrency):
    """(G, H, in flight) for every stand to run; H never exceeds G or the 64 test keys."""
    out = []
    for size in groups:
        counts = sorted({min(size if count == "G" else count, size, len(keys.HOST_ADDRESSES)) for count in hosts})
        out += [(size, count, flight) for count in counts for flight in concurrency]
    return out


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
    print("builds   the test once, then runs the binary per group size; memory cap %s GB per run" % (
        stress.default_memory_gb() or "none"))
    print("stand    stub hosts, mock chain and gateway images built once per commit; one stand per G, host count "
          "and concurrency; default 7 hosts, 8 in flight, no delay")
    print("network  github.com for the source, the Go module proxy, Docker Hub base images, Alpine packages; "
          "nothing to any Gonka network; the stand gateway on 127.0.0.1 only")
    print("cache    %s" % cache)
    print("writes   %s/<run>/: report.md, checkpoints.csv, gateway.svg, host.svg, go-test-g<G>.log" %
          os.path.join(data_dir(), "runs"))
    print("         stand: report.md, samples.csv, stand-cpu.svg, stand-rss.svg, g<G>-h<H>-c<x>/ with seed, env, logs, "
          "finalize.json")
    return 0


def _run_dir(mode="stress"):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = "%s-gateway-%s-%s" % (stamp, mode, secrets.token_hex(2))
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
            log("G=%d nonce %d: gateway %.2f ms, hosts %.2f ms per nonce, live %s, heap %.0f MB, %.0f s, "
                "about %.0f min left" % (event["hosts"], event["nonce"], event["gateway_ms"], event["host_ms"],
                                         event.get("live", "?"), event["heap_mb"], event["elapsed_s"], left))
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
            memory = stress.default_memory_gb() if args.memory is None else (args.memory or None)
            meta.update(commit=commit, runner="%s (%s)" % (runner, detail), memory_gb=memory)
            recorder.write_json("manifest.json", meta)
            print("source   %s at %s" % (args.tag, commit[:12]))
            print("runner   %s" % meta["runner"])
            print("memory   %s" % ("cap %g GB per run" % memory if memory else "no cap"))
            built = _build(runner, source, cache, run_id, run_dir)
            if args.dry_run or not built:
                return _ready(built, run_dir, recorder)
            return _stress(args, groups, runner, source, cache, run_id, run_dir, recorder, meta, memory)
    except LockBusy as error:
        print("ready    BLOCKED\n         lock: %s" % error)
        return EXIT_CODES["BLOCKED"]
    except stress.StressError as error:
        print("ready    BLOCKED\n         %s" % error)
        recorder.write_json("summary.json", {"mode": "gateway-stress", "overall": "BLOCKED", "reason": str(error)})
        return EXIT_CODES["BLOCKED"]


def _build(runner, source, cache, run_id, run_dir):
    argv, cwd, env = stress.build_command(runner, source, cache, "%s-build" % run_id)
    log("build    go test -c -tags stress ./user/")
    code, _events, interrupted = stress.run_one(argv, cwd, env, os.path.join(run_dir, "go-test-build.log"))
    return code == 0 and not interrupted


def _ready(built, run_dir, recorder):
    state = "READY" if built else "BLOCKED"
    recorder.write_json("summary.json", {"mode": "gateway-stress-probe", "state": state})
    print("ready    %s" % state)
    if not built:
        print("         %s" % stress.tail(os.path.join(run_dir, "go-test-build.log")))
    print("records  %s" % run_dir)
    return 0 if built else EXIT_CODES["BLOCKED"]


def _stress(args, groups, runner, source, cache, run_id, run_dir, recorder, meta, memory):
    runs, verdicts = [], []
    for hosts in groups:
        name = "%s-g%d" % (run_id, hosts)
        env = {"GCHECK_HOSTS": str(hosts), "GCHECK_NONCES": str(args.nonces), "GCHECK_EVERY": str(args.every)}
        argv, cwd, proc_env = stress.command(runner, source, cache, env, name, memory)
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


def _stand_one(groups, hosts, concurrency, args, commit, run_id, run_dir, on_log):
    names = stand.Names(run_id, groups, hosts, concurrency)
    label = "G=%d H=%d x%d" % (groups, hosts, concurrency)
    group_dir = os.path.join(run_dir, "g%d-h%d-c%d" % (groups, hosts, concurrency))
    gateway_data = os.path.join(group_dir, "gateway-data")
    os.makedirs(gateway_data, mode=0o700)
    with open(os.path.join(group_dir, "seed.yaml"), "w", encoding="utf-8") as handle:
        json.dump(stand.seed(groups, hosts, names), handle, indent=2)
    for j in range(hosts):
        stand.write_env(os.path.join(group_dir, "host-%d.env" % j), stand.host_env(j, groups, hosts, names))
    stand.write_env(os.path.join(group_dir, "gateway.env"), stand.gateway_env(names))
    target = 1 if args.dry_run else args.nonces
    samples, load, final, error, stop, stopped = [], None, None, None, None, []
    try:
        base = stand.start(names, commit, group_dir, gateway_data, hosts, args.delay_ms)
        on_log("%s: stand up on %s%s" % (label, base, ", delay %d ms" % args.delay_ms if args.delay_ms else ""))
        started = time.monotonic()
        load = stand.Load(base, 1 if args.dry_run else concurrency, target, run_id[-4:])

        def on_sample():
            item = stand.sample(base, names, hosts, gateway_data, started)
            samples.append(item)
            if len(samples) % 12 == 0 or (item["nonce"] or 0) >= target:
                on_log("%s nonce %s: CPU %.1f s, RSS %.0f MB, hosts %.0f MB, storage %.1f MB, sent %.1f MB" % (
                    label, item["nonce"], item["cpu_s"] or 0, item["rss_mb"], item["hosts_mem_mb"] or 0,
                    item["storage_mb"], item["tx_mb"]))
            return item["nonce"]

        if args.dry_run:
            load.one(1)
            load.reason = "one request"
        else:
            load.run(on_sample, every_s=args.every, max_s=args.max_minutes * 60 if args.max_minutes else None,
                     guard=stand.memory_guard)
        on_sample()
        on_log("%s: %s; finalizing at nonce %s, Ctrl-C skips it" % (label, load.reason, samples[-1]["nonce"]))
        final = stand.finalize(base, groups, os.path.join(group_dir, "finalize.json"))
    except stand.StandError as failure:
        error = str(failure)
    except KeyboardInterrupt:
        stop = "interrupted"
    finally:
        stopped = stand.exited(names, hosts)
        for name, file in ((names.gateway, "gateway.log"), (names.host(0), "host-0.log")):
            with open(os.path.join(group_dir, file), "w", encoding="utf-8") as handle:
                handle.write(stand.logs(name, tail=2000))
        stand.down(names, hosts)
    summary = stand.summarize(groups, hosts, concurrency, load, samples, final, error, stop, stopped)
    return {"groups": groups, "label": label, "samples": samples, "summary": summary,
            "verdict": stand.judge(summary, target)}


def cmd_stand(args):
    try:
        flights = counts_of(args.concurrency, "--concurrency", 256)
        stands = stands_of(groups_of(args.groups), hosts_of(args.hosts), flights)
        if args.delay_ms < 0 or args.delay_ms > 10000:
            raise ValueError("--delay-ms needs 0 to 10000")
    except ValueError as error:
        sys.stderr.write("gcheck: %s\n" % error)
        return EXIT_CODES["GUARD_STOP"]
    if args.dry_run:
        stands = [(stands[0][0], stands[0][1], 1)]
    run_id, run_dir = _run_dir("stand")
    recorder = Recorder(run_dir)
    cache = os.path.join(data_dir(), "cache", "gateway-load")
    meta = {"tool": "gonka-check %s" % __version__, "run_id": run_id, "mode": "gateway-stand", "tag": args.tag,
            "stands": stands, "delay_ms": args.delay_ms, "nonces": args.nonces, "started_at": utc_now()}
    try:
        with RunLock(os.path.join(config_dir(), "gateway-load.lock")):
            if not shutil.which("docker"):
                raise stress.StressError("needs docker")
            source, commit = stress.prepare_source(cache, args.tag)
            meta["commit"] = commit
            recorder.write_json("manifest.json", meta)
            print("source   %s at %s" % (args.tag, commit[:12]))
            log("build    stub host, mock chain and gateway images (once per commit)")
            stand.build_images(source, commit, os.path.join(run_dir, "docker-build.log"), netem=args.delay_ms > 0)
            runs = []
            for size, hosts, concurrency in stands:
                runs.append(_stand_one(size, hosts, concurrency, args, commit, run_id, run_dir, log))
                verdict, stop = runs[-1]["verdict"], runs[-1]["summary"]["stop"] or ""
                print("%-12s %-18s %s" % (verdict["verdict"], verdict["check"], verdict["reason"]))
                if verdict["verdict"] == "BLOCKED" or stop == "interrupted" or stop.startswith("machine memory"):
                    break
    except LockBusy as error:
        print("ready    BLOCKED\n         lock: %s" % error)
        return EXIT_CODES["BLOCKED"]
    except (stress.StressError, stand.StandError) as error:
        print("ready    BLOCKED\n         %s" % error)
        recorder.write_json("summary.json", {"mode": "gateway-stand", "overall": "BLOCKED", "reason": str(error)})
        return EXIT_CODES["BLOCKED"]
    verdicts = [run["verdict"] for run in runs]
    result = overall(verdicts)
    if args.dry_run:
        print("ready    %s" % ("READY" if result == "PASS" else "BLOCKED"))
        print("records  %s" % run_dir)
        return 0 if result == "PASS" else EXIT_CODES["BLOCKED"]
    files = report.write_stand(run_dir, meta, runs, verdicts, result)
    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump({"mode": "gateway-stand", "overall": result, "verdicts": verdicts,
                   "summaries": [run["summary"] for run in runs], "finished_at": utc_now()}, handle, indent=2,
                  sort_keys=True)
        handle.write("\n")
    print("written  %s: %s" % (run_dir, ", ".join(files)))
    print("overall  %s (exit %d)" % (result, EXIT_CODES[result]))
    return EXIT_CODES[result]
