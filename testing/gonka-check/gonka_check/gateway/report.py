"""report.md, checkpoints.csv and a chart for gcheck gateway-load stress."""

import csv
import io
import os
from xml.sax.saxutils import escape

CHECKPOINT_FIELDS = ("hosts", "nonce", "gateway_ms", "host_ms", "wall_ms", "heap_mb", "elapsed_s")
COLORS = ("#2a78d6", "#eb6834", "#1baf7a", "#8a4fd6", "#c23b5a")


def _num(value, digits=2):
    return ("%%.%df" % digits) % value if isinstance(value, float) else str(value)


def checkpoints_csv(runs):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(CHECKPOINT_FIELDS)
    for run in runs:
        for event in run["checkpoints"]:
            writer.writerow([_num(event[field], 3) for field in CHECKPOINT_FIELDS])
    return out.getvalue()


def chart(runs, field="gateway_ms", title="Gateway time per nonce"):
    """Line per group size: milliseconds per nonce over the checkpoints of the run."""
    series = [(run["hosts"], [(event["nonce"], event[field]) for event in run["checkpoints"]]) for run in runs]
    series = [(hosts, points) for hosts, points in series if points]
    W, H, ml, mr, mt, mb = 760, 380, 64, 24, 46, 54
    pw, ph = W - ml - mr, H - mt - mb
    top_x = max([x for _hosts, points in series for x, _y in points] or [1])
    top_y = max([y for _hosts, points in series for _x, y in points] or [1]) * 1.1 or 1

    def sx(x):
        return ml + x / top_x * pw

    def sy(y):
        return mt + (1 - y / top_y) * ph

    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" '
           'font-family="sans-serif" font-size="12">' % (W, H, W, H),
           '<rect width="%d" height="%d" fill="#ffffff"/>' % (W, H),
           '<text x="%d" y="20" font-size="14" font-weight="bold" fill="#111111">%s, ms</text>' % (ml, escape(title))]
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
    for i, (hosts, points) in enumerate(series):
        color = COLORS[i % len(COLORS)]
        path = " ".join("%.1f,%.1f" % (sx(x), sy(y)) for x, y in points)
        out.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="2"/>' % (path, color))
        out.append('<rect x="%d" y="28" width="12" height="12" fill="%s"/>'
                   '<text x="%d" y="38" fill="#333333">G=%d</text>' % (ml + 70 * i, color, ml + 16 + 70 * i, hosts))
    out.append("</svg>\n")
    return "\n".join(out)


def _row(run):
    summary, points = run["summary"] or {}, run["checkpoints"]
    first, last = (points[0], points[-1]) if points else ({}, {})

    def get(source, key, digits=2):
        return _num(source[key], digits) if key in source else "–"

    diff_bytes = ("%.0f" % (summary["diff_history_mb"] * 1048576 / summary["diffs"])
                  if summary.get("diffs") else "–")
    return ["G=%d" % run["hosts"], get(summary, "nonces", 0), get(first, "gateway_ms"), get(last, "gateway_ms"),
            get(last, "host_ms"), get(summary, "loop_gateway_s", 1), get(summary, "loop_host_s", 1),
            get(summary, "finalize_s", 2), get(summary, "state_mb", 1), get(summary, "diff_history_mb", 1), diff_bytes,
            get(summary, "user_cpu_s", 1), get(summary, "max_rss_mb", 0), run["verdict"]["verdict"]]


def markdown(meta, runs, verdicts, overall):
    header = ("G", "nonces", "gateway ms/nonce, first", "gateway ms/nonce, last", "host ms/nonce, last",
              "gateway s", "host s", "finalize s", "state MB", "diff log MB", "diff B, proto", "CPU s", "peak RSS MB",
              "verdict")
    lines = ["# Gateway load in one process, %s" % meta["tag"], "",
             "Source `%s` at `%s`, run with %s on %s CPUs, %s." % (
                 meta["tag"], meta["commit"][:12], meta["runner"], meta.get("cpus", "?"), meta["started_at"][:10]),
             "",
             "The upstream gateway session drives G in-process hosts with the stub model, one request at a time. "
             "Nothing seals during the run, as on DevNet, where an escrow lives under the 92-minute seal horizon. "
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
