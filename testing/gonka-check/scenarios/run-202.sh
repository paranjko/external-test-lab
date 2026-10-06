#!/usr/bin/env bash
# Live DevNet window at group size SIZE (64) on gateway A: the base -> SIZE proposal, escrow W and escrow Q created
# at SIZE slots, the SIZE -> base rollback right after, REQUESTS completions into W, Q left without requests for
# QUIET_S while its nonce is read every heartbeat turn, then both settled by hand in the same epoch. summary.json
# keeps the settlement gas, signatures and host stats of both escrows and the nonces Q spent per turn.
# Dry by default: reads only. --check-gov reads only the run account and its balance.
# shellcheck disable=SC2034,SC2154  # variables are set by the lib.sh functions
set -euo pipefail
RUN_ROOT=${RUN_ROOT:-$HOME/gonka-202-runs}
REQUESTS=${REQUESTS:-20}
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SIZE=${SIZE:-64}
QUIET_S=${QUIET_S:-600}
TURN_S=24
NEED=${NEED:-230}

mode=dry wait=0 yes=0 amount="" check=0
usage() { echo "usage: $0 [--run] [--yes] [--wait] [--amount NGONKA] | --check-gov" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --run) mode=run ;;
    --yes) yes=1 ;;
    --wait) wait=1 ;;
    --amount) [ $# -ge 2 ] || usage; amount=$2; shift ;;
    --check-gov) check=1 ;;
    *) usage ;;
  esac
  shift
done
[ "$check" = 0 ] || [ "$mode" = dry ] || usage
[[ $SIZE =~ ^[1-9][0-9]*$ ]] || { echo "SIZE must be a positive integer" >&2; exit 2; }

# quiet_samples ID: the escrow nonce every heartbeat turn for QUIET_S seconds into quiet.tsv.
quiet_samples() {
  local t0=$SECONDS code nonce
  : > "$run_dir/quiet.tsv"
  while :; do
    code=$(gw status-q GET "/devshard/$1/v1/status" admin)
    nonce=$(jget "$run_dir/status-q.json" nonce 2>/dev/null || true)
    [ "$code" = 200 ] && [ -n "$nonce" ] || log "status of Q: HTTP $code"
    printf '%s\t%s\n' "$((SECONDS - t0))" "${nonce:-}" >> "$run_dir/quiet.tsv"
    [ $((SECONDS - t0)) -lt "$QUIET_S" ] || break
    sleep "$TURN_S"
  done
  log "Q nonce $(head -n 1 "$run_dir/quiet.tsv" | cut -f 2) -> ${nonce:-?} in $((SECONDS - t0)) s without requests"
}

# open_proposals: "id title" of every proposal in its voting period, one per line; status 1 on a read error.
open_proposals() {
  chain "$GOV/proposals?proposal_status=PROPOSAL_STATUS_VOTING_PERIOD" | python3 -c '
import json, sys
for p in json.load(sys.stdin).get("proposals", []):
    print(p["id"], (p.get("title") or "").replace("\n", " ")[:80])'
}

# quiet_gov WAIT_S: no other proposal in voting, waiting up to WAIT_S; a parameter proposal of ours built while
# another one is open would put back the values it changes.
quiet_gov() {
  local until=$((SECONDS + $1)) open
  while :; do
    open=$(open_proposals) || { log "open proposals are unreadable"; return 1; }
    [ -n "$open" ] || return 0
    [ "$SECONDS" -lt "$until" ] || { log "still in voting: $(echo "$open" | tr '\n' ';')"; return 1; }
    log "waiting for proposals in voting: $(echo "$open" | tr '\n' ';')"
    sleep 15
  done
}

# summary: settlement gas, signatures and host stats of W and Q, and the nonces Q spent per turn, into summary.json.
summary() {
  python3 - "$run_dir" "$SIZE" "$base" "$TURN_S" <<'PY' | tee -a "$run_dir/$run_name.log"
import json, os, sys
run, size, base, turn = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])

def load(name):
    path = os.path.join(run, name)
    return json.load(open(path)) if os.path.exists(path) else {}

def settle(role):
    tx = load("settle-%s-tx.json" % role)
    response, body = tx.get("tx_response") or {}, (tx.get("tx") or {}).get("body") or {}
    msg = (body.get("messages") or [{}])[0]
    return {"tx": response.get("txhash"), "height": response.get("height"), "code": response.get("code"),
            "gas_used": int(response["gas_used"]) if response.get("gas_used") else None,
            "gas_wanted": int(response["gas_wanted"]) if response.get("gas_wanted") else None,
            "signatures": len(msg.get("signatures") or []), "host_stats": len(msg.get("host_stats") or []),
            "nonce": msg.get("nonce")}

samples = []
for line in open(os.path.join(run, "quiet.tsv")) if os.path.exists(os.path.join(run, "quiet.tsv")) else []:
    t, _, nonce = line.rstrip("\n").partition("\t")
    if nonce:
        samples.append([int(t), int(nonce)])
quiet = {"samples": samples}
if len(samples) >= 2 and samples[-1][0] > samples[0][0]:
    turns = (samples[-1][0] - samples[0][0]) / turn
    quiet.update(seconds=samples[-1][0] - samples[0][0], nonces=samples[-1][1] - samples[0][1],
                 per_turn=round((samples[-1][1] - samples[0][1]) / turns, 1), expected_per_turn=size + 2)
params = (load("params.json").get("params") or {}).get("devshard_escrow_params") or {}
out = {"size": size, "base": base, "w": settle("w"), "q": dict(settle("q"), quiet=quiet),
       "fee_per_nonce": params.get("fee_per_nonce")}
json.dump(out, open(os.path.join(run, "summary.json"), "w"), indent=1)
for role in ("w", "q"):
    s = out[role]
    if s["gas_used"] is not None:
        print("%s: settle code %s, gas %s of %s (default limit 500000), %s signatures, %s host stats" % (
            role.upper(), s["code"], s["gas_used"], s["gas_wanted"], s["signatures"], s["host_stats"]))
if "per_turn" in quiet:
    print("Q: %s nonces in %s s without requests, %s per %s s turn (G + 2 = %s)" % (
        quiet["nonces"], quiet["seconds"], quiet["per_turn"], turn, size + 2))
PY
}

changed=0 rolled=0 proposal_id=""
remind() {
  [ "$changed" = 1 ] && [ "$rolled" = 0 ] || return 0
  [ -z "$proposal_id" ] || proposal_final "$proposal_id" >/dev/null || true
  chain_params
  [ "$group_size" = "$SIZE" ] || { log "group_size is $group_size after the stop, nothing to roll back"; return 0; }
  log "group_size is $SIZE after the stop: proposal $SIZE -> $base"
  quiet_gov 600 || log "WARN: rolling back while another proposal is in voting"
  gov_change "$base" && return 0
  log "REMINDER: group_size may still be $SIZE on DevNet; the rollback is $run_dir/proposal-group-size-$base.json"
}

run_kind=$mode
[ "$check" = 0 ] || run_kind=check
start_run window-202 "$run_kind"
trap remind EXIT
log "run $run_dir, mode $run_kind"
log "1/8 chain checks"
chain_params
base=$group_size
log "group_size $base, max_escrows_per_epoch $max_escrows; the window runs at $SIZE"
[ "$base" != "$SIZE" ] || stop "group_size is already $SIZE"
amount=${amount:-$(jget "$run_dir/params.json" params.devshard_escrow_params.min_amount)}
[[ $amount =~ ^[1-9][0-9]*$ ]] || die "escrow amount '$amount' is not a positive integer; pass --amount"
gov_params
if ! gov_account 2; then
  [ "$check" = 0 ] || { log "governance check: FAIL"; exit 1; }
  stop "the run account cannot pay two deposits"
fi
[ "$check" = 0 ] || { log "governance check: PASS; the guardian key holders vote on their side"; exit 0; }

log "2/8 gateway A admin API on $GATEWAY_HOST:127.0.0.1:$GATEWAY_PORT"
gateway_settings

log "3/8 window"
wait_window "$NEED"
free_places 2
proposal_file "$SIZE"
proposal_file "$base"
quiet_gov 0 || stop "another proposal is in voting; ours would overwrite the parameters it changes"

if [ "$mode" = dry ]; then
  log "plan, all in epoch $epoch:"
  log "  the run account submits the $base -> $SIZE proposal, the guardians vote, the run checks the result"
  log "  escrows W and Q of $amount ngonka at $SIZE slots, then at once the $SIZE -> $base rollback"
  log "  $REQUESTS requests into W; Q gets none and its nonce is read every $TURN_S s for $QUIET_S s"
  log "  settle W, then Q, before P+$rotate_at; summary.json with the gas and the nonces per turn"
  log "dry run: nothing sent; run with --run, add --wait to wait for the window"
  exit 0
fi

if [ "$yes" != 1 ]; then
  printf 'Run the group size %s window in epoch %s with escrows of %s ngonka on gateway A? Type yes: ' \
    "$SIZE" "$epoch" "$amount"
  read -r answer
  [ "$answer" = yes ] || die "not confirmed"
fi

log "4/8 proposal $base -> $SIZE"
quiet_gov 0 || die "another proposal is in voting; ours would overwrite the parameters it changes"
changed=1
gov_change "$SIZE" || die "the $base -> $SIZE proposal was not accepted"
change=$proposal_id

log "5/8 escrows W and Q at group_size $SIZE"
create_escrow w
w_escrow=$escrow w_id=$id
escrow_on_chain w "$w_escrow" "$SIZE"
create_escrow q
q_escrow=$escrow q_id=$id
escrow_on_chain q "$q_escrow" "$SIZE"
gw heightsync-start GET /v1/debug/heightsync admin > /dev/null

log "6/8 rollback $SIZE -> $base, then $REQUESTS requests into W"
rollback=""
quiet_gov 600 || log "WARN: rolling back while another proposal is in voting"
for try in 1 2 3; do
  if gov_change "$base"; then
    rolled=1 rollback=$proposal_id
    break
  fi
  log "the $SIZE -> $base proposal was not accepted, try $try of 3"
  sleep 10
done
[ "$rolled" = 1 ] || log "group_size stays $SIZE for now; the rollback is retried at the end"
send_requests w "$w_id"

log "7/8 Q without requests for $QUIET_S s"
quiet_samples "$q_id"
gw heightsync-end GET /v1/debug/heightsync admin > /dev/null

log "8/8 settle W, then Q"
settle_escrow w "$w_id"
settle_escrow q "$q_id"
summary
log "done: W $w_escrow, Q $q_escrow, change ${change:-?}, rollback ${rollback:-?}"
