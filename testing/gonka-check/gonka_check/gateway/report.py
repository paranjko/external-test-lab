"""report.md, checkpoints.csv and a chart for gcheck gateway-load stress."""

import csv
import io
import os
from xml.sax.saxutils import escape

CHECKPOINT_FIELDS = ("hosts", "nonce", "gateway_ms", "host_ms", "wall_ms", "heap_mb", "elapsed_s", "live", "sealed")
COLORS = ("#2a78d6", "#eb6834", "#1baf7a", "#8a4fd6", "#c23b5a")


def _num(value, digits=2):
    return ("%%.%df" % digits) % value if isinstance(value, float) else str(value)


def checkpoints_csv(runs):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(CHECKPOINT_FIELDS)
    for run in runs:
        for event in run["checkpoints"]:
            writer.writerow(["" if event.get(field) is None else _num(event[field], 3) for field in CHECKPOINT_FIELDS])
    return out.getvalue()


def chart(runs, field="gateway_ms", title="Gateway time per nonce", unit="ms"):
    """Line per group size: milliseconds per nonce over the checkpoints of the run."""
    series = [(run.get("label") or "G=%d" % run["hosts"],
               [(event["nonce"], event[field]) for event in run["checkpoints"]]) for run in runs]
    series = [(label, points) for label, points in series if points]
    W, H, ml, mr, mt, mb = 760, 380, 64, 24, 46, 54
    pw, ph = W - ml - mr, H - mt - mb
    top_x = max([x for _label, points in series for x, _y in points] or [1])
    top_y = max([y for _label, points in series for _x, y in points] or [1]) * 1.1 or 1

    def sx(x):
        return ml + x / top_x * pw

    def sy(y):
        return mt + (1 - y / top_y) * ph

    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" '
           'font-family="sans-serif" font-size="12">' % (W, H, W, H),
           '<rect width="%d" height="%d" fill="#ffffff"/>' % (W, H),
           '<text x="%d" y="20" font-size="14" font-weight="bold" fill="#111111">%s, %s</text>' % (
               ml, escape(title), escape(unit))]
    for i in range(5):
        value = top_y * i / 4
        out.append('<line x1="%d" x2="%d" y1="%.1f" y2="%.1f" stroke="#e3e6ea"/>' % (ml, W - mr, sy(value), sy(value)))
        out.append('<text x="%d" y="%.1f" text-anchor="end" fill="#555555">%.3g</text>'
                   % (ml - 6, sy(value) + 4, value))
    for i in range(5):
        value = top_x * i / 4
        out.append('<text x="%.1f" y="%d" text-anchor="middle" fill="#555555">%d</text>'
                   % (sx(value), H - mb + 18, value))
    out.append('<text x="%.0f" y="%d" text-anchor="middle" fill="#333333">nonce</text>' % (ml + pw / 2, H - 12))
    left = ml
    for i, (label, points) in enumerate(series):
        color = COLORS[i % len(COLORS)]
        path = " ".join("%.1f,%.1f" % (sx(x), sy(y)) for x, y in points)
        out.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="2"/>' % (path, color))
        out.append('<rect x="%d" y="28" width="12" height="12" fill="%s"/>'
                   '<text x="%d" y="38" fill="#333333">%s</text>' % (left, color, left + 16, escape(label)))
        left += 30 + 7 * len(label)
    out.append("</svg>\n")
    return "\n".join(out)


def _row(run):
    summary, points = run["summary"] or {}, run["checkpoints"]
    first, last = (points[0], points[-1]) if points else ({}, {})

    def get(source, key, digits=2):
        return _num(source[key], digits) if key in source else "–"

    diff_bytes = ("%.0f" % (summary["diff_history_mb"] * 1048576 / summary["diffs"])
                  if summary.get("diffs") else "–")
    return ["G=%d" % run["hosts"], get(summary, "nonces", 0), get(last, "live", 0), get(first, "gateway_ms"),
            get(last, "gateway_ms"), get(last, "host_ms"), get(summary, "loop_gateway_s", 1),
            get(summary, "loop_host_s", 1),
            get(summary, "finalize_s", 2), get(summary, "state_mb", 1), get(summary, "diff_history_mb", 1), diff_bytes,
            get(summary, "user_cpu_s", 1), get(summary, "max_rss_mb", 0), run["verdict"]["verdict"]]


def markdown(meta, runs, verdicts, overall):
    header = ("G", "nonces", "live records, last", "gateway ms/nonce, first", "gateway ms/nonce, last",
              "host ms/nonce, last",
              "gateway s", "host s", "finalize s", "state MB", "diff log MB", "diff B, proto", "CPU s", "peak RSS MB",
              "verdict")
    lines = ["# Gateway load in one process, %s" % meta["tag"], "",
             "Source `%s` at `%s`, run with %s on %s CPUs, %s." % (
                 meta["tag"], meta["commit"][:12], meta["runner"], meta.get("cpus", "?"), meta["started_at"][:10]),
             "",
             "The upstream gateway session drives G in-process hosts with the stub model, one request at a time. "
             "The seal clock is set to 30 days: a DevNet escrow ends before its records seal by the clock, and a "
             "run of hours must not seal them either; validated records still seal by nonce, as on DevNet. "
             "Gateway time is the wall time of a nonce minus the time spent inside the hosts. "
             "Memory and CPU are for the whole process, hosts included.", "",
             "## Checks", "", "| check | verdict | reason |", "|---|---|---|"]
    lines += ["| %s | %s | %s |" % (item["check"], item["verdict"], item["reason"].replace("|", "/"))
              for item in verdicts]
    lines += ["", "Overall: **%s**." % overall, "", "## Per group size", "",
              "| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(_row(run)) + " |" for run in runs]
    lines += ["", "First and last: the first and the last %d nonces. "
              "Diff B, proto: diff log size over the number of diffs, protobuf; on the wire the gateway sends "
              "JSON with base64, larger by a third and more." % meta["every"], "",
              "![gateway time per nonce](gateway.svg)", "", "![host time per nonce](host.svg)", "",
              "Every checkpoint is in `checkpoints.csv`; the raw output of each run is in `go-test-g<G>.log`.", ""]
    return "\n".join(lines)


def write(run_dir, meta, runs, verdicts, overall):
    files = {"report.md": markdown(meta, runs, verdicts, overall), "checkpoints.csv": checkpoints_csv(runs),
             "gateway.svg": chart(runs, "gateway_ms", "Gateway time per nonce"),
             "host.svg": chart(runs, "host_ms", "Host time per nonce")}
    for name, text in files.items():
        with open(os.path.join(run_dir, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    return sorted(files)


SAMPLE_FIELDS = ("groups", "t_s", "nonce", "cpu_s", "rss_mb", "hosts_mem_mb", "rx_mb", "tx_mb", "storage_mb")


def samples_csv(runs):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(SAMPLE_FIELDS)
    for run in runs:
        for item in run["samples"]:
            row = dict(item, groups=run["groups"])
            writer.writerow(["" if row.get(field) is None else _num(row[field], 3) for field in SAMPLE_FIELDS])
    return out.getvalue()


def stand_series(runs):
    """Per run: RSS and gateway CPU per nonce between samples, keyed by nonce for chart()."""
    out = []
    for run in runs:
        points, previous = [], None
        for item in run["samples"]:
            if item.get("nonce") is None:
                continue
            point = {"nonce": item["nonce"], "rss_mb": item.get("rss_mb") or 0.0}
            if previous and item["nonce"] > previous["nonce"] and item.get("cpu_s") is not None:
                point["cpu_ms"] = (item["cpu_s"] - previous["cpu_s"]) * 1000 / (item["nonce"] - previous["nonce"])
                points.append(point)
            previous = item
        out.append({"hosts": run["groups"], "label": run.get("label"), "checkpoints": points})
    return out


def _cell(value, digits=2):
    if value is None:
        return "–"
    return _num(float(value), digits) if isinstance(value, (int, float)) else str(value)


def stand_markdown(meta, runs, verdicts, overall):
    load, cost, final = [], [], []
    for run in runs:
        item = run["summary"]
        done = item.get("finalize") or {}
        size = "G=%d H=%d x%d" % (item["groups"], item["hosts"], item["concurrency"])
        load.append([size, str(item["requests"]), str(item["nonce"]), _cell(item["nonces_per_request"]),
                     _cell(item["nonces_per_s"]), _cell(item["p50_s"]), _cell(item["p95_s"]),
                     run["verdict"]["verdict"]])
        cost.append([size, _cell(item["cpu_ms_per_nonce"]), _cell(item["peak_rss_mb"], 0),
                     _cell(item.get("hosts_peak_mb"), 0), _cell(item["storage_mb"], 1),
                     _cell(item["tx_kb_per_nonce"]), _cell(item["rx_kb_per_nonce"])])
        final.append([size, _cell(done.get("nonce"), 0), _cell(done.get("seconds")),
                      _cell(done.get("signatures"), 0), _cell(done.get("quorum"), 0), _cell(done.get("host_stats"), 0),
                      _cell(done["bytes"] / 1000 if done.get("bytes") is not None else None, 1)])

    def table(header, rows):
        return ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)] + [
            "| " + " | ".join(row) + " |" for row in rows]

    lines = ["# Gateway load against a stub stand, %s" % meta["tag"], "",
             "Source `%s` at `%s`. The gateway runs as its own container against H stub hosts and the mock chain; "
             "escrow values are the DevNet ones, except the seal clock of 30 days, so that no record seals by the "
             "clock during a run, as on DevNet, where an escrow ends first. Each stand, G slots on H hosts with "
             "x requests in flight, runs until the escrow nonce reaches %d or the gateway stops routing at its cap. "
             "Network delay added to every stub host: %d ms. CPUs: gateway %s, stub hosts and chain %s. "
             "Stub hosts also gossip every request to their peers, which `devshardd` does not, so the hosts are "
             "slower than real ones." % (
                 meta["tag"], meta["commit"][:12], meta["nonces"], meta.get("delay_ms", 0),
                 meta.get("gateway_cpus") or "any", meta.get("host_cpus") or "any"), "",
             "## Checks", "", "| check | verdict | reason |", "|---|---|---|"]
    lines += ["| %s | %s | %s |" % (item["check"], item["verdict"], item["reason"].replace("|", "/"))
              for item in verdicts]
    lines += ["", "Overall: **%s**." % overall, "", "## Load", ""]
    lines += table(("stand", "requests", "nonce", "nonces/request", "nonces/s", "p50 s", "p95 s", "verdict"), load)
    lines += ["", "## Gateway cost", ""]
    lines += table(("stand", "CPU ms/nonce", "peak RSS MB", "stub hosts peak MB", "storage MB", "sent KB/nonce",
                    "received KB/nonce"), cost)
    lines += ["", "Sent and received: the gateway container's network traffic over the run. Storage: the gateway "
              "data directory at the end. Stub hosts: the memory of all stub host containers together.", "",
              "## Finalization", ""]
    lines += table(("stand", "nonce", "seconds", "signatures", "quorum", "host stats", "payload KB"), final)
    lines += ["", "The finalization reply is the settlement payload, saved as `g<G>-h<H>-c<x>/finalize.json`. "
              "Quorum is 2G/3 + 1 signatures.", "", "![gateway CPU per nonce](stand-cpu.svg)", "",
              "![gateway memory](stand-rss.svg)", "", "Every sample is in `samples.csv`.", ""]
    return "\n".join(lines)


def write_stand(run_dir, meta, runs, verdicts, overall):
    series = stand_series(runs)
    files = {"report.md": stand_markdown(meta, runs, verdicts, overall), "samples.csv": samples_csv(runs),
             "stand-cpu.svg": chart(series, "cpu_ms", "Gateway CPU per nonce"),
             "stand-rss.svg": chart(series, "rss_mb", "Gateway memory", "MB")}
    for name, text in files.items():
        with open(os.path.join(run_dir, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    return sorted(files)


TESTENV_FIELDS = ("groups", "phase", "t_s", "nonce", "cpu_pct", "cpu_s", "rss_mb", "mem_mb", "rx_mb", "tx_mb",
                  "write_mb", "storage_mb", "hosts_cpu_pct", "hosts_mem_mb", "host_last_min", "host_last_max",
                  "heartbeats", "abandoned", "no_height", "cap_lines", "dead_lines", "escrows")
HOST_FIELDS = ("groups", "phase", "t_s", "host", "cpu_pct", "mem_mb", "write_mb", "last_diff")
CONTAINER_FIELDS = ("groups", "phase", "t_s", "container", "cpu_pct", "mem_mb", "rx_mb", "tx_mb", "write_mb")


def _csv(fields, rows):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(fields)
    for row in rows:
        writer.writerow(["" if row.get(field) is None else _num(row[field], 3) for field in fields])
    return out.getvalue()


def testenv_samples_csv(runs):
    return _csv(TESTENV_FIELDS, [dict(item, groups=run["groups"]) for run in runs for item in run["samples"]])


def testenv_hosts_csv(runs):
    return _csv(HOST_FIELDS, [dict(row, groups=run["groups"], phase=item["phase"], t_s=item["t_s"])
                              for run in runs for item in run["samples"] for row in item.get("hosts", [])])


def testenv_cores_csv(runs):
    cpus = sorted({cpu for run in runs for item in run["samples"] for cpu in item.get("cores") or {}})
    fields = ("groups", "phase", "t_s", "load1", "mem_avail_mb") + tuple("cpu%d" % cpu for cpu in cpus)
    return _csv(fields, [dict({"cpu%d" % cpu: value for cpu, value in (item.get("cores") or {}).items()},
                              groups=run["groups"], phase=item["phase"], t_s=item["t_s"], load1=item.get("load1"),
                              mem_avail_mb=item.get("mem_avail_mb"))
                         for run in runs for item in run["samples"]])


def testenv_containers_csv(runs):
    return _csv(CONTAINER_FIELDS, [dict(row, groups=run["groups"], phase=item["phase"], t_s=item["t_s"], container=name)
                                   for run in runs for item in run["samples"]
                                   for name, row in sorted((item.get("others") or {}).items())])


def _since(event):
    return "–" if not event or event.get("after_s") is None else "+%s s" % _num(float(event["after_s"]), 1)


def rotation_row(size, rotation, final):
    events, result, beats = rotation["events"], rotation["result"], rotation["heartbeats"] or {}
    state = {"settled": "settled", "failed": "failed: %s" % result["detail"]}.get(result["state"], "none")
    if rotation["mode"] == "deactivate":
        state = "manual %s%s" % (_cell(final.get("code"), 0), ": %s" % result["detail"] if result["detail"] else "")
    if beats.get("continued") is None:
        moved = "–"
    else:
        moved = "%s: nonce %s to %s, last diff %s to %s" % (
            "yes" if beats["continued"] else "no", _cell(beats["nonce_from"], 0), _cell(beats["nonce_to"], 0),
            _cell(beats["host_last_from"], 0), _cell(beats["host_last_to"], 0))
    return [size, rotation["mode"], _since(events.get("nonce_high")), _since(events.get("replacement_created")),
            _since(events.get("deactivated")), state.replace("|", "/"), _since(result), _cell(result["nonce"], 0),
            "%s..%s" % (_cell(result["host_last_min"], 0), _cell(result["host_last_max"], 0)), moved]


def testenv_markdown(meta, runs, verdicts, overall):
    load, gateway, hosts, settle, box, rest, turns = [], [], [], [], [], [], []
    for run in runs:
        item = run["summary"]
        size, quiet, cost, done = "G=%d" % item["groups"], item["quiet"], item["gateway"], item["finalize"] or {}
        load.append([size, str(item["hosts"]), "%d/%d" % (item["warm_ok"], item["warm_sent"]), str(item["requests"]),
                     _cell(item["drive_nonce"], 0), _cell(item["nonces_per_s"]), str(item["unquarantines"]),
                     _cell(quiet.get("minutes"), 1), _cell(quiet.get("per_min"), 1), _cell(quiet.get("per_turn"), 1),
                     _cell(quiet.get("turns"), 0), _cell(quiet.get("abandoned"), 0), run["verdict"]["verdict"]])
        gateway.append([size, _cell(cost["cpu_mean_pct"], 1), _cell(cost["cpu_peak_pct"], 1),
                        _cell(cost["rss_peak_mb"], 0), _cell(cost["rx_mb"], 1), _cell(cost["tx_mb"], 1),
                        _cell(cost["write_mb"], 1), _cell(cost["storage_mb"], 1)])
        hosts += [[size, str(host["host"]), str(host["slots"]), _cell(host["cpu_mean_pct"], 1),
                   _cell(host["mem_peak_mb"], 0), _cell(host["last_diff"], 0)] for host in item["per_host"]]
        busy = item.get("machine") or {}
        pair = [" / ".join((_cell(busy.get(name + "_mean"), 1), _cell(busy.get(name + "_peak"), 1)))
                for name in ("gateway_busy", "host_busy", "all_busy")]
        box.append([size] + pair + [_cell(busy.get("core_peak"), 1), _cell(busy.get("load_peak"), 1),
                    _cell(busy.get("mem_avail_min_mb"), 0)])
        rest += [[size, other["container"], _cell(other["cpu_mean_pct"], 1), _cell(other["mem_peak_mb"], 0)]
                 for other in item.get("others") or []]
        settle.append([size, _cell(item["nonce"], 0), "%s..%s" % (_cell(item["host_last_min"], 0),
                                                                  _cell(item["host_last_max"], 0)),
                       str(item["active_cap"]), _cell(item["cap_lines"], 0), _cell(item["dead_lines"], 0),
                       _cell(done.get("code"), 0), _cell(done.get("seconds")), _cell(done.get("weight"), 0),
                       _cell(done.get("quorum"), 0), (done.get("error") or "").replace("|", "/")])
        if item.get("rotation") and item["mode"] == "drive":
            turns.append(rotation_row(size, item["rotation"], done))

    def table(header, rows):
        return ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)] + [
            "| " + " | ".join(row) + " |" for row in rows]

    idle = "then sends nothing for %g minutes" % meta["quiet_minutes"]
    after = {"settle": "%s while the gateway replaces escrow 1 and settles it itself" % idle,
             "deactivate": "%s while the gateway replaces escrow 1 and only deactivates it, and settles escrow 1 "
                           "through the gateway admin API" % idle}.get(meta.get("rotation"), "%s, and finalizes" % idle)
    if not meta["quiet_minutes"]:
        after = "and finalizes at once"
    run = {"drive": "drives one escrow with %d chats in flight until the gateway stops routing at nonce %d, %s" % (
               meta["concurrency"], meta["routing_stop"], after),
           "quiet-only": "sends nothing for %g minutes, and finalizes" % meta["quiet_minutes"]}.get(
        meta.get("run"), "and finalizes")
    lines = ["# Gateway load against real devshardd hosts, %s" % meta["tag"], "",
             "Source `%s` at `%s`. The upstream `devshard/testenv` runs the real `devshardd` hosts under `versiond`, "
             "the `versiond` router and the `devshardctl` gateway; the chain, dapi and ML node are its mocks. "
             "max_nonce is %d, so hosts take diffs with completion-type txs up to max_nonce − (G+1) and heartbeat "
             "diffs up to max_nonce. Each stack warms up with 20 chats so heartbeats start, %s. "
             "CPUs: gateway %s, hosts, router and mocks %s." % (
                 meta["tag"], meta["commit"][:12], meta["max_nonce"], run, meta.get("gateway_cpus") or "any",
                 meta.get("host_cpus") or "any"), "",
             "## Checks", "", "| check | verdict | reason |", "|---|---|---|"]
    lines += ["| %s | %s | %s |" % (item["check"], item["verdict"], item["reason"].replace("|", "/"))
              for item in verdicts]
    lines += ["", "Overall: **%s**." % overall, "", "## Load", ""]
    lines += table(("G", "hosts", "warm-up", "drive chats", "drive nonce", "nonces/s", "unquarantines", "quiet min",
                    "quiet nonces/min", "nonces/turn", "turns", "abandoned", "verdict"), load)
    lines += ["", "A heartbeat turn costs G diffs plus 1 to 4 ack diffs.", "", "## Gateway", ""]
    lines += table(("G", "CPU mean %", "CPU peak %", "peak RSS MB", "received MB", "sent MB", "written MB",
                    "storage MB"), gateway)
    lines += ["", "## Hosts", ""]
    lines += table(("G", "host", "slots", "CPU mean %", "peak memory MB", "last diff"), hosts)
    lines += ["", "## Machine", ""]
    lines += table(("G", "gateway CPUs busy mean / peak %", "host CPUs busy mean / peak %", "all CPUs mean / peak %",
                    "busiest CPU peak %", "load peak", "min available MB"), box)
    lines += ["", "Busy shares come from /proc/stat between samples, averaged over the CPUs of each list; every CPU "
              "of the machine when no list was given. Per CPU in `cores.csv`.", "", "## Other containers", ""]
    lines += table(("G", "container", "CPU mean %", "peak memory MB"), rest)
    lines += ["", "## Settlement", ""]
    lines += table(("G", "gateway nonce", "hosts' last diff", "active cap", "refusals at the cap", "dead host lines",
                    "finalize", "seconds", "signature weight", "quorum", "error"), settle)
    lines += ["", "Gateway nonce: the gateway's own count before finalizing. Refusals at the cap and dead host lines "
              "are gateway log lines. The finalization reply is in `g<G>/finalize.json`; quorum is 2G/3 + 1 slots. "
              "Every sample is in `samples.csv`, every host sample in `hosts.csv`, the router and mocks in "
              "`containers.csv`.", ""]
    if turns:
        lines += ["## Rotation", ""]
        lines += table(("G", "mode", "nonce high", "replacement", "deactivated", "settlement", "at", "gateway nonce",
                        "hosts' last diff", "heartbeats after deactivation"), turns)
        lines += ["", "Times are seconds after the gateway stopped routing, from its log lines about escrow 1; the "
                  "gateway nonce and the hosts' last diff are those of the first sample after the line. In deactivate "
                  "mode the settlement is `POST /v1/admin/devshards/1/settle` after the quiet minutes, its reply in "
                  "`g<G>/settle.json`. Every first line is in `summary.json`.", ""]
    return "\n".join(lines)


def write_testenv(run_dir, meta, runs, verdicts, overall):
    files = {"report.md": testenv_markdown(meta, runs, verdicts, overall), "samples.csv": testenv_samples_csv(runs),
             "hosts.csv": testenv_hosts_csv(runs), "cores.csv": testenv_cores_csv(runs),
             "containers.csv": testenv_containers_csv(runs)}
    for name, text in files.items():
        with open(os.path.join(run_dir, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    return sorted(files)
