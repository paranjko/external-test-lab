#!/usr/bin/env python3
"""Replay chosen dataset rows one at a time through live gateways and record every answer as raw SSE.

Shows answers of one generated token with no text: the client view (content, tool_calls, finish_reason,
usage and whether usage came in the finish event) and, with --gw-ssh, the gateway view (stage=empty_stream
with output chunks, empty_stream streaks and quarantines) for the same window.
Usage: remote-one-token.py --dataset D --out DIR --gateway v6=ENV [--gateway v42=ENV] [--rows 247,234]
       [--repeats 50] [--temperature T] [--pause 0.5] [--gw-ssh gdc-node0 --container v6=NAME ...]
ENV holds GONKA_BASE and GONKA_API_KEY; rows are 0-based dataset lines (sample_index of wrap-load).
"""
import argparse, collections, datetime, gzip, json, pathlib, re, shutil, subprocess, time, urllib.error, urllib.request


def env_file(path):
    env = {}
    for line in pathlib.Path(path).expanduser().read_text().splitlines():
        line = line.strip().removeprefix("export ")
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("'\"")
    return env


def scan(raw):
    """Client view of one SSE answer."""
    text = tools = 0
    finish, tokens, usage_with_finish, events = "", None, False, 0
    for line in raw.splitlines():
        if not line.startswith("data:") or line[5:].strip() in ("", "[DONE]"):
            continue
        try:
            ev = json.loads(line[5:])
        except ValueError:
            continue
        events += 1
        usage = ev.get("usage") or {}
        for ch in ev.get("choices") or []:
            d = ch.get("delta") or ch.get("message") or {}
            text += len(d.get("content") or "") + len(d.get("reasoning_content") or "")
            tools += len(d.get("tool_calls") or [])
            if ch.get("finish_reason"):
                finish = ch["finish_reason"]
                usage_with_finish = bool(usage)
        if usage.get("completion_tokens") is not None:
            tokens = usage["completion_tokens"]
    return {"events": events, "text_chars": text, "tool_calls": tools, "finish": finish or "-",
            "completion_tokens": tokens, "usage_with_finish": usage_with_finish}


def send(base, key, body, rid, timeout):
    req = urllib.request.Request(base.rstrip("/") + "/v1/chat/completions", json.dumps(body).encode(), {
        "Authorization": "Bearer " + key, "Content-Type": "application/json", "X-Request-Id": rid})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace"), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8", "replace"), time.time() - t0
    except Exception as e:  # timeout, reset
        return 0, {}, f"{type(e).__name__}: {e}", time.time() - t0


def gateway_view(path):
    c = collections.Counter()
    for line in gzip.open(path, "rt", errors="replace"):
        if "stage=empty_stream " in line:
            chunks = int((re.search(r"output_chunks=(\d+)", line) or [0, 0])[1])
            tokens = int((re.search(r"usage_tokens=(\d+)", line) or [0, 0])[1])
            c["empty_stream one_token" if chunks > 0 and tokens <= 2 else "empty_stream no_chunks" if chunks == 0 else "empty_stream other"] += 1
        for name in ("participant_limit_empty_stream_streak", "participant_limit_empty_stream_quarantine"):
            if name in line:
                c[name] += 1
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--gateway", action="append", required=True, help="name=env file")
    ap.add_argument("--rows", default="247,234")
    ap.add_argument("--repeats", type=int, default=50)
    ap.add_argument("--temperature", type=float)
    ap.add_argument("--pause", type=float, default=0.5)
    ap.add_argument("--timeout", type=float, default=180)
    ap.add_argument("--gw-ssh")
    ap.add_argument("--container", action="append", default=[], help="name=container on --gw-ssh")
    a = ap.parse_args()

    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=False)
    rows = [json.loads(l) for l in open(a.dataset)]
    run = datetime.datetime.now(datetime.timezone.utc).strftime("%m%d%H%M%S")
    start = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    gateways = [(g.split("=", 1)[0], env_file(g.split("=", 1)[1])) for g in a.gateway]
    (out / "conf.json").write_text(json.dumps({"run": run, "start": start, "rows": a.rows, "repeats": a.repeats,
        "temperature": a.temperature, "gateways": {n: e.get("GONKA_BASE") for n, e in gateways}}, indent=1))
    results = out / "results.jsonl"
    for n in range(1, a.repeats + 1):
        for name, env in gateways:
            for row in map(int, a.rows.split(",")):
                body = {k: v for k, v in rows[row].items() if k != "response"}
                body["stream"] = True
                if a.temperature is not None:
                    body["temperature"] = a.temperature
                body["messages"] = [dict(m) for m in body["messages"]]
                last = max(i for i, m in enumerate(body["messages"]) if m["role"] == "user")
                body["messages"][last]["content"] += f"\n[R:{run}:{name}:{row}:{n:04d}]"
                rid = f"repro-{run}-{name}-{row}-{n:04d}"
                status, headers, raw, secs = send(env["GONKA_BASE"], env["GONKA_API_KEY"], body, rid, a.timeout)
                d = out / name / f"row{row}"
                d.mkdir(parents=True, exist_ok=True)
                (d / f"{n:04d}.sse").write_text(raw)
                rec = {"time": datetime.datetime.now(datetime.timezone.utc).isoformat(), "gateway": name, "row": row,
                       "n": n, "request_id": rid, "status": status, "seconds": round(secs, 2),
                       "headers": {k: v for k, v in headers.items() if k.lower().startswith("x-")}, **scan(raw)}
                with results.open("a") as f:
                    f.write(json.dumps(rec) + "\n")
                print(f'{rec["time"][11:19]} {name} row{row} #{n} {status} text={rec["text_chars"]} '
                      f'tokens={rec["completion_tokens"]} finish={rec["finish"]} {secs:.1f}s', flush=True)
                time.sleep(a.pause)
    time.sleep(10 if a.container else 0)  # the gateway logs the race result after the answer
    end = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    recs = [json.loads(l) for l in results.open()]
    lines = ["gateway\trow\tsends\thttp200\tempty_text\tone_token_empty\tfinish_reasons\tusage_with_finish"]
    groups = collections.defaultdict(list)
    for rec in recs:
        groups[(rec["gateway"], rec["row"])].append(rec)
    for (g, r), group in sorted(groups.items()):
        ok = [x for x in group if x["status"] == 200]
        empty = [x for x in ok if x["text_chars"] == 0 and x["tool_calls"] == 0]
        one = [x for x in empty if x["completion_tokens"] == 1]
        fins = collections.Counter(x["finish"] for x in ok)
        lines.append(f"{g}\t{r}\t{len(group)}\t{len(ok)}\t{len(empty)}\t{len(one)}\t"
                     f"{' '.join(f'{k}:{v}' for k, v in fins.items())}\t{sum(x['usage_with_finish'] for x in ok)}")
    for spec in a.container:
        name, container = spec.split("=", 1)
        log = out / f"gateway-{name}.log.gz"
        with gzip.open(log, "wb") as f, subprocess.Popen(
                ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", a.gw_ssh,
                 f"docker logs --since {start} --until {end} {container}"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL) as p:
            shutil.copyfileobj(p.stdout, f)
        lines.append(f"# gateway {name} {start}..{end}: " + " ".join(f"{k}={v}" for k, v in sorted(gateway_view(log).items())))
    (out / "summary.tsv").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
