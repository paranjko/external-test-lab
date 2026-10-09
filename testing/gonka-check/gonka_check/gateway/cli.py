"""gcheck gateway-load: plan and stress (the upstream in-process gateway session at several group sizes)."""

import argparse
import datetime
import json
import os
import re
import secrets
import shutil
import sys
import time

from .. import __version__
from ..record import Recorder, utc_now
from ..scheduler import LockBusy, RunLock
from ..summary import EXIT_CODES, overall
from ..target import config_dir, data_dir
from . import keys, report, stand, stress, testenv

DEFAULT_GROUPS = "16,32,64"
CPUS = re.compile(r"^\d+(-\d+)?(,\d+(-\d+)?)*$")
DEFAULT_NONCES = 19800
DEFAULT_EVERY = 1000
DEFAULT_QUIET_MINUTES = 10


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
    stand_cmd.add_argument("--gateway-cpus", default=None, help="CPUs for the gateway alone, e.g. 0 (default: any)")
    stand_cmd.add_argument("--host-cpus", default=None, help="CPUs for the stub hosts and the chain, e.g. 1-3")
    stand_cmd.add_argument("--delay-ms", type=int, default=0,
                           help="netem delay on every packet a stub host sends (default 0)")
    stand_cmd.add_argument("--nonces", type=positive, default=DEFAULT_NONCES,
                           help="escrow nonce to reach (default %d)" % DEFAULT_NONCES)
    stand_cmd.add_argument("--every", type=float, default=5.0, help="seconds between samples (default 5)")
    stand_cmd.add_argument("--max-minutes", type=float, default=None, help="stop each stand after this long")
    stand_cmd.add_argument("--tag", default=stress.TAG, help="gonka-ai/gonka tag (default %s)" % stress.TAG)
    stand_cmd.add_argument("--dry-run", action="store_true",
                           help="build the images, bring up a small stand, send one request; READY or BLOCKED")
    tenv = sub.add_parser("testenv", help="the gateway against real devshardd hosts in the upstream devshard/testenv")
    tenv.add_argument("--groups", default="64", help="group sizes (default 64)")
    tenv.add_argument("--hosts", type=positive, default=4, help="devshardd host processes, at most G (default 4)")
    tenv.add_argument("--concurrency", type=positive, default=8, help="chats in flight during the drive (default 8)")
    tenv.add_argument("--quiet-minutes", type=float, default=DEFAULT_QUIET_MINUTES,
                      help="minutes of no requests after the drive, 0 finalizes at once (default %d)" %
                      DEFAULT_QUIET_MINUTES)
    tenv.add_argument("--quiet-only", action="store_true",
                      help="no drive: warm up, then sample the idle escrow for --quiet-minutes")
    tenv.add_argument("--rotation", choices=testenv.ROTATIONS, default="off",
                      help="settle: the gateway replaces escrow 1 at the routing stop and settles it itself; "
                           "deactivate: it only deactivates it, and gcheck settles it through the admin API after "
                           "--quiet-minutes (default off)")
    tenv.add_argument("--gateway-cpus", default=None, help="CPUs for the gateway alone, e.g. 0 (default: any)")
    tenv.add_argument("--host-cpus", default=None, help="CPUs for the hosts, router and mocks, e.g. 1-7")
    tenv.add_argument("--every", type=float, default=5.0, help="seconds between samples (default 5)")
    tenv.add_argument("--max-minutes", type=float, default=None, help="stop each drive after this long")
    tenv.add_argument("--keep", action="store_true", help="leave each stack up for inspection")
    tenv.add_argument("--tag", default=stress.TAG, help="gonka-ai/gonka tag (default %s)" % stress.TAG)
    tenv.add_argument("--dry-run", action="store_true",
                      help="build the images, bring up G=8 on 3 hosts, 3 chats, finalize; READY or BLOCKED")
    tenv.add_argument("--cleanup", action="store_true",
                      help="remove every container, network, volume, work dir and image of this mode")
    return gateway


def run(args):
    return {"plan": cmd_plan, "stress": cmd_stress, "stand": cmd_stand,
            "testenv": cmd_testenv}[args.gateway_command](args)


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
    print("testenv  real devshardd hosts under versiond, the versiond router and the gateway from the same commit "
          "(source adds %s); mock chain, dapi and ML node; one compose stack per G, default G=64 on 4 hosts: "
          "20 warm-up chats, 8 in flight to nonce %d, %d quiet minutes, finalize, down" % (
              ", ".join(testenv.SPARSE[len(stress.SPARSE):]), testenv.ROUTING_STOP, DEFAULT_QUIET_MINUTES))
    print("         builds %s-<image>:<commit>, devshardd extracted to the cache; --quiet-only skips the drive; "
          "--cleanup removes all of it" % testenv.PREFIX)
    print("network  github.com for the source, the Go module proxy, Docker Hub base images, Alpine packages; "
          "nothing to any Gonka network; the stand and testenv gateways on 127.0.0.1 only")
    print("cache    %s" % cache)
    print("writes   %s/<run>/: report.md, checkpoints.csv, gateway.svg, host.svg, go-test-g<G>.log" %
          os.path.join(data_dir(), "runs"))
    print("         stand: report.md, samples.csv, stand-cpu.svg, stand-rss.svg, g<G>-h<H>-c<x>/ with seed, env, logs, "
          "finalize.json")
    print("         testenv: report.md, samples.csv, hosts.csv, cores.csv, containers.csv, g<G>/ with gencompose.log, "
          "logs, finalize.json; stacks in %s while they run" % os.path.join(data_dir(), "testenv"))
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
        try:
            code, events, interrupted = stress.run_one(argv, cwd, proc_env, log_path, progress(args.nonces),
                                                       guard=lambda: stress.disk_guard([run_dir]))
        finally:
            if runner == "docker":
                stress.remove_container(name)
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


def _stand_one(groups, hosts, concurrency, args, commit, run_id, run_dir, on_log, guard=None):
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
        base = stand.start(names, commit, group_dir, gateway_data, hosts, args.delay_ms,
                           gateway_cpus=args.gateway_cpus, host_cpus=args.host_cpus)
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
                     guard=guard)
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
                handle.write("".join(stress.shorten(line + "\n") for line in stand.logs(name, tail=2000).splitlines()))
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
        for flag, value in (("--gateway-cpus", args.gateway_cpus), ("--host-cpus", args.host_cpus)):
            if value is not None and not CPUS.match(value):
                raise ValueError("%s needs a CPU list such as 0, 1-3 or 0,2" % flag)
    except ValueError as error:
        sys.stderr.write("gcheck: %s\n" % error)
        return EXIT_CODES["GUARD_STOP"]
    if args.dry_run:
        stands = [(stands[0][0], stands[0][1], 1)]
    run_id, run_dir = _run_dir("stand")
    recorder = Recorder(run_dir)
    cache = os.path.join(data_dir(), "cache", "gateway-load")
    meta = {"tool": "gonka-check %s" % __version__, "run_id": run_id, "mode": "gateway-stand", "tag": args.tag,
            "stands": stands, "delay_ms": args.delay_ms, "gateway_cpus": args.gateway_cpus,
            "host_cpus": args.host_cpus, "nonces": args.nonces, "started_at": utc_now()}
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
            disks = [run_dir] + [path for path in [stand.docker_root()] if path]

            def guard():
                return stand.memory_guard() or stress.disk_guard(disks)

            runs = []
            for size, hosts, concurrency in stands:
                runs.append(_stand_one(size, hosts, concurrency, args, commit, run_id, run_dir, log, guard))
                verdict, stop = runs[-1]["verdict"], runs[-1]["summary"]["stop"] or ""
                print("%-12s %-18s %s" % (verdict["verdict"], verdict["check"], verdict["reason"]))
                if verdict["verdict"] == "BLOCKED" or stop == "interrupted" or stop.startswith(("machine memory",
                                                                                               "disk below")):
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


def _testenv_one(size, hosts, index, args, source, cache, commit, devshardd, run_id, run_dir, on_log, guard=None):
    work_root = os.path.join(data_dir(), "testenv")
    stack = testenv.Stack(run_id, size, hosts, work_root)
    label = "G=%d N=%d" % (size, hosts)
    group_dir = os.path.join(run_dir, "g%d" % size)
    os.makedirs(group_dir, mode=0o700, exist_ok=True)
    mode = "dry-run" if args.dry_run else "quiet-only" if args.quiet_only else "drive"
    rotating = args.rotation if mode == "drive" and args.rotation != "off" else None
    tag = "%s-g%d" % (run_id[-4:], size)
    sampler, warm, drive, final, error, stop, stopped = None, None, None, None, None, None, []
    manual_t = None
    try:
        on_log("%s: gencompose and compose patch" % label)
        stack.generate(source, cache, devshardd, commit, testenv.binary_version(args.tag),
                       os.path.join(group_dir, "gencompose.log"), testenv.SUBNET_OCTET + index,
                       args.gateway_cpus, args.host_cpus, args.rotation)
        base = stack.up()
        on_log("%s: stack %s up, gateway on %s" % (label, stack.project, base))
        sampler = testenv.Sampler(stack, base, time.monotonic())
        sampler.take("up")
        warm = testenv.warm_up(base, testenv.DRY_CHATS if args.dry_run else testenv.WARM_CHATS, tag + "-w",
                               stack.addresses)
        sampler.take("warm")
        on_log("%s: warm-up %d of %d chats, nonce %s" % (label, warm.codes.get(200, 0), sum(warm.codes.values()),
                                                         sampler.samples[-1]["nonce"]))
        if mode == "drive":
            drive = testenv.Drive(base, args.concurrency, testenv.ROUTING_STOP, tag, stack.addresses)

            def on_sample():
                nonce = sampler.take("drive")
                if len(sampler.samples) % 12 == 0:
                    item = sampler.samples[-1]
                    on_log("%s drive nonce %s: gateway CPU %s%%, RSS %.0f MB, hosts %.0f MB, unquarantined %d" % (
                        label, nonce, item["cpu_pct"], item["rss_mb"], item["hosts_mem_mb"], drive.unquarantines))
                return nonce

            drive.run(on_sample, every_s=args.every, max_s=args.max_minutes * 60 if args.max_minutes else None,
                      guard=guard)
            sampler.stop_t = round((drive.ended or time.monotonic()) - sampler.started, 1)
            on_log("%s: drive %s" % (label, drive.reason))
        reached = mode == "drive" and testenv.reached(drive, sampler.samples)
        if (mode == "quiet-only" or reached) and args.quiet_minutes > 0:
            on_log("%s: quiet for %g min%s" % (label, args.quiet_minutes, ", the gateway rotates escrow 1 (%s)" %
                                               rotating if rotating else ""))

            def on_quiet():
                known = set(sampler.events)
                sampler.take("quiet", diffs=True)
                for name in sorted(set(sampler.events) - known):
                    item = sampler.events[name]
                    on_log("%s: %s +%.0f s after the routing stop, nonce %s, hosts' last diff %s..%s" % (
                        label, name, item["t_s"] - (sampler.stop_t or 0), item["nonce"], item["host_last_min"],
                        item["host_last_max"]))
                if len(sampler.samples) % 12 == 0:
                    item = sampler.samples[-1]
                    on_log("%s quiet nonce %s: hosts' last diff %s..%s, %s turns, %d refusals at the active cap" % (
                        label, item["nonce"], item["host_last_min"], item["host_last_max"], item["heartbeats"],
                        item["cap_lines"]))

            stop = testenv.quiet(on_quiet, args.quiet_minutes, args.every, guard)
        sampler.take("settle", diffs=True)
        if rotating == "settle":
            on_log("%s: no finalize from here, the gateway settles escrow 1 itself" % label)
        elif rotating == "deactivate":
            on_log("%s: settling escrow 1 by hand at nonce %s, Ctrl-C skips it" % (label, sampler.nonce))
            manual_t = time.monotonic() - sampler.started
            final = testenv.settle(base, size, os.path.join(group_dir, "settle.json"))
            on_log("%s: manual settlement %s in %.1f s %s" % (label, final["code"], final["seconds"],
                                                              final["error"] or final["tx_hash"]))
        else:
            on_log("%s: finalizing at nonce %s, Ctrl-C skips it" % (label, sampler.samples[-1]["nonce"]))
            final = testenv.finalize(base, size, os.path.join(group_dir, "finalize.json"))
            on_log("%s: finalize %s in %.1f s, weight %s of %s" % (label, final["code"], final["seconds"],
                                                                   final["weight"], final["quorum"]))
        sampler.take("final", diffs=True)
    except stand.StandError as failure:
        error = str(failure)
    except KeyboardInterrupt:
        stop = "interrupted"
    finally:
        stopped = stack.exited()
        for service, file in (("devshardctl", "gateway.log"), ("versiond-0", "host-0.log")):
            with open(os.path.join(group_dir, file), "w", encoding="utf-8") as handle:
                handle.write("".join(stress.shorten(line + "\n") for line in stack.logs(service).splitlines()))
        if args.keep:
            on_log("%s: kept; docker compose -p %s -f %s; gcheck gateway-load testenv --cleanup removes it" % (
                label, stack.project, stack.compose_file))
        else:
            stack.down()
    samples = sampler.samples if sampler else []
    rotation = None
    if sampler and args.rotation != "off":
        rotation = testenv.timeline(args.rotation, sampler, args.quiet_minutes, final, manual_t)
    summary = testenv.summarize(size, hosts, args.concurrency, mode, warm, drive, samples, final, error, stop, stopped,
                                (args.gateway_cpus, args.host_cpus), rotation)
    return {"groups": size, "label": label, "samples": samples, "summary": summary, "verdict": testenv.judge(summary)}


def _testenv_cleanup():
    roots = [os.path.join(data_dir(), "testenv"), os.path.join(data_dir(), "cache", "gateway-load", "testenv")]
    try:
        with RunLock(os.path.join(config_dir(), "gateway-load.lock")):
            if not shutil.which("docker"):
                raise stress.StressError("needs docker")
            removed = testenv.cleanup(roots)
    except LockBusy as error:
        print("cleanup  BLOCKED\n         lock: %s" % error)
        return EXIT_CODES["BLOCKED"]
    except stress.StressError as error:
        print("cleanup  BLOCKED\n         %s" % error)
        return EXIT_CODES["BLOCKED"]
    for kind in ("containers", "networks", "volumes", "dirs", "images"):
        print("removed  %s: %s" % (kind, ", ".join(removed[kind]) or "none"))
    return 0


def cmd_testenv(args):
    if args.cleanup:
        return _testenv_cleanup()
    try:
        groups = [8] if args.dry_run else groups_of(args.groups)
        if args.hosts > len(keys.HOST_ADDRESSES):
            raise ValueError("--hosts needs 1 to %d" % len(keys.HOST_ADDRESSES))
        if args.concurrency > 256:
            raise ValueError("--concurrency needs 1 to 256")
        if args.quiet_minutes < 0 or args.every <= 0:
            raise ValueError("--quiet-minutes needs 0 or more and --every a positive number")
        if args.quiet_minutes == 0 and (args.quiet_only or args.rotation != "off"):
            raise ValueError("--quiet-only and --rotation need --quiet-minutes above 0")
        if args.quiet_only and args.rotation != "off":
            raise ValueError("--rotation needs the drive, not --quiet-only")
        if len(groups) > 100:
            raise ValueError("--groups takes at most 100 sizes")
        for flag, value in (("--gateway-cpus", args.gateway_cpus), ("--host-cpus", args.host_cpus)):
            if value is not None and not CPUS.match(value):
                raise ValueError("%s needs a CPU list such as 0, 1-7 or 0,2" % flag)
    except ValueError as error:
        sys.stderr.write("gcheck: %s\n" % error)
        return EXIT_CODES["GUARD_STOP"]
    hosts = 3 if args.dry_run else args.hosts
    run_id, run_dir = _run_dir("testenv")
    recorder = Recorder(run_dir)
    cache = os.path.join(data_dir(), "cache", "gateway-load")
    mode = "dry-run" if args.dry_run else "quiet-only" if args.quiet_only else "drive"
    meta = {"tool": "gonka-check %s" % __version__, "run_id": run_id, "mode": "gateway-testenv", "tag": args.tag,
            "groups": groups, "hosts": hosts, "concurrency": args.concurrency, "run": mode,
            "quiet_minutes": args.quiet_minutes, "rotation": args.rotation, "gateway_cpus": args.gateway_cpus,
            "host_cpus": args.host_cpus, "max_nonce": testenv.MAX_NONCE, "routing_stop": testenv.ROUTING_STOP,
            "started_at": utc_now()}
    runs = []
    try:
        with RunLock(os.path.join(config_dir(), "gateway-load.lock")):
            if not shutil.which("docker"):
                raise stress.StressError("needs docker")
            source, commit = stress.prepare_source(cache, args.tag, sparse=testenv.SPARSE, test_file=False)
            meta["commit"] = commit
            recorder.write_json("manifest.json", meta)
            print("source   %s at %s" % (args.tag, commit[:12]))
            log("build    devshardd, gateway, versiond, router and mock images (once per commit)")
            devshardd, built = testenv.build_images(source, commit, cache, os.path.join(run_dir, "docker-build.log"),
                                                    args.tag)
            log("build    %s" % (", ".join(built) or "all images already there"))
            disks = [run_dir, data_dir()] + [path for path in [stand.docker_root()] if path]

            def guard():
                return stand.memory_guard() or stress.disk_guard(disks)

            for index, size in enumerate(groups):
                runs.append(_testenv_one(size, min(hosts, size), index, args, source, cache, commit, devshardd,
                                         run_id, run_dir, log, guard))
                verdict, stop = runs[-1]["verdict"], runs[-1]["summary"]["stop"] or ""
                print("%-12s %-13s %s" % (verdict["verdict"], verdict["check"], verdict["reason"]))
                if verdict["verdict"] == "BLOCKED" or stop == "interrupted" or stop.startswith(("machine memory",
                                                                                               "disk below")):
                    break
    except LockBusy as error:
        print("ready    BLOCKED\n         lock: %s" % error)
        return EXIT_CODES["BLOCKED"]
    except (stress.StressError, stand.StandError) as error:
        print("ready    BLOCKED\n         %s" % error)
        recorder.write_json("summary.json", {"mode": "gateway-testenv", "overall": "BLOCKED", "reason": str(error)})
        return EXIT_CODES["BLOCKED"]
    verdicts = [run["verdict"] for run in runs]
    result = overall(verdicts)
    with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump({"mode": "gateway-testenv", "overall": result, "verdicts": verdicts,
                   "summaries": [run["summary"] for run in runs], "finished_at": utc_now()}, handle, indent=2,
                  sort_keys=True)
        handle.write("\n")
    if args.dry_run:
        print("ready    %s" % ("READY" if result == "PASS" else "BLOCKED"))
        if result != "PASS":
            print("         %s" % "; ".join(item["reason"] for item in verdicts))
        print("records  %s" % run_dir)
        return 0 if result == "PASS" else EXIT_CODES["BLOCKED"]
    files = report.write_testenv(run_dir, meta, runs, verdicts, result)
    print("written  %s: %s" % (run_dir, ", ".join(files)))
    print("overall  %s (exit %d)" % (result, EXIT_CODES[result]))
    return EXIT_CODES[result]
