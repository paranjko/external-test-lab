#!/usr/bin/env python3
"""One row per step of remote-ladder.sh, with the stop verdict against the previous good step.

Usage: remote-ladder-table.py <ladder output directory> [--errors]
Stop rules: errors above 2 %, p95 above twice the previous step, or throughput up by less than 5 %.
"""
import collections, json, pathlib, re, sys

ERROR_LIMIT, P95_FACTOR, RPS_GAIN = 0.02, 2.0, 1.05


def kind(r):
    if r["status"]:
        return str(r["status"])
    e = r.get("error", "")
    return "timeout" if re.search(r"Timeout|deadline exceeded", e) else "noresp"


def step(d):
    summary = json.loads((d / "summary.json").read_text())
    rows = [json.loads(l) for l in (d / "requests.jsonl").open()]
    sent = [r for r in rows if r["outcome"] != "dropped_by_generator"]
    ok = [r for r in sent if r["outcome"] != "error"]
    failed = [r for r in sent if r["outcome"] == "error"]
    lat = sorted(r["duration"] / 1e9 for r in sent if r["duration"] > 0)
    q = lambda p: lat[int((len(lat) - 1) * p)] if lat else 0.0
    seconds = summary["duration"] / 1e9 or 1
    return {
        "workers": int(d.name[1:]),
        "start": summary["started_at"][:19] + "Z",
        "requests": len(rows),
        "ok": len(ok),
        "rps": len(ok) / seconds,
        "p50": q(.5), "p95": q(.95), "p99": q(.99),
        "err": 1 - len(ok) / len(rows) if rows else 1.0,
        "codes": collections.Counter(kind(r) for r in failed)
                 + collections.Counter({"drop": len(rows) - len(sent)} if len(rows) > len(sent) else {}),
        "messages": collections.Counter(f'{kind(r)} {r.get("error", "")[:90]}' for r in failed),
    }


def main():
    root = pathlib.Path(sys.argv[1])
    steps = [step(d) for d in sorted(root.glob("w[0-9][0-9][0-9]")) if (d / "summary.json").exists()]
    if "--errors" in sys.argv:
        for s in steps:
            for m, n in s["messages"].most_common(5):
                print(f'w{s["workers"]}\t{n}\t{m}')
        return
    print("workers\tstart_utc\trequests\tok\trps\tp50_s\tp95_s\tp99_s\terrors_pct\terror_codes\tverdict")
    prev = None
    for s in steps:
        if s["err"] > ERROR_LIMIT:
            verdict = "stop:errors"
        elif prev and s["p95"] > P95_FACTOR * prev["p95"]:
            verdict = "stop:p95x2"
        elif prev and s["rps"] < RPS_GAIN * prev["rps"]:
            verdict = "stop:rps_flat"
        else:
            verdict = "ok"
        codes = " ".join(f"{k}:{v}" for k, v in sorted(s["codes"].items())) or "-"
        print(f'{s["workers"]}\t{s["start"]}\t{s["requests"]}\t{s["ok"]}\t{s["rps"]:.2f}\t{s["p50"]:.1f}\t{s["p95"]:.1f}'
              f'\t{s["p99"]:.1f}\t{100 * s["err"]:.2f}\t{codes}\t{verdict}')
        if verdict == "ok":
            prev = s


if __name__ == "__main__":
    main()
