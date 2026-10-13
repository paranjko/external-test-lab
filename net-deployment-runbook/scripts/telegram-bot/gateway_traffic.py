#!/usr/bin/env python3
"""Read native gateway request counters, never add consumer attempts again."""
import json
import math
import re
import time
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


def unknown(model):
    return {"scope": "native_gateway_requests_including_bot_and_direct_clients", "model": model,
            "state": "UNVERIFIED", "reason": "native_metrics_unavailable", "backends": []}


def initialize(db):
    db.execute("CREATE TABLE IF NOT EXISTS gateway_traffic_snapshots ("
               "id INTEGER PRIMARY KEY AUTOINCREMENT, model TEXT NOT NULL, "
               "started_at REAL NOT NULL, payload TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS gateway_traffic_clock (singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL)")
    db.execute("INSERT OR IGNORE INTO gateway_traffic_clock(singleton,revision) VALUES (1,0)")
    db.execute("CREATE TABLE IF NOT EXISTS gateway_traffic_sources ("
               "model TEXT NOT NULL, backend TEXT NOT NULL, observed_at REAL NOT NULL, "
               "counters TEXT NOT NULL, PRIMARY KEY(model,backend))")
    db.commit()


def begin(db, model, timestamp):
    receipt = db.execute("INSERT INTO gateway_traffic_snapshots(model,started_at) VALUES (?,?)", (model, timestamp)).lastrowid
    db.execute("UPDATE gateway_traffic_clock SET revision=revision+1 WHERE singleton=1")
    db.commit()
    return receipt


def finish(db, receipt, snapshot):
    # Completion never reorders an older request or renews source timestamps.
    if not db.in_transaction:
        db.execute("BEGIN IMMEDIATE")
    snapshot = json.loads(json.dumps(snapshot))
    for backend in snapshot.get("backends", []):
        if backend.get("state") != "FRESH":
            continue
        source = number(backend["observed_at"])
        counters = json.dumps(backend["counters"], sort_keys=True, separators=(",", ":"))
        prior = db.execute("SELECT observed_at,counters FROM gateway_traffic_sources WHERE model=? AND backend=?",
                           (snapshot["model"], backend["backend"])).fetchone()
        if prior is not None and (source < prior[0] or (source == prior[0] and counters != prior[1])):
            backend.update(state="UNVERIFIED", reason="native_source_regressed_or_conflicting", counters=[],
                           requests_per_second=None, rate_reason="source_order_unverified")
    if snapshot.get("backends"):
        count = sum(backend["state"] == "FRESH" for backend in snapshot["backends"])
        snapshot["state"] = "CURRENT" if count == 2 else "PARTIAL" if count else "UNVERIFIED"
    db.execute("UPDATE gateway_traffic_snapshots SET payload=? WHERE id=? AND model=? AND payload IS NULL",
               (json.dumps(snapshot, separators=(",", ":")), receipt, snapshot["model"]))
    updated = db.execute("SELECT changes()").fetchone()[0]
    if updated:
        for backend in snapshot.get("backends", []):
            if backend.get("state") == "FRESH":
                db.execute("INSERT INTO gateway_traffic_sources(model,backend,observed_at,counters) VALUES (?,?,?,?) "
                           "ON CONFLICT(model,backend) DO UPDATE SET observed_at=excluded.observed_at,counters=excluded.counters",
                           (snapshot["model"], backend["backend"], backend["observed_at"],
                            json.dumps(backend["counters"], sort_keys=True, separators=(",", ":"))))
        db.execute("UPDATE gateway_traffic_clock SET revision=revision+1 WHERE singleton=1")
    db.commit()
    return bool(updated)


def revision(db):
    return db.execute("SELECT revision FROM gateway_traffic_clock WHERE singleton=1").fetchone()[0]


def latest(db, model, timestamp):
    row = db.execute("SELECT id,payload FROM gateway_traffic_snapshots WHERE model=? AND payload IS NOT NULL ORDER BY id DESC LIMIT 1",
                     (model,)).fetchone()
    if row is None:
        return unknown(model)
    try:
        return at_time(json.loads(row[1]), model, timestamp, row[0])
    except (ValueError, TypeError, KeyError, IndexError, AttributeError):
        return unknown(model)


def at_time(snapshot, model, timestamp, observation_id):
    if (snapshot["model"] != model or snapshot["scope"] != "native_gateway_requests_including_bot_and_direct_clients"
            or not isinstance(snapshot["backends"], list) or len(snapshot["backends"]) > 2):
        raise ValueError("invalid stored traffic snapshot")
    snapshot["observation_id"] = observation_id
    for backend in snapshot["backends"]:
        observed, expires = backend["observed_at"], backend["expires_at"]
        if backend["model"] != model or backend["backend"] not in {"A", "B"}:
            raise ValueError("invalid stored traffic identity")
        if observed is not None and (number(observed) != observed or expires != observed + 30):
            raise ValueError("invalid stored source expiry")
        if observed is None or expires is None or not 0 < observed <= timestamp <= expires:
            backend.update(state="UNVERIFIED", reason="native_metrics_missing_or_stale", counters=[],
                           requests_per_second=None, rate_reason="source_stale")
    count = sum(backend["state"] == "FRESH" for backend in snapshot["backends"])
    snapshot["state"] = "CURRENT" if count == 2 else "PARTIAL" if count else "UNVERIFIED"
    return snapshot


def vector(payload):
    if (not isinstance(payload, dict) or payload.get("status") != "success"
            or not isinstance(payload.get("data"), dict) or payload["data"].get("resultType") != "vector"
            or not isinstance(payload["data"].get("result"), list)):
        raise ValueError("invalid metrics response")
    return payload["data"]["result"]


def number(value):
    if type(value) is bool:
        raise ValueError("boolean metric")
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise ValueError("invalid metric number")
    return result


def parse_snapshot(counters, freshness, model, timestamp, previous=None):
    """A query evaluation timestamp is not the underlying scrape timestamp."""
    series = {"A": {}, "B": {}}
    sources = {}
    for row in vector(freshness):
        labels = row["metric"]
        if set(labels) != {"gateway", "model"} or labels["model"] != model or labels["gateway"] not in series:
            raise ValueError("unexpected source labels")
        gateway = labels["gateway"]
        if gateway in sources:
            raise ValueError("duplicate source")
        sources[gateway] = number(row["value"][1])
    for row in vector(counters):
        labels = row["metric"]
        if (not {"gateway", "model", "outcome"} <= set(labels)
                or not set(labels) <= {"gateway", "model", "outcome", "reason"}
                or labels["gateway"] not in series or labels["model"] != model):
            raise ValueError("unexpected counter labels")
        outcome, reason = labels["outcome"], labels.get("reason", "none")
        if not all(isinstance(value, str) and re.fullmatch(r"[a-z0-9_]{1,128}", value) for value in (outcome, reason)):
            raise ValueError("invalid counter dimension")
        key = (outcome, reason)
        target = series[labels["gateway"]]
        if key in target:
            raise ValueError("duplicate counter")
        target[key] = number(row["value"][1])
    backends = []
    for gateway, values in series.items():
        source = sources.get(gateway)
        prior_source = next((old.get("observed_at") for old in (previous or {}).get("backends", [])
                             if old.get("backend") == gateway and old.get("model") == model), None)
        regressed = source is not None and prior_source is not None and source < prior_source
        fresh = source is not None and 0 < source <= timestamp <= source + 30 and bool(values)
        fresh = fresh and not regressed
        item = {"backend": gateway, "model": model, "state": "FRESH" if fresh else "UNVERIFIED",
                "reason": "native_metrics_current" if fresh else "native_source_regressed" if regressed else "native_metrics_missing_or_stale",
                "observed_at": source, "expires_at": source + 30 if source is not None else None,
                "counters": [{"outcome": key[0], "reason": key[1], "value": value}
                             for key, value in sorted(values.items())] if fresh else [],
                "tokens": None, "tokens_reason": "native_token_counters_not_available",
                "requests_per_second": None, "rate_reason": "baseline_unavailable"}
        prior = next((old for old in (previous or {}).get("backends", [])
                      if old.get("backend") == gateway and old.get("model") == model and old.get("state") == "FRESH"), None)
        if fresh and prior is not None and prior.get("observed_at") is not None and source > prior["observed_at"]:
            old_values = {(entry["outcome"], entry["reason"]): entry["value"] for entry in prior["counters"]}
            if set(old_values) != set(values):
                item["rate_reason"] = "counter_series_changed"
            elif any(values[key] < old_values[key] for key in values):
                item["rate_reason"] = "counter_reset"
            else:
                item["requests_per_second"] = sum(values[key] - old_values[key] for key in values) / (source - prior["observed_at"])
                item["rate_reason"] = "observed_counter_delta"
        backends.append(item)
    count = sum(item["state"] == "FRESH" for item in backends)
    return {"scope": "native_gateway_requests_including_bot_and_direct_clients", "model": model,
            "state": "CURRENT" if count == 2 else "PARTIAL" if count else "UNVERIFIED",
            "reason": "native_counters_not_telegram_delivery", "backends": backends}


def collect(endpoint, model, previous=None, opener=urlopen, clock=time.time, monotonic=time.monotonic):
    """Two bounded read-only queries, unknown telemetry never means outage."""
    try:
        url = urlsplit(endpoint)
        if (url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password
                or url.query or url.fragment or (url.scheme == "http" and url.hostname not in {"localhost", "127.0.0.1", "::1"})):
            raise ValueError("invalid metrics endpoint")
        if not isinstance(model, str) or not model or len(model) > 256:
            raise ValueError("invalid model")
        selector = "devshard_gateway_requests_total{model=" + json.dumps(model) + ',gateway=~"A|B"}'
        queries = ("sum by (gateway,model,outcome,reason) (" + selector + ")",
                   "min by (gateway,model) (timestamp(" + selector + "))")
        deadline = monotonic() + 6
        evaluation = number(clock())
        payloads = []
        for query in queries:
            remaining = deadline - monotonic()
            if remaining <= 0:
                raise TimeoutError("metrics deadline elapsed")
            request = Request(endpoint + "?" + urlencode({"query": query, "time": format(evaluation, ".15g")}), headers={"Accept": "application/json"})
            with opener(request, timeout=min(3, remaining)) as response:
                result = json.load(response)
                for row in vector(result):
                    if abs(number(row["value"][0]) - evaluation) > 0.001:
                        raise ValueError("metrics evaluation time mismatch")
                payloads.append(result)
            if monotonic() >= deadline:
                raise TimeoutError("metrics deadline elapsed")
        if any(number(row["value"][1]) > evaluation for row in vector(payloads[1])):
            raise ValueError("source timestamp exceeds evaluation time")
        return parse_snapshot(*payloads, model, clock(), previous)
    except (ValueError, TypeError, KeyError, IndexError, AttributeError, OSError, OverflowError):
        return unknown(model)
