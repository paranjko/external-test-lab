"""gcheck escrow: plan, snapshot (GET only), verify, simulate, report; preflight, record and verdict of a G change."""

import argparse
import datetime
import json
import os
import re
import secrets
import sys
import time

from .. import __version__
from ..preflight import status_blocker
from ..record import Recorder, utc_now
from ..scheduler import LockBusy, RunLock
from ..source import SourceClient, SourceError, resolve
from ..summary import EXIT_CODES, SSL_HINT, overall
from ..target import config_dir, data_dir
from ..transport import Client
from . import evaluate, gchange, report
from .snapshot import ChainReads, capture, load_snapshot, probe, write_snapshot

MAX_REQUESTS = 4000
SUMMARY_KEYS = ("epoch", "latest_epoch_start", "height_start", "height_end", "group_size", "escrows_indexed",
                "escrow_range", "stopped")


def positive(text):
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("needs a positive number")
    return value


def add_parser(commands):
    escrow = commands.add_parser("escrow", help="escrow slot study: snapshot chain weights, simulate group sizes")
    sub = escrow.add_subparsers(dest="escrow_command", required=True)
    plan = sub.add_parser("plan", help="what a snapshot reads and roughly how long it takes; no network")
    plan.add_argument("--source", required=True, help="mainnet or devnet")
    snap = sub.add_parser("snapshot", help="read weights and the real escrows of the effective epoch; GET only")
    snap.add_argument("--source", required=True, help="mainnet or devnet")
    snap.add_argument("--dry-run", action="store_true", help="a few reads; READY or BLOCKED")
    snap.add_argument("--escrow-ids",
                      help="read this id range, FIRST-LAST, instead of the epoch's range from the tx index")
    snap.add_argument("--last", type=positive, help="read only the newest N escrows of the range")
    snap.add_argument("--max-requests", type=positive, default=MAX_REQUESTS,
                      help="request cap (default %d)" % MAX_REQUESTS)
    for name, text in (("verify", "replay the real escrows of a snapshot with the slots.go port; no network"),
                       ("simulate", "simulate escrows per model and group size; write CSV; no network"),
                       ("report", "verify, simulate and write report.md, charts and CSV; no network")):
        command = sub.add_parser(name, help=text)
        command.add_argument("snapshot", help="snapshot.json or the run directory that holds it")
        command.add_argument("--min-escrows", type=positive, default=30, help="real escrows needed for slots_replay")
        command.add_argument("--slots-go", help="slots.go of a chain checkout; adds the slots_source check")
        if name != "verify":
            command.add_argument("--groups", default="16,32,64", help="group sizes (default 16,32,64)")
            command.add_argument("--runs", type=positive, default=1000, help="simulated escrows per model and size")
            command.add_argument("--out", help="output directory (default: report/ next to the snapshot)")
    pre = sub.add_parser("preflight", help="readiness for a group size change run; GET only")
    pre.add_argument("--source", default="devnet", help="devnet or a loopback URL")
    pre.add_argument("--gateway", default="a", choices=("a", "b"), help="gateway that creates and settles the escrows")
    pre.add_argument("--from", dest="start_size", type=positive, default=5, help="group_size the run starts from (5)")
    pre.add_argument("--need", type=positive, default=2, help="free escrow places the run needs (2)")
    rec = sub.add_parser("record", help="evidence of a group size change run from public chain reads; GET only")
    rec.add_argument("--source", default="devnet", help="devnet or a loopback URL")
    rec.add_argument("--a", type=positive, required=True, help="escrow created before the change")
    rec.add_argument("--b", type=positive, help="escrow created after the change")
    rec.add_argument("--change", type=positive, help="proposal that changed group_size")
    rec.add_argument("--rollback", type=positive, help="proposal that restored group_size")
    rec.add_argument("--attempt", action="append", default=[], metavar="ROLE=TXHASH",
                     help="a settlement transaction the chain rejected, for escrow a or b")
    rec.add_argument("--max-requests", type=positive, default=400, help="request cap (default 400)")
    ver = sub.add_parser("verdict", help="verdicts and report.md from recorded evidence; no network")
    ver.add_argument("evidence", help="evidence.json or the run directory that holds it")
    ver.add_argument("--out", help="output directory (default: report/ next to the evidence)")
    return escrow


def log(message):
    sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), message))
    sys.stderr.flush()


def run(args):
    handler = {"plan": cmd_plan, "snapshot": cmd_snapshot, "verify": cmd_verify, "simulate": cmd_simulate,
               "report": cmd_report, "preflight": cmd_preflight, "record": cmd_record,
               "verdict": cmd_verdict}[args.escrow_command]
    return handler(args)


def cmd_plan(args):
    name, origin, interval = resolve(args.source)
    print("source   %s %s: GET only, no key, one request every %gs" % (name, origin, interval))
    print("reads    node_info, the effective epoch, epoch_info, params, the epoch group and one group per model,")
    print("         excluded participants; the tx index for the first and last escrow of the epoch;")
    print("         then one read per escrow id in that range")
    if name == "mainnet":
        print("estimate about 20 requests plus one per escrow; mainnet creates about 1000-1500 escrows per epoch,")
        print("         so up to about %d minutes late in an epoch" % round((20 + 1500) * interval / 60))
    else:
        print("estimate about 20 requests plus one per escrow, %gs each" % interval)
    print("writes   %s/<run>/: snapshot.json, chain.jsonl, records.jsonl, summary.json"
          % os.path.join(data_dir(), "runs"))
    return 0


def _run_dir(source, mode):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_id = "%s-%s-escrow-%s-%s" % (stamp, source, mode, secrets.token_hex(2))
    return run_id, os.path.join(data_dir(), "runs", run_id)


def _hint(texts):
    if any("CERTIFICATE_VERIFY_FAILED" in (text or "") for text in texts):
        print("hint     %s" % SSL_HINT)


def cmd_snapshot(args):
    name, origin, interval = resolve(args.source)
    escrow_ids = None
    if args.escrow_ids:
        try:
            low, high = (int(part) for part in args.escrow_ids.split("-"))
        except ValueError:
            sys.stderr.write("gcheck: --escrow-ids needs FIRST-LAST\n")
            return EXIT_CODES["GUARD_STOP"]
        escrow_ids = (min(low, high), max(low, high))
    mode = "probe" if args.dry_run else "snapshot"
    run_id, run_dir = _run_dir(name, mode)
    recorder = Recorder(run_dir)
    recorder.write_json("manifest.json", {"tool": "gonka-check %s" % __version__, "run_id": run_id, "source": name,
                                          "origin": origin, "mode": "escrow-" + mode, "started_at": utc_now(),
                                          "escrow_ids": args.escrow_ids, "last": args.last,
                                          "max_requests": args.max_requests})
    source = SourceClient(origin, interval, recorder, args.max_requests)
    chain_log = open(os.path.join(run_dir, "chain.jsonl"), "a", encoding="utf-8")

    def sink(kind, key, body):
        chain_log.write(json.dumps({"at": utc_now(), "kind": kind, "key": key, "body": body}, sort_keys=True) + "\n")
        chain_log.flush()
        os.fsync(chain_log.fileno())

    chain = ChainReads(source, sink)
    print("source   %s %s: GET only, no key, one request every %gs" % (name, origin, interval))
    try:
        with RunLock(os.path.join(config_dir(), "source.lock")):
            if args.dry_run:
                return _probe(chain, source, recorder, run_dir)
            return _snapshot(chain, source, recorder, run_dir, escrow_ids, args.last)
    except LockBusy as error:
        print("ready    BLOCKED\n         lock: %s" % error)
        return EXIT_CODES["BLOCKED"]
    finally:
        chain_log.close()


def _chain_line(facts, heights):
    return "chain    %s (%s), effective epoch %s, %s, group size %s" % (
        facts.get("version") or "version unknown", report.commit_text(facts), facts.get("epoch", "?"), heights,
        facts.get("group_size", "?"))


def _probe(chain, source, recorder, run_dir):
    facts, reasons = probe(chain)
    state = "BLOCKED" if reasons else "READY"
    recorder.write_json("summary.json", {"mode": "escrow-probe", "state": state, "facts": facts, "reasons": reasons,
                                         "requests": source.requests, "retries": source.retries})
    if facts.get("height") is not None:
        print(_chain_line(facts, "height %d" % facts["height"]))
        if facts.get("latest_epoch", facts["epoch"]) != facts["epoch"]:
            print("note     PoC of epoch %d is running; escrows still go to epoch %d" % (facts["latest_epoch"],
                                                                                          facts["epoch"]))
    if facts.get("escrows_so_far") is not None:
        print("escrows  %d so far in this epoch, first id %s" % (facts["escrows_so_far"], facts["first_escrow"]))
    print("ready    %s" % state)
    for reason in reasons:
        print("         %s" % reason)
    _hint(reasons)
    print("records  %s" % run_dir)
    return 0 if state == "READY" else EXIT_CODES["BLOCKED"]


def _snapshot(chain, source, recorder, run_dir, escrow_ids, last):
    snap, stop = None, None
    try:
        snap = capture(chain, escrow_ids, last, log)
    except SourceError as error:
        stop = error.reason
    except KeyboardInterrupt:
        stop = "interrupted"
    if snap is None:
        verdicts = []
        summary = {"stopped": stop}
        print("stopped  %s" % stop)
    else:
        write_snapshot(os.path.join(run_dir, "snapshot.json"), snap)
        verdicts = [evaluate.check_weights(snap), evaluate.check_escrows(snap)]
        summary = {key: snap.get(key) for key in SUMMARY_KEYS}
        summary.update(escrows_read=sum(len(items) for items in snap["escrows"].values()),
                       escrows_failed=len(snap["escrows_failed"]), verdicts=verdicts)
        heights = "height %d..%s" % (snap["height_start"], snap["height_end"] or "?")
        print(_chain_line(dict(snap["chain"], epoch=snap["epoch"], group_size=snap["group_size"]), heights))
        print("models   %s" % ", ".join("%s %d" % (model, len(data["weights"]))
                                        for model, data in snap["models"].items()))
        print("escrows  %s: %d read (%s); not found %d, failed %d, other epoch %d" % (
            "ids %d..%d" % tuple(snap["escrow_range"]) if snap.get("escrow_range") else "no range",
            summary["escrows_read"], ", ".join("%s %d" % (model.split("/")[-1], len(items))
                                               for model, items in snap["escrows"].items()),
            len(snap["escrows_missing"]), len(snap["escrows_failed"]), len(snap["escrows_other_epoch"])))
        if snap.get("stopped"):
            print("stopped  %s; what was read is kept" % snap["stopped"])
        for item in verdicts:
            print("%-8s %s %s" % (item["check"], item["verdict"], item["reason"]))
    result = overall(verdicts) if verdicts else "INCONCLUSIVE"
    summary.update(mode="escrow-snapshot", overall=result, requests=source.requests, retries=source.retries,
                   finished_at=utc_now())
    recorder.write_json("summary.json", summary)
    print("requests %d (retries %d)" % (source.requests, source.retries))
    _hint([stop, snap and snap.get("stopped")])
    print("overall  %s (exit %d)" % (result, EXIT_CODES[result]))
    print("records  %s" % run_dir)
    return EXIT_CODES[result]


def _load(path):
    try:
        return load_snapshot(path)
    except (OSError, ValueError) as error:
        sys.stderr.write("gcheck: %s\n" % error)
        return None, None


def _print_verdicts(verdicts):
    for item in verdicts:
        print("%-12s %-13s %s" % (item["verdict"], item["check"], item["reason"]))
    result = overall(verdicts)
    print("overall  %s (exit %d)" % (result, EXIT_CODES[result]))
    return EXIT_CODES[result]


def cmd_verify(args):
    snap, _path = _load(args.snapshot)
    if snap is None:
        return EXIT_CODES["GUARD_STOP"]
    verdicts = [evaluate.check_weights(snap), evaluate.check_escrows(snap), evaluate.replay(snap, args.min_escrows)[0]]
    if args.slots_go:
        verdicts.append(evaluate.check_source(args.slots_go))
    return _print_verdicts(verdicts)


def _groups(text):
    groups = sorted({int(part) for part in text.split(",") if part.strip()})
    if not groups or groups[0] <= 0:
        raise ValueError("--groups needs positive sizes")
    return groups


def _evaluate(args):
    snap, path = _load(args.snapshot)
    if snap is None:
        return None, None, None
    try:
        groups = _groups(args.groups)
    except ValueError as error:
        sys.stderr.write("gcheck: %s\n" % error)
        return None, None, None
    result = evaluate.evaluate(snap, groups, args.runs, args.min_escrows, args.slots_go)
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(path)), "report")
    return snap, result, out


def cmd_simulate(args):
    snap, result, out = _evaluate(args)
    if snap is None:
        return EXIT_CODES["GUARD_STOP"]
    os.makedirs(out, exist_ok=True)
    excluded = {item["address"] for item in snap["excluded"]}
    for name, text in (("selection.csv", report.selection_csv(result, excluded)),
                       ("addresses.csv", report.address_csv(result))):
        with open(os.path.join(out, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    print("written  %s: selection.csv, addresses.csv" % out)
    return _print_verdicts(result["verdicts"])


def cmd_report(args):
    snap, result, out = _evaluate(args)
    if snap is None:
        return EXIT_CODES["GUARD_STOP"]
    files = report.write(out, snap, result)
    with open(os.path.join(out, "verdicts.json"), "w", encoding="utf-8") as handle:
        json.dump({"epoch": snap["epoch"], "groups": result["groups"], "runs": result["runs"],
                   "verdicts": result["verdicts"], "overall": overall(result["verdicts"])}, handle, indent=2,
                  sort_keys=True)
        handle.write("\n")
    print("written  %s: %s, verdicts.json" % (out, ", ".join(files)))
    return _print_verdicts(result["verdicts"])


def _share(value):
    return "%.3g%%" % (100 * value)


def cmd_preflight(args):
    name, origin, interval = resolve(args.source)
    if name not in ("devnet", "loopback"):
        sys.stderr.write("gcheck: a group size change runs on DevNet only\n")
        return EXIT_CODES["GUARD_STOP"]
    run_id, run_dir = _run_dir(name, "gchange-preflight")
    recorder = Recorder(run_dir)
    recorder.write_json("manifest.json", {"tool": "gonka-check %s" % __version__, "run_id": run_id, "source": name,
                                          "origin": origin, "mode": "escrow-gchange-preflight", "started_at": utc_now(),
                                          "gateway": args.gateway})
    source = SourceClient(origin, interval, recorder, 200)
    reads = gchange.Reads(source, lambda *_args: None)
    gateway = "%s/%s" % (origin, args.gateway)
    client = Client({"base_url": origin, "gateway_path": "/" + args.gateway, "health_url": None,
                     "forbid_paths": [], "node_rpcs": []}, recorder)
    print("source   %s %s: GET only, no key, one request every %gs" % (name, origin, interval))
    reply = client.get(gateway + "/v1/status")
    blocker = status_blocker(reply.json) if reply.ok else "status HTTP %s" % (reply.status or reply.transport_error)
    try:
        facts, reasons, notes = gchange.preflight(reads, (blocker, reply.json if reply.ok else None),
                                                  args.start_size, args.need)
    except SourceError as error:
        facts, reasons, notes = {}, [error.reason], []
    if "height" in facts:
        print("chain    height %d, epoch %d (latest %d), cycle start %d, offset %d of %d" % (
            facts["height"], facts["epoch"], facts["latest_epoch"], facts["cycle_start"],
            facts["height"] - facts["cycle_start"], facts["epoch_length"]))
        print("escrows  group_size %d; %d of %d created in epoch %d" % (
            facts["group_size"], facts["escrows_created"], facts["max_escrows"], facts["epoch"]))
    if "creator" in facts:
        print("gateway  %s: %s; creator %s, %s settlements" % (
            gateway, blocker or "routable", facts["creator"] or "unknown", facts.get("creator_settlements", "?")))
    if "gov" in facts:
        gov = facts["gov"]
        print("gov      voting %s, quorum %s, threshold %s, deposit %s" % (
            gov["voting_period"], _share(float(gov["quorum"] or 0)), _share(float(gov["threshold"] or 0)),
            ",".join("%s%s" % (c.get("amount"), c.get("denom")) for c in gov["min_deposit"] or [])))
        print("voters   %s" % ", ".join("…%s %s" % (address[-6:], _share(share))
                                        for address, share in facts["validators"]))
    for note in notes:
        print("note     %s" % note)
    state = "BLOCKED" if reasons else "READY"
    print("ready    %s" % state)
    for reason in reasons:
        print("         %s" % reason)
    _hint(reasons)
    recorder.write_json("summary.json", {"mode": "escrow-gchange-preflight", "state": state, "facts": facts,
                                         "reasons": reasons, "notes": notes, "requests": source.requests})
    print("records  %s" % run_dir)
    return 0 if state == "READY" else EXIT_CODES["BLOCKED"]


def cmd_record(args):
    name, origin, interval = resolve(args.source)
    attempts = {}
    for text in args.attempt:
        role, _sep, tx_hash = text.partition("=")
        if role not in ("a", "b") or not re.fullmatch(r"[0-9A-Fa-f]{64}", tx_hash):
            sys.stderr.write("gcheck: --attempt needs a=TXHASH or b=TXHASH\n")
            return EXIT_CODES["GUARD_STOP"]
        attempts[role] = tx_hash.upper()
    escrows = {role: value for role, value in (("a", args.a), ("b", args.b)) if value}
    proposals = {role: value for role, value in (("change", args.change), ("rollback", args.rollback)) if value}
    run_id, run_dir = _run_dir(name, "gchange")
    recorder = Recorder(run_dir)
    recorder.write_json("manifest.json", {"tool": "gonka-check %s" % __version__, "run_id": run_id, "source": name,
                                          "origin": origin, "mode": "escrow-gchange-record", "started_at": utc_now(),
                                          "escrows": escrows, "proposals": proposals, "attempts": attempts})
    source = SourceClient(origin, interval, recorder, args.max_requests)
    chain_log = open(os.path.join(run_dir, "chain.jsonl"), "a", encoding="utf-8")

    def sink(kind, key, body, height):
        chain_log.write(json.dumps({"at": utc_now(), "kind": kind, "key": key, "height": height, "body": body},
                                   sort_keys=True) + "\n")
        chain_log.flush()

    print("source   %s %s: GET only, no key, one request every %gs" % (name, origin, interval))
    try:
        evidence = gchange.collect(gchange.Reads(source, sink), escrows, proposals, attempts, log)
    except SourceError as error:
        print("stopped  %s" % error.reason)
        _hint([error.reason])
        print("records  %s" % run_dir)
        return EXIT_CODES["INCONCLUSIVE"]
    finally:
        chain_log.close()
    gchange.write_evidence(os.path.join(run_dir, "evidence.json"), evidence)
    for role, item in sorted(evidence["escrows"].items()):
        settle = item["settle"]
        print("%-8s escrow %d: %d slots, group_size %d at creation height %d; %s" % (
            role.upper(), item["id"], len(item["escrow"].get("slots") or []), item["group_size_at_create"],
            item["create"]["height"], "settled at %d (code %d)" % (settle["height"], settle["code"]) if settle
            else "not settled"))
    for role, item in sorted(evidence["proposals"].items()):
        print("%-8s proposal %d: %s, group_size %s at height %s" % (
            role, item["id"], item["status"], item["group_size"], item.get("applied_height")))
    print("requests %d (retries %d)" % (source.requests, source.retries))
    print("records  %s" % run_dir)
    return 0


def cmd_verdict(args):
    try:
        evidence, path = gchange.load_evidence(args.evidence)
    except (OSError, ValueError) as error:
        sys.stderr.write("gcheck: %s\n" % error)
        return EXIT_CODES["GUARD_STOP"]
    verdicts = gchange.evaluate(evidence)
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(path)), "report")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "report.md"), "w", encoding="utf-8") as handle:
        handle.write(gchange.markdown(evidence, verdicts))
    with open(os.path.join(out, "verdicts.json"), "w", encoding="utf-8") as handle:
        json.dump({"verdicts": verdicts, "overall": overall(verdicts)}, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print("written  %s: report.md, verdicts.json" % out)
    return _print_verdicts(verdicts)
