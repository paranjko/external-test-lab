"""Chain poller: reads public node RPC and LCD and exposes Prometheus metrics on :9800.

It needs no access to the hosts: every request is a GET to a published endpoint."""

import base64
import hashlib
import logging
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import requests
import yaml
from prometheus_client import Counter, Gauge, Histogram, start_http_server

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("poller")

CFG = yaml.safe_load(open(os.environ.get("POLLER_CONFIG", "/app/config.yml")))
NODES = CFG["nodes"]
# Label participants with the inventory alias of their published URL when it is known.
ALIAS = {url.rstrip("/"): name for name, url in NODES.items()}
TIMEOUT = CFG.get("timeout", 8)
IV = CFG["intervals"]

S = requests.Session()
S.headers["User-Agent"] = "gonka-monitoring/1"

# ── metrics ─────────────────────────────────────────────────────────────────
G = Gauge
rpc_up = G("gdc_chain_rpc_up", "Public node RPC answers", ["node"])
rpc_latency = G("gdc_chain_rpc_latency_seconds", "/status response time", ["node"])
node_height = G("gdc_chain_node_height", "Latest node height", ["node"])
node_block_ts = G("gdc_chain_node_latest_block_timestamp", "Latest block time of the node, unix", ["node"])
node_catching_up = G("gdc_chain_node_catching_up", "Node is catching up", ["node"])
node_earliest = G("gdc_chain_node_earliest_height", "Earliest block height the node serves", ["node"])
node_peers = G("gdc_chain_node_peers", "Node peer count", ["node"])
node_vp = G("gdc_chain_node_validator_power", "Voting power of this node's validator per /status", ["node"])
node_info = G("gdc_chain_node_info", "Node versions", ["node", "cometbft", "app"])
component_info = G("gdc_chain_component_info", "Component versions from /v1/versions", ["node", "component", "version"])
versions_up = G("gdc_chain_versions_up", "/v1/versions answers", ["node"])

chain_height = G("gdc_chain_chain_height", "Chain height per source")
blocks_total = Counter("gdc_chain_blocks_total", "Processed blocks")
block_interval = Histogram("gdc_chain_block_interval_seconds", "Interval between blocks",
                           buckets=(1, 2, 3, 4, 5, 6, 7, 8, 10, 15, 20, 30, 60, 120))
block_interval_last = G("gdc_chain_block_interval_last_seconds", "Interval before the latest block")
block_txs = G("gdc_chain_block_txs", "Transactions in the latest block")
signed_ratio = G("gdc_chain_block_signed_power_ratio", "Share of voting power that signed the previous block")
signatures = G("gdc_chain_block_signatures", "Signatures in last_commit of the latest block", ["state"])
val_signed = G("gdc_chain_validator_signed_last", "Validator signed the latest block", ["host", "validator"])
val_missed = Counter("gdc_chain_validator_missed_blocks", "Missed signatures seen by the poller", ["host", "validator"])
val_power = G("gdc_chain_validator_power", "Validator voting power in CometBFT", ["host", "validator"])
vals_count = G("gdc_chain_validators_count", "Validators in the set")
vals_power = G("gdc_chain_validators_total_power", "Total voting power of the set")
val_missed_window = G("gdc_chain_validator_missed_in_window", "Missed blocks in the slashing window", ["host", "validator"])
val_staking = G("gdc_chain_validator_staking", "Staking validator tokens; only bonded or jailed",
                ["host", "operator", "status", "jailed", "guardian"])
guardian = G("gdc_chain_guardian", "Operator in the guardian list", ["host", "operator"])
guardian_boost = G("gdc_chain_guardian_enhancement_active", "Guardian voting power differs from its group weight")

epoch_index = G("gdc_chain_epoch_index", "Latest epoch index")
epoch_start = G("gdc_chain_epoch_poc_start_height", "Cycle start height P")
epoch_len = G("gdc_chain_epoch_length", "Epoch length, blocks")
epoch_pos = G("gdc_chain_epoch_position", "Height position from cycle start P")
epoch_phase = G("gdc_chain_epoch_phase_code", "Cycle phase: 0 PoC generation, 1 batch exchange and wait, 2 PoC validation, 3 validator set switch, 4 inference")
epoch_left = G("gdc_chain_epoch_blocks_to_next_poc", "Blocks until the next PoC starts")
cpoc_active = G("gdc_chain_cpoc_active", "Confirmation PoC is running")
part_weight = G("gdc_chain_participant_weight", "Epoch group weight", ["host", "participant"])
part_cweight = G("gdc_chain_participant_confirmation_weight", "Epoch group confirmation weight", ["host", "participant"])
group_weight = G("gdc_chain_epoch_group_total_weight", "Epoch group total weight")
group_size = G("gdc_chain_epoch_group_size", "Epoch group members")
group_epoch = G("gdc_chain_epoch_group_index", "Epoch of the current epoch group")
participants = G("gdc_chain_participants", "Participants by status", ["status"])
gov_props = G("gdc_chain_gov_proposals", "Proposals by status (latest 100)", ["status"])
gov_last = G("gdc_chain_gov_last_proposal_id", "Latest proposal id")

gw_up = G("gdc_chain_gateway_up", "Gateway status answers", ["gateway"])
gw_working = G("gdc_chain_gateway_working", "Gateway has an active devshard", ["gateway"])
gw_devshards = G("gdc_chain_gateway_devshards", "Gateway devshards by phase", ["gateway", "phase"])
gw_error = G("gdc_chain_gateway_error", "Gateway returned an error", ["gateway", "type"])
gw_avail = G("gdc_chain_gateway_available_percent", "Gateway available capacity, %", ["gateway"])
gw_hosts = G("gdc_chain_gateway_hosts", "Gateway hosts", ["gateway", "state"])
gw_runtimes = G("gdc_chain_gateway_runtimes", "Gateway runtimes", ["gateway"])
gw_inflight = G("gdc_chain_gateway_in_flight_requests", "Requests in flight", ["gateway"])
gw_limit = G("gdc_chain_gateway_max_concurrent_requests", "Effective concurrent request limit", ["gateway"])

esc_open = G("gdc_chain_escrows_open", "Escrows created and not settled", ["creator"])
esc_locked = G("gdc_chain_escrow_locked_ngonka", "Amount held in unsettled escrows", ["creator"])
esc_recent = G("gdc_chain_escrows_created_recent", "Escrows created within the window", ["creator", "window"])
esc_settled = G("gdc_chain_escrows_settled", "Settled escrows", ["creator"])
esc_payout = G("gdc_chain_escrow_payout_ngonka", "Payout to hosts over all settlements", ["creator"])
esc_fees = G("gdc_chain_escrow_fees_ngonka", "Nonce fees over all settlements", ["creator"])
esc_nonces = G("gdc_chain_escrow_settled_nonces", "Nonces paid over all settlements: fees / fee_per_nonce", ["creator"])
creator_balance = G("gdc_chain_escrow_creator_balance_ngonka", "Wallet balance of an allowed escrow creator", ["creator"])

task_ok = G("gdc_chain_poller_last_success_timestamp", "Last successful task run", ["task"])
task_err = Counter("gdc_chain_poller_errors", "Task errors", ["task"])


# ── helpers ───────────────────────────────────────────────────────────────
def get(url, **params):
    r = S.get(url, params=params or None, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def rpc(node, path, **params):
    return get(f"{NODES[node]}/chain-rpc/{path}", **params)["result"]


def lcd(node, path, **params):
    return get(f"{NODES[node]}/chain-api/{path}", **params)


def host_of(url):
    url = (url or "").rstrip("/")
    if url in ALIAS:
        return ALIAS[url]
    m = re.match(r"https?://([^./:]+)", url)
    return m.group(1) if m else "unknown"


_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def bech32_to_hex(addr):
    """valcons/valoper/acc address to hex address bytes (checksum not verified)."""
    data = addr[addr.rfind("1") + 1:-6]
    vals = [_CHARSET.index(c) for c in data]
    acc, bits, out = 0, 0, bytearray()
    for v in vals:
        acc = (acc << 5) | v
        bits += 5
        while bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 0xFF)
    return out.hex().upper()


def pubkey_to_hex_address(b64):
    return hashlib.sha256(base64.b64decode(b64)).hexdigest()[:40].upper()


def parse_ts(s):
    s = s.rstrip("Z")
    if "." in s:
        base, frac = s.split(".", 1)
        s = base + "." + frac[:6]
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()


PREV_INFO = {}


def mark(task):
    task_ok.labels(task).set(time.time())


def chain_node():
    for n in CFG["chain_sources"]:
        try:
            rpc(n, "health")
            return n
        except Exception:
            continue
    raise RuntimeError("no chain source answers")


# Address book: validator hex address → host; operator → host; participant → host.
# Operator and participant match by address bytes (valoper = acc); the current key comes from staking.
BOOK = {"hex": {}, "op": {}, "part": {}, "guardians": set(), "at": 0}


def refresh_book(src):
    parts = lcd(src, "productscience/inference/inference/participant", **{"pagination.limit": 500}).get("participant", [])
    acc_host, statuses = {}, {}
    for p in parts:
        h = host_of(p.get("inference_url"))
        BOOK["part"][p["address"]] = h
        acc_host[bech32_to_hex(p["address"])] = h
        statuses[p.get("status", "UNKNOWN")] = statuses.get(p.get("status", "UNKNOWN"), 0) + 1
    participants.clear()
    for st, n in statuses.items():
        participants.labels(st).set(n)
    vals = lcd(src, "cosmos/staking/v1beta1/validators", **{"pagination.limit": 500}).get("validators", [])
    hexmap, opmap = {}, {}
    for v in vals:
        h = acc_host.get(bech32_to_hex(v["operator_address"]), "unknown")
        opmap[v["operator_address"]] = h
        hexmap[pubkey_to_hex_address(v["consensus_pubkey"]["key"])] = h
    BOOK["hex"], BOOK["op"] = hexmap, opmap
    params = lcd(src, "productscience/inference/inference/params")["params"]
    BOOK["guardians"] = set((params.get("genesis_guardian_params") or {}).get("guardian_addresses") or [])
    guardian.clear()
    for op in BOOK["guardians"]:
        guardian.labels(BOOK["op"].get(op, "unknown"), op[-6:]).set(1)
    BOOK["at"] = time.time()
    return params


def vlabel(hexaddr):
    return BOOK["hex"].get(hexaddr, "unknown"), hexaddr[:6]


# ── tasks ──────────────────────────────────────────────────────────────────
def poll_node(node):
    t0 = time.time()
    try:
        st = rpc(node, "status")
        rpc_latency.labels(node).set(time.time() - t0)
        rpc_up.labels(node).set(1)
        si = st["sync_info"]
        node_height.labels(node).set(int(si["latest_block_height"]))
        node_block_ts.labels(node).set(parse_ts(si["latest_block_time"]))
        node_catching_up.labels(node).set(1 if si["catching_up"] else 0)
        node_earliest.labels(node).set(int(si["earliest_block_height"]))
        node_vp.labels(node).set(int(st["validator_info"]["voting_power"]))
        try:
            node_peers.labels(node).set(int(rpc(node, "net_info")["n_peers"]))
        except Exception:
            pass
        try:
            info = (st["node_info"]["version"], rpc(node, "abci_info")["response"].get("version", ""))
            if PREV_INFO.get(node) not in (None, info):
                node_info.remove(node, *PREV_INFO[node])
            PREV_INFO[node] = info
            node_info.labels(node, *info).set(1)
        except Exception:
            pass
    except Exception as e:
        rpc_up.labels(node).set(0)
        # an unreachable node must not keep its last height and peers on the board
        for g in (rpc_latency, node_height, node_block_ts, node_catching_up, node_earliest, node_vp, node_peers):
            if (node,) in g._metrics:
                g.remove(node)
        if node in PREV_INFO:
            node_info.remove(node, *PREV_INFO.pop(node))
        log.debug("node %s: %s", node, e)


def task_nodes():
    if NODES:
        with ThreadPoolExecutor(max_workers=len(NODES)) as ex:
            list(ex.map(poll_node, NODES))
    mark("nodes")


LAST = {"height": None, "time": None}
MISSED_SEEN = set()


def process_block(src, h):
    blk = rpc(src, "block", height=h)["block"]
    commit_h = int(blk["last_commit"]["height"])
    vset = rpc(src, "validators", height=commit_h, per_page=100)["validators"]
    bt = parse_ts(blk["header"]["time"])
    if LAST["time"] is not None and LAST["height"] == h - 1:
        dt = max(bt - LAST["time"], 0)
        block_interval.observe(dt)
        block_interval_last.set(dt)
    LAST["time"], LAST["height"] = bt, h
    block_txs.set(len(blk["data"].get("txs") or []))
    blocks_total.inc()
    sigs = blk["last_commit"]["signatures"]
    powers = {v["address"]: int(v["voting_power"]) for v in vset}
    if any(a not in BOOK["hex"] for a in powers) and time.time() - BOOK["at"] > 60:
        refresh_book(src)
    total = sum(powers.values()) or 1
    signed = {s["validator_address"] for s in sigs if s.get("block_id_flag") == 2}
    counts = {"commit": 0, "absent": 0, "nil": 0}
    for s in sigs:
        counts[{2: "commit", 1: "absent", 3: "nil"}.get(s.get("block_id_flag"), "absent")] += 1
    for k, v in counts.items():
        signatures.labels(k).set(v)
    signed_ratio.set(sum(p for a, p in powers.items() if a in signed) / total)
    val_signed.clear()
    for a in powers:
        host, short = vlabel(a)
        val_missed.labels(host, short)
        ok = a in signed
        val_signed.labels(host, short).set(1 if ok else 0)
        if not ok:
            val_missed.labels(host, short).inc()
    current = {vlabel(a) for a in powers}
    for labels in list(MISSED_SEEN - current):
        val_missed.remove(*labels)
    MISSED_SEEN.clear(); MISSED_SEEN.update(current)
    val_power.clear()
    for a, p in powers.items():
        val_power.labels(*vlabel(a)).set(p)
    vals_count.set(len(powers))
    vals_power.set(sum(powers.values()))


def task_blocks():
    src = chain_node()
    top = int(rpc(src, "status")["sync_info"]["latest_block_height"])
    chain_height.set(top)
    if LAST["height"] is not None and top < LAST["height"]:
        # the chain was reset below the last processed block
        LAST["height"] = LAST["time"] = None
    start = top if LAST["height"] is None else LAST["height"] + 1
    start = max(start, top - CFG.get("max_block_catchup", 30) + 1)
    for h in range(start, top + 1):
        process_block(src, h)
    mark("blocks")


def task_chain():
    src = chain_node()
    ei = lcd(src, "productscience/inference/inference/epoch_info")
    p = ei["params"]["epoch_params"] if ei.get("params") else {}
    le = ei["latest_epoch"]
    start, length, height = int(le["poc_start_block_height"]), int(p.get("epoch_length", 0)), int(ei["block_height"])
    epoch_index.set(int(le["index"]))
    epoch_start.set(start)
    epoch_len.set(length)
    pos = height - start
    epoch_pos.set(pos)
    d = [int(p.get(k, 0)) for k in ("poc_stage_duration", "poc_validation_delay", "poc_validation_duration", "set_new_validators_delay")]
    # the new set signs from P+23: group written at P+19 plus 4 blocks until CometBFT applies it
    edges = [d[0], d[0] + d[1], d[0] + d[1] + d[2], d[0] + d[1] + d[2] + d[3] + 4]
    epoch_phase.set(next((i for i, e in enumerate(edges) if pos < e), 4))
    epoch_left.set(max(length - pos, 0) if length else 0)
    cpoc_active.set(1 if ei.get("is_confirmation_poc_active") else 0)

    g = lcd(src, "productscience/inference/inference/current_epoch_group_data")["epoch_group_data"]
    part_weight.clear(); part_cweight.clear()
    weights = {}
    for w in g.get("validation_weights", []):
        host = BOOK["part"].get(w["member_address"], "unknown")
        weights[w["member_address"]] = int(w.get("weight", 0))
        part_weight.labels(host, w["member_address"][-6:]).set(int(w.get("weight", 0)))
        part_cweight.labels(host, w["member_address"][-6:]).set(int(w.get("confirmation_weight", 0) or 0))
    group_weight.set(int(g.get("total_weight", 0) or sum(weights.values())))
    group_size.set(len(weights))
    group_epoch.set(int(g.get("epoch_index", 0)))

    vals = lcd(src, "cosmos/staking/v1beta1/validators", **{"pagination.limit": 500}).get("validators", [])
    val_staking.clear()
    active_hex = set()
    boost = 0
    host_weight = {BOOK["part"].get(a): w for a, w in weights.items()}
    for v in vals:
        op, jailed = v["operator_address"], bool(v.get("jailed"))
        bonded = v.get("status") == "BOND_STATUS_BONDED"
        if not (bonded or jailed):
            continue  # old identities: left the set and not jailed
        h = BOOK["op"].get(op, "unknown")
        active_hex.add(pubkey_to_hex_address(v["consensus_pubkey"]["key"]))
        val_staking.labels(h, op[-6:], "bonded" if bonded else "not bonded",
                           "yes" if jailed else "no", "yes" if op in BOOK["guardians"] else "no").set(int(v.get("tokens", 0)))
        # guardian enhancement: guardian staking tokens differ from its group weight
        if op in BOOK["guardians"] and h in host_weight and int(v.get("tokens", 0)) != host_weight[h]:
            boost = 1
    guardian_boost.set(boost)

    infos = lcd(src, "cosmos/slashing/v1beta1/signing_infos", **{"pagination.limit": 500}).get("info", [])
    val_missed_window.clear()
    for i in infos:
        hx = bech32_to_hex(i["address"])
        if hx in active_hex:
            val_missed_window.labels(*vlabel(hx)).set(int(i.get("missed_blocks_counter", 0)))
    mark("chain")


def gateway_down(name):
    gw_up.labels(name).set(0)
    gw_working.labels(name).set(0)
    drop_gateway((gw_devshards, gw_error, gw_avail, gw_hosts, gw_runtimes, gw_inflight, gw_limit), name)


def poll_gateway(name, url):
    try:
        r = S.get(url, timeout=TIMEOUT)
        st = r.json()
    except Exception:
        gateway_down(name)
        return
    try:
        apply_gateway_status(name, st)
    except Exception as e:
        gateway_down(name)
        log.debug("gateway %s: %s", name, e)


def drop_gateway(gauges, name):
    for g in gauges:
        for labels in [m for m in list(g._metrics) if m[0] == name]:
            g.remove(*labels)


def apply_gateway_status(name, st):
    gw_up.labels(name).set(1)
    drop_gateway((gw_devshards, gw_error, gw_avail, gw_hosts, gw_runtimes, gw_inflight, gw_limit), name)
    phases = {}
    if "devshards" not in st and st.get("escrow_id"):
        # v4 gateways report their single escrow instead of a devshard list
        phases[st.get("phase") or "unknown"] = 1
    for d in st.get("devshards") or []:
        ph = d.get("phase") or "unknown"
        phases[ph] = phases.get(ph, 0) + 1
    for ph, n in phases.items():
        gw_devshards.labels(name, ph).set(n)
    gw_working.labels(name).set(1 if phases.get("active") else 0)
    err = st.get("error")
    if err:
        kind = err.get("type") if isinstance(err, dict) else err
        gw_error.labels(name, str(kind or "error")).set(1)
    cap, lim = st.get("capacity"), st.get("limiter")
    if isinstance(cap, dict):
        gw_avail.labels(name).set(float(cap.get("available_percent", 0) or 0))
        gw_hosts.labels(name, "available").set(int(cap.get("available_host_count", 0) or 0))
        gw_hosts.labels(name, "unavailable").set(int(cap.get("unavailable_host_count", 0) or 0))
    if "runtimes" in st:
        gw_runtimes.labels(name).set(int(st.get("runtimes") or 0))
    if isinstance(lim, dict):
        gw_inflight.labels(name).set(int(lim.get("in_flight_requests", 0) or 0))
        gw_limit.labels(name).set(int(lim.get("effective_max_concurrent_requests", 0) or 0))


def task_gateway():
    for name, url in (CFG.get("gateways") or {}).items():
        poll_gateway(name, url)
    mark("gateway")


CREATORS = {addr: name for name, addr in (CFG.get("escrow_creators") or {}).items()}
# Creations, settlements and block times never change: each is read once and kept.
CREATED, SETTLED, BLOCK_TIME = {}, {}, {}


def creator_name(addr):
    return CREATORS.get(addr) or (addr[-6:] if addr else "unknown")


def new_events(src, kind, known, per_page=100):
    """Events of kind newest first, read until a page reaches an already known escrow."""
    out = []
    for page in range(1, 1000):
        res = rpc(src, "tx_search", query=f'"{kind}.escrow_id EXISTS"', page=page, per_page=per_page, order_by='"desc"')
        hit = False
        for tx in res.get("txs", []):
            for ev in tx["tx_result"].get("events", []):
                if ev.get("type") != kind:
                    continue
                attrs = {a["key"]: a.get("value", "") for a in ev.get("attributes", [])}
                if attrs.get("escrow_id") in known:
                    hit = True
                    continue
                attrs["height"] = int(tx["height"])
                out.append(attrs)
        if hit or page * per_page >= int(res.get("total_count", 0)):
            return out
    return out


def block_time(src, height):
    if height not in BLOCK_TIME:
        BLOCK_TIME[height] = parse_ts(rpc(src, "block", height=height)["block"]["header"]["time"])
    return BLOCK_TIME[height]


def task_escrow():
    src = chain_node()
    params = lcd(src, "productscience/inference/inference/params")["params"].get("devshard_escrow_params", {})
    for addr in params.get("allowed_creator_addresses", []):
        coins = lcd(src, f"cosmos/bank/v1beta1/balances/{addr}").get("balances", [])
        creator_balance.labels(creator_name(addr)).set(sum(int(c["amount"]) for c in coins if c.get("denom") == "ngonka"))

    for ev in new_events(src, "devshard_escrow_created", CREATED):
        CREATED[ev["escrow_id"]] = (creator_name(ev.get("creator", "")), int(ev.get("amount", 0) or 0), ev["height"])
    for ev in new_events(src, "devshard_escrow_settled", SETTLED):
        e = lcd(src, f"productscience/inference/inference/devshard_escrow/{ev['escrow_id']}").get("escrow") or {}
        fees, fee = int(ev.get("fees", 0) or 0), int(e.get("fee_per_nonce") or params.get("fee_per_nonce") or 0)
        SETTLED[ev["escrow_id"]] = (creator_name(e.get("creator") or ev.get("settler", "")),
                                    int(ev.get("total_payout", 0) or 0), fees, fees // fee if fee else 0)

    opened, locked, recent = {}, {}, {}
    for eid, (who, amount, _) in CREATED.items():
        if eid not in SETTLED:
            opened[who] = opened.get(who, 0) + 1
            locked[who] = locked.get(who, 0) + amount
    now = time.time()
    for who, _, height in sorted(CREATED.values(), key=lambda c: -c[2]):
        age = now - block_time(src, height)
        if age > 86400:
            break
        for window, seconds in (("1h", 3600), ("24h", 86400)):
            if age <= seconds:
                recent[(who, window)] = recent.get((who, window), 0) + 1
    sums = {}
    for who, payout, fees, nonces in SETTLED.values():
        row = sums.setdefault(who, [0, 0, 0, 0])
        for i, v in enumerate((1, payout, fees, nonces)):
            row[i] += v

    for g in (esc_open, esc_locked, esc_recent, esc_settled, esc_payout, esc_fees, esc_nonces):
        g.clear()
    for who in opened:
        esc_open.labels(who).set(opened[who]); esc_locked.labels(who).set(locked[who])
    for who in {w for w, _, _ in CREATED.values()}:
        for window in ("1h", "24h"):
            esc_recent.labels(who, window).set(recent.get((who, window), 0))
    for who, (n, payout, fees, nonces) in sums.items():
        esc_settled.labels(who).set(n); esc_payout.labels(who).set(payout)
        esc_fees.labels(who).set(fees); esc_nonces.labels(who).set(nonces)
    mark("escrow")


def task_slow():
    src = chain_node()
    refresh_book(src)
    component_info.clear()
    for node, base in NODES.items():
        try:
            v = get(f"{base}/v1/versions")
            versions_up.labels(node).set(1)
            for k in ("api_version", "node_version"):
                if isinstance(v.get(k), dict):
                    component_info.labels(node, v[k].get("application_name", k), v[k].get("version", "?")).set(1)
            for ml in v.get("mlnodes") or []:
                component_info.labels(node, "mlnode", ml.get("version", "?")).set(1)
        except Exception:
            versions_up.labels(node).set(0)
    props = lcd(src, "cosmos/gov/v1/proposals", **{"pagination.limit": 100, "pagination.reverse": "true"}).get("proposals", [])
    gov_props.clear()
    counts = {}
    for p in props:
        counts[p["status"]] = counts.get(p["status"], 0) + 1
    for k, n in counts.items():
        gov_props.labels(k.replace("PROPOSAL_STATUS_", "").lower()).set(n)
    if props:
        gov_last.set(max(int(p["id"]) for p in props))
    mark("slow")


TASKS = [("slow", task_slow, IV["slow"]), ("nodes", task_nodes, IV["nodes"]),
         ("chain", task_chain, IV["chain"]), ("gateway", task_gateway, IV["chain"]),
         ("blocks", task_blocks, IV["blocks"]), ("escrow", task_escrow, IV.get("escrow", 120))]


def main():
    start_http_server(int(os.environ.get("POLLER_PORT", "9800")))
    log.info("poller started, %d nodes", len(NODES))
    due = {name: 0 for name, _, _ in TASKS}
    while True:
        now = time.time()
        for name, fn, every in TASKS:
            if now >= due[name]:
                try:
                    fn()
                except Exception as e:
                    task_err.labels(name).inc()
                    log.warning("task %s failed: %s", name, e)
                due[name] = time.time() + every
        time.sleep(1)


if __name__ == "__main__":
    main()
