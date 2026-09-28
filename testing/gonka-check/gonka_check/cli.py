"""gcheck: plan, run --dry-run, run --profile smoke, selftest."""

import argparse
import datetime
import os
import secrets
import sys
import time
import traceback
import unittest

from . import __version__
from . import chaincheck
from .chain import Chain
from .checks import CHECKS, JUDGES, fence_audit, model_served, verdict
from .guards import GuardStop, Guards
from .preflight import preflight
from .record import Recorder, utc_now
from .scheduler import BudgetSpent, Ledger, LockBusy, NoSlot, RunLock, Scheduler
from .summary import EXIT_CODES, SSL_HINT, hints, overall, render
from .target import (ROOT, TargetRefused, check_profile, config_dir, data_dir, is_loopback, key_fingerprint,
                     key_path, load_key, load_preset)
from .transport import Client
from .watch import Watch


WATCH_MIN_INTERVAL_S = 5


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("gcheck: error: %s\n" % message)
        sys.exit(EXIT_CODES["GUARD_STOP"])


def log(message):
    sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


def plan_chain(preset):
    print("target   %s (%s)" % (preset["base_url"], preset["name"]))
    print("profile  chain: GET only, no key, no completion")
    print("nodes    %s" % (", ".join(preset.get("node_rpcs", [])) or "none"))
    print("checks")
    for check in chaincheck.CHAIN_CHECKS:
        print("  %-14s %-8s %s" % (check["id"], ",".join(check["maps"]), check["what"]))
    print("total    0 POST")
    return 0


def cmd_plan(args):
    preset = load_preset(args.preset)
    check_profile(preset, args.profile)
    if args.profile == "chain":
        return plan_chain(preset)
    path = key_path(preset, args.key_file)
    _key, problem = load_key(path)
    window = preset["send_window"]
    print("target   %s (%s, point %s)" % (preset["base_url"], preset["name"], preset.get("point", "-")))
    print("model    %s" % preset["model"])
    print("profile  %s" % args.profile)
    print("window   epoch offset from safe_start+%d to epoch_length-%d, read from chain params at run time"
          % (window["from_offset"], window["stop_before_end"]))
    print("pacing   one request in flight, sends at least %d blocks apart, deadline now+%ds"
          % (preset["min_blocks_between_sends"], preset["deadline_s"]))
    print("budget   %d POST per run, %d per epoch; ledger %s" % (
        preset["budget"]["per_run"], preset["budget"]["per_epoch"], os.path.join(config_dir(), "ledger.jsonl")))
    print("key      %s (%s)" % (path, problem or "present, mode 0600"))
    print("checks")
    for check in CHECKS:
        print("  %-12s %-15s %d POST  %s" % (check["id"], ",".join(check["maps"]), check["posts"], check["what"]))
    print("total    %d POST" % sum(check["posts"] for check in CHECKS))
    return 0


def smoke(client, chain, preset, readiness, key, run_id, wait_s):
    verdicts = [model_served(readiness["models_reply"], preset["model"])]
    if readiness["state"] != "READY":
        reason = "not sent: preflight BLOCKED"
        verdicts += [verdict(check, "BLOCKED", reason) for check in ("canary", "floor64", "fence_audit")]
        return verdicts, [], None
    scheduler = Scheduler(client, chain, preset, readiness["facts"],
                          Ledger(os.path.join(config_dir(), "ledger.jsonl")), run_id, log)
    guards, replies, stop = Guards(), [], None
    tag = "gcheck-%s" % secrets.token_hex(4)
    for check, (build, judge) in JUDGES.items():
        if stop is not None:
            verdicts.append(verdict(check, "INCONCLUSIVE", "not sent: run stopped by a guard"))
            continue
        try:
            slot = scheduler.next_slot(wait_s)
            scheduler.reserve(check, slot)
        except NoSlot as error:
            verdicts.append(verdict(check, "INCONCLUSIVE", "not sent: %s" % error))
            continue
        except BudgetSpent as error:
            verdicts.append(verdict(check, "BLOCKED", "not sent: %s" % error))
            continue
        client.get(preset["health_url"])
        log("sending %s at height %d (epoch %d, offset %d)" % (check, slot["height"], slot["epoch"], slot["offset"]))
        reply = client.post_completion(build(preset["model"], "%s-%s" % (tag, check)), key, check)
        replies.append(reply)
        verdicts.append(judge(reply))
        try:
            guards.after_post(reply)
        except GuardStop as error:
            stop = error
            log("guard stop: %s; %s" % (error.reason, error.advice))
    verdicts.append(fence_audit(replies, readiness["facts"]))
    return verdicts, replies, stop


def cmd_run(args):
    preset = load_preset(args.preset)
    chain_only = args.profile == "chain"
    if chain_only or not args.dry_run:
        check_profile(preset, args.profile)
    mode = "dry-run" if args.dry_run and not chain_only else args.profile
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = "%s-%s-%s-%s" % (stamp, preset["name"], mode, secrets.token_hex(2))
    run_dir = os.path.join(data_dir(), "runs", run_id)
    recorder = Recorder(run_dir)
    key, key_problem = (None, None) if chain_only else load_key(key_path(preset, args.key_file))
    started = utc_now()
    recorder.write_json("manifest.json", {
        "tool": "gonka-check %s" % __version__, "run_id": run_id, "preset": preset,
        "mode": mode, "started_at": started, "key_sha256_prefix": key_fingerprint(key),
        "wait_s": args.wait,
    })
    client = Client(preset, recorder)
    chain = Chain(client, preset)
    readiness, verdicts, stop, interrupted = None, [], None, False
    try:
        if chain_only:
            readiness = {"state": "SKIPPED", "reasons": [], "items": [], "facts": {}}
            verdicts = [
                chaincheck.chain_advances(chain, preset.get("chain_advance_wait_s", 12)),
                chaincheck.nodes_at_tip(chain, preset.get("node_rpcs", []), preset.get("node_max_lag_blocks", 5)),
                chaincheck.epoch_state(chain),
            ]
        elif args.dry_run:
            readiness = preflight(client, chain, preset, key_problem, args.wait, log)
        else:
            with RunLock(os.path.join(config_dir(), "run.lock")):
                readiness = preflight(client, chain, preset, key_problem, args.wait, log)
                verdicts, _replies, stop = smoke(client, chain, preset, readiness, key, run_id, args.wait)
    except LockBusy as error:
        readiness = {"state": "BLOCKED", "reasons": ["lock: %s" % error], "items": [], "facts": {}}
    except KeyboardInterrupt:
        interrupted = True
        readiness = readiness or {"state": "BLOCKED", "reasons": ["interrupted"], "items": [], "facts": {}}
    readiness.pop("models_reply", None)
    if args.dry_run and not chain_only:
        result = readiness["state"] if not interrupted else "BLOCKED"
        code = 0 if result == "READY" else EXIT_CODES["BLOCKED"]
    else:
        result = "INCONCLUSIVE" if interrupted else overall(verdicts, stop) if verdicts else "BLOCKED"
        code = EXIT_CODES[result]
    summary = {
        "tool": "gonka-check %s" % __version__, "run_id": run_id, "run_dir": run_dir,
        "preset": preset["name"], "target": preset["base_url"], "mode": mode,
        "started_at": started, "finished_at": utc_now(), "readiness": readiness,
        "posts": client.posts, "interrupted": interrupted, "verdicts": verdicts,
        "guard": stop.to_dict() if stop else None, "overall": result, "exit_code": code,
    }
    summary["hints"] = hints(summary)
    recorder.write_json("summary.json", summary)
    print(render(summary))
    return code


def cmd_watch(args):
    preset = load_preset(args.preset)
    interval = args.interval if args.interval is not None else preset.get("watch_interval_s", 10)
    if not is_loopback(preset["base_url"]):
        floor = max(float(preset["chain_poll_s"]), WATCH_MIN_INTERVAL_S)
        interval = interval if interval >= floor else floor
    # With --epochs the run ends once the epochs are complete; the cap guards a network that never completes one.
    duration = args.duration if args.duration is not None else (max(3600, 1200 * args.epochs) if args.epochs else 3600)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = "%s-%s-watch-%s" % (stamp, preset["name"], secrets.token_hex(2))
    run_dir = os.path.join(data_dir(), "runs", run_id)
    recorder = Recorder(run_dir)
    started = utc_now()
    recorder.write_json("manifest.json", {
        "tool": "gonka-check %s" % __version__, "run_id": run_id, "preset": preset, "mode": "watch",
        "started_at": started, "interval_s": interval, "duration_s": duration, "epochs": args.epochs,
    })
    client = Client(preset, None)
    def out(text):
        print(text, flush=True)

    watcher = Watch(client, Chain(client, preset), preset, run_dir, log, out)
    out("watch    %s every %ss, up to %ds%s, GET only" % (
        preset["base_url"], interval, duration, " or %d complete epochs" % args.epochs if args.epochs else ""))
    interrupted = watcher.run(interval, duration, args.epochs)
    if watcher.epochs:
        out(next(reversed(watcher.epochs.values())).line(watcher.params["epoch_length"]))
    summary = {"tool": "gonka-check %s" % __version__, "run_id": run_id, "run_dir": run_dir,
               "preset": preset["name"], "target": preset["base_url"], "mode": "watch",
               "started_at": started, "finished_at": utc_now(), "interrupted": interrupted}
    summary.update(watcher.summary(args.epochs))
    totals = summary["totals"]
    summary["hints"] = [SSL_HINT] if any("CERTIFICATE_VERIFY_FAILED" in error for error in totals["errors"]) else []
    recorder.write_json("summary.json", summary)
    share = totals["window_ready_share"]
    out("epochs   %d seen, %d complete" % (totals["epochs_seen"], totals["epochs_complete"]))
    out("window   ready %d of %d samples%s" % (totals["window_ready"], totals["window_samples"],
                                               " (%d%%)" % round(100 * share) if share is not None else ""))
    out("cpoc     in %d of %d complete epochs" % (totals["complete_epochs_with_confirmation_poc"],
                                                  totals["epochs_complete"]))
    out("health   %s" % (", ".join("%s x%d" % item for item in totals["health"].items()) or "-"))
    if totals["errors"]:
        out("errors   %s" % ", ".join("%s x%d" % item for item in totals["errors"].items()))
    for hint in summary["hints"]:
        out("hint     %s" % hint)
    out("records  %s" % os.path.join(run_dir, "samples.jsonl"))
    # Without one valid sample the watch observed nothing.
    return 0 if totals["epochs_seen"] else EXIT_CODES["INCONCLUSIVE"]


def cmd_selftest(_args):
    suite = unittest.defaultTestLoader.discover(os.path.join(ROOT, "tests"), top_level_dir=ROOT)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() else 1


def build_parser():
    parser = Parser(prog="gcheck", description="Smoke checks for Gonka inference through a public gateway.")
    parser.add_argument("--version", action="version", version="gonka-check %s" % __version__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name, text in (("plan", "print target, budget and checks; no network"),
                       ("run", "run the preflight and, unless --dry-run, the smoke checks")):
        command = commands.add_parser(name, help=text)
        command.add_argument("--preset", default="devnet", help="preset name or path to a preset JSON")
        command.add_argument("--profile", default="smoke", help="check profile: smoke or chain")
        command.add_argument("--key-file", help="API key file, mode 0600 (default: ~/.config/gonka-check/<preset>.key)")
        if name == "run":
            command.add_argument("--dry-run", action="store_true", help="GET only; report READY or BLOCKED")
            command.add_argument("--wait", type=int, default=420,
                                 help="seconds to wait for readiness and for each send slot (default 420)")
    watch = commands.add_parser("watch", help="sample chain, gateway and health readiness; GET only")
    watch.add_argument("--preset", default="devnet", help="preset name or path to a preset JSON")
    watch.add_argument("--interval", type=float, help="seconds between samples (default from the preset)")
    watch.add_argument("--duration", type=int, help="seconds to watch (default 3600, or 1200 per epoch with --epochs)")
    watch.add_argument("--epochs", type=int, default=0, help="stop after this many complete epochs")
    commands.add_parser("selftest", help="run the unit tests against a local fake gateway")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    handler = {"plan": cmd_plan, "run": cmd_run, "watch": cmd_watch, "selftest": cmd_selftest}[args.command]
    try:
        return handler(args)
    except TargetRefused as error:
        sys.stderr.write("gcheck: refused: %s\n" % error)
        return EXIT_CODES["GUARD_STOP"]
    except Exception:
        traceback.print_exc()
        return EXIT_CODES["GUARD_STOP"]
