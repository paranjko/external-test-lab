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
