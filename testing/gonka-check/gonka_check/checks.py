"""The four stage-0 smoke checks and their verdicts."""

import re

from .chain import FENCE_GUARD_BLOCKS, in_fence
from .guards import CONFIG_REJECTIONS
from .preflight import ADMISSION_ID, SAFE_GENERATION


CHECKS = (
    {"id": "model_served", "maps": ["REG-11"], "posts": 0,
     "what": "GET /v1/models lists the preset model"},
    {"id": "canary", "maps": ["SMK-06"], "posts": 1,
     "what": "\"7 + 5\" answers 12 with finish_reason and usage"},
    {"id": "floor64", "maps": ["REG-15"], "posts": 1,
     "what": "max_tokens 1 yields 64 completion tokens, finish_reason length"},
    {"id": "fence_audit", "maps": ["SMK-05", "REG-13"], "posts": 0,
     "what": "dispatches sit inside the proxy fence with ordered heights"},
)
MAPS = {check["id"]: check["maps"] for check in CHECKS}


def active_checks(direct):
    """Without the admission proxy there is no fence to audit."""
    return tuple(check for check in CHECKS if not (direct and check["id"] == "fence_audit"))
OUTPUT_FLOOR = 64


def verdict(check, value, reason, records=()):
    return {"check": check, "maps": MAPS[check], "verdict": value, "reason": reason,
            "records": [seq for seq in records if seq]}


def canary_payload(model, tag):
    return {
        "model": model,
        "messages": [{"role": "user", "content": "[%s] What is 7 + 5? Reply with the number only." % tag}],
        "max_tokens": 16,
        "temperature": 0,
        "stream": False,
        "enable_thinking": False,
    }


def floor64_payload(model, tag):
    return {
        "model": model,
        "messages": [{"role": "user", "content": "[%s] Count from 1 to 300, separated by commas." % tag}],
        "max_tokens": 1,
        "temperature": 0,
        "stream": False,
    }


def model_served(reply, model):
    if reply is None:
        return verdict("model_served", "BLOCKED", "models were not read")
    if not reply.ok or not isinstance(reply.json, dict):
        return verdict("model_served", "INCONCLUSIVE",
                       "models HTTP %s" % (reply.status or reply.transport_error), [reply.seq])
    listed = [m.get("id") for m in reply.json.get("data", []) if isinstance(m, dict)]
    if model in listed:
        return verdict("model_served", "PASS", "%s listed" % model, [reply.seq])
    return verdict("model_served", "FAIL", "%s not listed; served: %s" % (model, ", ".join(map(str, listed)) or "none"),
                   [reply.seq])


def _refused(check, reply):
    """Verdict for a completion that did not come back with 2xx, else None."""
    if reply.ok:
        return None
    detail = reply.error_code or reply.error_message or reply.transport_error or "no error body"
    records = [reply.send_seq, reply.seq]
    if reply.gdc.get("admission") == "pre_dispatch_rejected" and reply.error_code in CONFIG_REJECTIONS:
        return verdict(check, "FAIL", "proxy misconfigured: HTTP %s %s" % (reply.status, detail), records)
    if reply.gdc.get("admission") == "pre_dispatch_rejected":
        return verdict(check, "BLOCKED", "rejected before dispatch: HTTP %s %s" % (reply.status, detail), records)
    if reply.status is None:
        return verdict(check, "INCONCLUSIVE", "no reply: %s" % detail, records)
    if reply.status in (401, 403):
        return verdict(check, "BLOCKED", "gateway refused the key: HTTP %s %s" % (reply.status, detail), records)
    if reply.status == 429:
        return verdict(check, "INCONCLUSIVE", "rate limited: %s" % detail, records)
    return verdict(check, "FAIL", "HTTP %s %s" % (reply.status, detail), records)


def _first_choice(reply):
    body = reply.json if isinstance(reply.json, dict) else {}
    choices = body.get("choices") if isinstance(body.get("choices"), list) else []
    choice = choices[0] if choices and isinstance(choices[0], dict) else {}
    usage = body.get("usage") if isinstance(body.get("usage"), dict) else {}
    message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    return choice, message, usage


def visible_text(text):
    text = re.sub(r"<think>.*?</think>", "", text or "", flags=re.S)
    return text.split("<think>", 1)[0].strip()


def canary(reply):
    refused = _refused("canary", reply)
    if refused:
        return refused
    records = [reply.send_seq, reply.seq]
    choice, message, usage = _first_choice(reply)
    missing = [name for name, value in (
        ("choices", choice), ("finish_reason", choice.get("finish_reason")),
        ("usage.completion_tokens", usage.get("completion_tokens"))) if not value]
    if missing:
        return verdict("canary", "FAIL", "response lacks %s" % ", ".join(missing), records)
    text = visible_text(message.get("content"))
    if not re.search(r"\b12\b", text):
        return verdict("canary", "FAIL", "answer lacks 12: %r" % text[:80], records)
    return verdict("canary", "PASS", "answered 12; finish_reason=%s, completion_tokens=%s"
                   % (choice["finish_reason"], usage["completion_tokens"]), records)


def floor64(reply):
    refused = _refused("floor64", reply)
    if refused:
        return refused
    records = [reply.send_seq, reply.seq]
    choice, _message, usage = _first_choice(reply)
    tokens, finish = usage.get("completion_tokens"), choice.get("finish_reason")
    if tokens == OUTPUT_FLOOR and finish == "length":
        return verdict("floor64", "PASS", "max_tokens 1 gave %d tokens, finish_reason length" % tokens, records)
    return verdict("floor64", "FAIL", "completion_tokens=%s finish_reason=%s; expected %d and length"
                   % (tokens, finish, OUTPUT_FLOOR), records)


def fence_audit(sent, facts):
    """sent: (reply, slot) pairs; the slot carries the PoC start the send was scheduled against."""
    params = {"epoch_length": facts["epoch_length"], "safe_start": facts["safe_start"]}
    low, high = params["safe_start"], params["epoch_length"] - FENCE_GUARD_BLOCKS
    sent = list(sent)
    dispatched = [(r, slot) for r, slot in sent if r.gdc.get("admission") == "dispatched_once"]
    if not dispatched:
        return verdict("fence_audit", "INCONCLUSIVE", "no dispatched completion to audit",
                       [r.seq for r, _slot in sent])
    records = [r.seq for r, _slot in dispatched]
    for reply, slot in dispatched:
        gdc = reply.gdc
        heights = [gdc.get(name) for name in
                   ("arrival_height", "permit_height", "dispatch_height", "response_height")]
        if not all(isinstance(h, int) for h in heights):
            return verdict("fence_audit", "INCONCLUSIVE", "record %d lacks height headers" % reply.seq, records)
        arrival, permit, dispatch, response = heights
        if not in_fence(permit - slot["start"], params):
            return verdict("fence_audit", "FAIL", "record %d: permit height %d at epoch offset %d, fence %d..%d"
                           % (reply.seq, permit, permit - slot["start"], low, high), records)
        if not arrival <= permit <= dispatch <= response:
            return verdict("fence_audit", "FAIL", "record %d: heights out of order %s" % (reply.seq, heights),
                           records)
        if not ADMISSION_ID.match(str(gdc.get("admission_id", ""))) or \
                not SAFE_GENERATION.match(str(gdc.get("safe_generation", ""))):
            return verdict("fence_audit", "FAIL", "record %d: admission id or safe generation malformed"
                           % reply.seq, records)
    return verdict("fence_audit", "PASS", "%d dispatch(es) inside fence %d..%d, heights ordered"
                   % (len(dispatched), low, high), records)


JUDGES = {"canary": (canary_payload, canary), "floor64": (floor64_payload, floor64)}
