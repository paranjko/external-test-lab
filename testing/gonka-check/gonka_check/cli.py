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
from .chain import Chain
from .checks import CHECKS, JUDGES, fence_audit, model_served, verdict
from .guards import GuardStop, Guards
from .preflight import preflight
from .record import Recorder, utc_now
from .scheduler import BudgetSpent, Ledger, LockBusy, NoSlot, RunLock, Scheduler
from .summary import EXIT_CODES, hints, overall, render
from .target import (ROOT, TargetRefused, check_profile, config_dir, data_dir, key_fingerprint,
                     key_path, load_key, load_preset)
from .transport import Client


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        sys.stderr.write("gcheck: error: %s\n" % message)
        sys.exit(EXIT_CODES["GUARD_STOP"])


def log(message):
    sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


def cmd_plan(args):
    preset = load_preset(args.preset)
    check_profile(preset, args.profile)
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
    if not args.dry_run:
        check_profile(preset, args.profile)
    mode = "dry-run" if args.dry_run else args.profile
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = "%s-%s-%s-%s" % (stamp, preset["name"], mode, secrets.token_hex(2))
    run_dir = os.path.join(data_dir(), "runs", run_id)
    recorder = Recorder(run_dir)
    key, key_problem = load_key(key_path(preset, args.key_file))
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
        if args.dry_run:
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
    if args.dry_run:
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
        command.add_argument("--profile", default="smoke", help="check profile (stage 0: smoke)")
        command.add_argument("--key-file", help="API key file, mode 0600 (default: ~/.config/gonka-check/<preset>.key)")
        if name == "run":
            command.add_argument("--dry-run", action="store_true", help="GET only; report READY or BLOCKED")
            command.add_argument("--wait", type=int, default=420,
                                 help="seconds to wait for readiness and for each send slot (default 420)")
    commands.add_parser("selftest", help="run the unit tests against a local fake gateway")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    handler = {"plan": cmd_plan, "run": cmd_run, "selftest": cmd_selftest}[args.command]
    try:
        return handler(args)
    except TargetRefused as error:
        sys.stderr.write("gcheck: refused: %s\n" % error)
        return EXIT_CODES["GUARD_STOP"]
    except Exception:
        traceback.print_exc()
        return EXIT_CODES["GUARD_STOP"]
