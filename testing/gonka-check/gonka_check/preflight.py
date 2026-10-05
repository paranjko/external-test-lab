"""GET-only readiness: chain, epoch fence, gateway status, model, health receipt."""

import datetime
import re
import time

from .chain import BLOCKING_CONFIRMATION_PHASES, ChainError, epoch_offset, send_window
from .target import gateway_url


ALLOWED_CONFIRMATION = {"NORMAL_OPERATION", "CONFIRMATION_POC_INACTIVE", "CONFIRMATION_POC_COMPLETED"}
ADMISSION_ID = re.compile(r"^[a-f0-9]{32}$")
SAFE_GENERATION = re.compile(r"^sha256:[a-f0-9]{64}$")
HEIGHT_FIELDS = ("arrival_height", "permit_height", "dispatch_height", "response_height")
CLOCK_SKEW_S = 5


def _first(*values):
    # jq `a // b` semantics: the first value that is neither null nor false.
    for value in values:
        if value is not None and value is not False:
            return value
    return None


def _active_unblocked(devshards):
    for shard in devshards:
        if not isinstance(shard, dict) or shard.get("active") is not True:
            continue
        runtime = shard.get("runtime") if isinstance(shard.get("runtime"), dict) else {}
        if _first(runtime.get("phase"), shard.get("phase"), "") != "active":
            continue
        if _first(runtime.get("requests_blocked"), shard.get("requests_blocked"), False) is True:
            continue
        if _first(runtime.get("chain_phase"), shard.get("chain_phase"), "Inference") != "Inference":
            continue
        return True
    return False


def _positive_capacity(capacity):
    if not isinstance(capacity, dict):
        return False
    weight = _first(capacity.get("total_weight"), capacity.get("effective_weight"))
    if weight is None:
        models = capacity.get("models")
        if isinstance(models, dict):
            weights = [_first(m.get("current_weight"), m.get("total_weight"))
                       for m in models.values() if isinstance(m, dict)]
            weights = [w for w in weights if w is not None]
            weight = sum(float(w) for w in weights) if weights else None
    try:
        return float(weight or 0) > 0
    except (TypeError, ValueError):
        return False


def _single_session_blocker(doc):
    escrow = doc.get("escrow_id")
    if not isinstance(escrow, str) or not escrow:
        return "runtime_not_routable"
    if doc.get("phase") != "active":
        return "phase=%s" % doc.get("phase")
    if doc.get("requests_blocked") is not False:
        return "requests_blocked (%s)" % (doc.get("block_reason") or "no reason")
    if doc.get("chain_phase") != "Inference":
        return "chain_phase=%s" % doc.get("chain_phase")
    seed = doc.get("height_seed")
    if seed is not None and not (isinstance(seed, dict) and seed.get("state") == "ok"):
        state = seed.get("state") if isinstance(seed, dict) else seed
        return "height_seed=%s" % state
    return None


def status_blocker(doc):
    """Port of gateway-status-routable.sh; None means routable."""
    if not isinstance(doc, dict):
        return "status_invalid"
    devshards = doc.get("devshards") if isinstance(doc.get("devshards"), list) else []
    phases = [doc.get("confirmation_poc_phase")]
    phases += [shard.get("confirmation_poc_phase") for shard in devshards if isinstance(shard, dict)]
    for phase in phases:
        if isinstance(phase, str) and phase and phase not in ALLOWED_CONFIRMATION:
            return "confirmation_poc_phase=%s" % phase
    if doc.get("routable") is True and (not devshards or _active_unblocked(devshards)):
        return None
    if _positive_capacity(doc.get("capacity")) and _active_unblocked(devshards):
        return None
    return _single_session_blocker(doc)


def _parse_utc(text):
    if not isinstance(text, str):
        return None
    text = re.sub(r"\.[0-9]+Z$", "Z", text).replace("Z", "+00:00")
    try:
        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def health_blocker(doc, max_age_s, now=None):
    """Port of the wait-public-traffic-readiness.sh receipt rule; None means fresh READY."""
    if not isinstance(doc, dict):
        return "health_invalid"
    if doc.get("state") != "READY" or doc.get("readiness") != "TRAFFIC_READY":
        return "health %s/%s (%s)" % (doc.get("state"), doc.get("readiness"), doc.get("reason") or "no reason")
    if doc.get("admission") != "dispatched_once":
        return "health admission=%s" % doc.get("admission")
    if not ADMISSION_ID.match(str(doc.get("admission_id", ""))):
        return "health admission_id malformed"
    if not SAFE_GENERATION.match(str(doc.get("safe_generation", ""))):
        return "health safe_generation malformed"
    heights = [doc.get(name) for name in HEIGHT_FIELDS]
    if not all(isinstance(h, int) and not isinstance(h, bool) and h > 0 for h in heights):
        return "health heights missing"
    if heights != sorted(heights):
        return "health heights out of order"
    finished = doc.get("completion_finished_ms")
    if not isinstance(finished, (int, float)) or finished <= 0:
        return "health completion_finished_ms missing"
    checked = _parse_utc(doc.get("checked_at"))
    if checked is None:
        return "health checked_at missing"
    age = (time.time() if now is None else now) - checked
    if age < -CLOCK_SKEW_S or age > max_age_s:
        return "health stale (%ds old)" % age
    return None


def _item(name, ok, detail, seq=None):
    return {"name": name, "ok": ok, "detail": detail, "records": [seq] if seq else []}


def _blocked(items, facts, models_reply):
    reasons = ["%s: %s" % (item["name"], item["detail"]) for item in items if not item["ok"]]
    return {"state": "BLOCKED", "reasons": reasons, "items": items, "facts": facts,
            "models_reply": models_reply}


def _poll_live(client, chain, preset):
    base = gateway_url(preset)
    items = []
    try:
        phases, seq = chain.confirmation_phases()
        blocking = [phase for phase in phases if phase in BLOCKING_CONFIRMATION_PHASES]
        items.append(_item("confirmation_poc", not blocking,
                           ", ".join(blocking) if blocking else "no active confirmation PoC", seq))
    except ChainError as error:
        items.append(_item("confirmation_poc", False, error.reason, error.seq))
    reply = client.get(base + "/v1/status")
    blocker = status_blocker(reply.json) if reply.ok else "status HTTP %s" % (reply.status or reply.transport_error)
    items.append(_item("gateway_status", blocker is None, blocker or "routable", reply.seq))
    if not preset["health_url"]:
        return items
    reply = client.get(preset["health_url"])
    blocker = health_blocker(reply.json, preset["health_max_age_s"]) if reply.ok \
        else "health HTTP %s" % (reply.status or reply.transport_error)
    items.append(_item("health", blocker is None, blocker or "fresh TRAFFIC_READY receipt", reply.seq))
    return items


def preflight(client, chain, preset, key_problem, wait_s, log):
    """Return READY only when every item holds at the same poll."""
    base = gateway_url(preset)
    items, facts = [], {}
    try:
        height, seq = chain.height()
        items.append(_item("chain", True, "height %d" % height, seq))
        params = chain.epoch_params()
        low, high = send_window(params, preset)
        epoch, _ = chain.epoch_index()
        facts = {
            "height": height, "epoch": epoch, "epoch_length": params["epoch_length"],
            "safe_start": params["safe_start"], "send_window": [low, high],
            "epoch_offset": epoch_offset(chain, height),
        }
        items.append(_item("epoch_params", low <= high,
                           "epoch %d, length %d, send window %d..%d" % (epoch, params["epoch_length"], low, high),
                           params["seq"]))
    except ChainError as error:
        items.append(_item("chain", False, error.reason, error.seq))
    models_reply = client.get(base + "/v1/models")
    listed = []
    if models_reply.ok and isinstance(models_reply.json, dict):
        listed = [m.get("id") for m in models_reply.json.get("data", []) if isinstance(m, dict)]
    if not models_reply.ok:
        detail = "models HTTP %s" % (models_reply.status or models_reply.transport_error)
    else:
        detail = "%s listed" % preset["model"] if preset["model"] in listed else "%s not listed" % preset["model"]
    items.append(_item("model", preset["model"] in listed, detail, models_reply.seq))
    items.append(_item("key", key_problem is None, key_problem or "present, mode 0600"))
    # A fixed blocker is reported together with one live poll, without waiting.
    fixed_ok = all(item["ok"] for item in items)
    deadline = time.monotonic() + (wait_s if fixed_ok else 0)
    while True:
        live = _poll_live(client, chain, preset)
        if fixed_ok and all(item["ok"] for item in live):
            return {"state": "READY", "reasons": [], "items": items + live, "facts": facts,
                    "models_reply": models_reply}
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return _blocked(items + live, facts, models_reply)
        log("waiting %ds more: %s" % (remaining, "; ".join(
            "%s: %s" % (item["name"], item["detail"]) for item in live if not item["ok"])))
        time.sleep(min(preset["health_poll_s"], remaining))
