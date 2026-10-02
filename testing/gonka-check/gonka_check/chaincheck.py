"""GET-only chain checks for the `chain` profile: no gateway, no key, no completion."""

import concurrent.futures
import time
from urllib.parse import urlsplit

from .chain import BLOCKING_CONFIRMATION_PHASES, ChainError
from .checks import MAPS, verdict
from .target import LOOPBACK


KNOWN_PHASES = BLOCKING_CONFIRMATION_PHASES | {"CONFIRMATION_POC_INACTIVE", "CONFIRMATION_POC_COMPLETED"}
CHAIN_CHECKS = (
    {"id": "chain_advances", "maps": ["SMK-01"], "posts": 0,
     "what": "the public chain height grows over a few blocks"},
    {"id": "nodes_at_tip", "maps": ["SMK-02"], "posts": 0,
     "what": "every public node RPC answers, is not catching up and is near the tip"},
    {"id": "epoch_state", "maps": ["SMK-04"], "posts": 0,
     "what": "height, epoch start and the confirmation PoC event agree (a snapshot; watch shows progress)"},
)
MAPS.update({check["id"]: check["maps"] for check in CHAIN_CHECKS})


def chain_advances(chain, wait_s):
    try:
        first, seq = chain.height()
        started = time.monotonic()
        time.sleep(wait_s)
        second, seq2 = chain.height()
    except ChainError as error:
        return verdict("chain_advances", "INCONCLUSIVE", error.reason, [error.seq])
    waited = time.monotonic() - started
    if second > first:
        return verdict("chain_advances", "PASS", "height %d -> %d in %ds" % (first, second, waited), [seq, seq2])
    return verdict("chain_advances", "FAIL", "height stayed at %d for %ds" % (first, waited), [seq, seq2])


def _node_name(rpc):
    parts = urlsplit(rpc)
    if parts.hostname in LOOPBACK:
        return parts.path.strip("/").split("/")[0] or rpc
    return (parts.hostname or rpc).split(".")[0]


def nodes_at_tip(chain, nodes, max_lag):
    """Compare every node, and the public RPC itself, with the highest height any of them reports."""
    if not nodes:
        return verdict("nodes_at_tip", "INCONCLUSIVE", "the preset lists no node RPCs")
    targets = [("public RPC", chain.rpc)] + [(_node_name(rpc), rpc) for rpc in nodes]
    # All heights are read at once: a slow node must not make the others look behind.
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(targets)) as pool:
        futures = [(name, pool.submit(chain.node_height, rpc)) for name, rpc in targets]
    heights, problems, seqs = {}, [], []
    for name, future in futures:
        try:
            height, catching_up = future.result()
        except ChainError as error:
            problems.append("%s: %s" % (name, error.reason))
            seqs.append(error.seq)
            continue
        if catching_up:
            problems.append("%s: catching up at %d" % (name, height))
        else:
            heights[name] = height
    if not heights:
        return verdict("nodes_at_tip", "INCONCLUSIVE", "; ".join(problems), seqs)
    tip = max(heights.values())
    fine = []
    for name, height in heights.items():
        if tip - height > max_lag:
            problems.append("%s: %d blocks behind" % (name, tip - height))
        else:
            fine.append(name)
    if problems:
        return verdict("nodes_at_tip", "FAIL", "%s; at tip: %s" % ("; ".join(problems), ", ".join(fine) or "none"),
                       seqs)
    return verdict("nodes_at_tip", "PASS", "%d nodes and the public RPC within %d blocks of %d"
                   % (len(fine) - 1, max_lag, tip), seqs)


def epoch_state(chain):
    try:
        params = chain.epoch_params()
        height, seq = chain.height()
        group = chain.epoch_group()
        event = chain.confirmation_event()
    except ChainError as error:
        return verdict("epoch_state", "INCONCLUSIVE", error.reason, [error.seq])
    length = params["epoch_length"]
    into = height - group["start"]
    records = [params["seq"], seq]
    # The previous epoch group stays current until the PoC of the next epoch is validated.
    if not 0 <= into < length + params["safe_start"]:
        return verdict("epoch_state", "FAIL", "height %d is %d blocks from epoch %d start %d (length %d)"
                       % (height, into, group["epoch"], group["start"], length), records)
    where = "epoch %d started at %d, height %d, offset %d" % (group["epoch"], group["start"], height, height % length)
    if into >= length:
        where += " (next epoch PoC; group not switched yet)"
    if not event["active"]:
        return verdict("epoch_state", "PASS", "%s; no confirmation PoC" % where, records)
    if event["phase"] not in KNOWN_PHASES:
        return verdict("epoch_state", "FAIL", "%s; unknown confirmation PoC phase %s" % (where, event["phase"]), records)
    trigger = event["trigger_height"]
    if event["epoch_index"] not in (None, group["epoch"]) or (
            trigger is not None and not group["start"] <= trigger < group["start"] + length):
        return verdict("epoch_state", "INCONCLUSIVE", "%s; confirmation PoC %s belongs to epoch %s, trigger %s"
                       % (where, event["phase"], event["epoch_index"], trigger), records)
    return verdict("epoch_state", "PASS", "%s; confirmation PoC %s, trigger at offset %s"
                   % (where, event["phase"], trigger % length if trigger is not None else "?"), records)
