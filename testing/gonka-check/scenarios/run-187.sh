#!/usr/bin/env bash
# Live run of a group size change on gateway A: escrow A at 5 slots, the 5 -> 9 proposal, escrow B at 9 slots, both
# settled by hand in the same epoch, the 9 -> 5 rollback, then gcheck escrow record and verdict. The run account
# submits each proposal and votes yes for the genesis guardians through their vote grants;
# with --gov wait it only writes the proposal files, says when, and waits for group_size. --check-gov reads only
# the run account, its vote grants and its balance.
# shellcheck disable=SC2034,SC2154  # variables are set by the lib.sh functions
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

CHANGE_BY=${CHANGE_BY:-200}
ROLLBACK_WAIT_S=${ROLLBACK_WAIT_S:-1800}
GOV=/chain-api/cosmos/gov/v1
GOV_HOME=${GOV_HOME:-$HOME/gov-187}
GOV_KEY=${GOV_KEY:-gov-187}
INFERENCED=${INFERENCED:-$GOV_HOME/bin/inferenced}
CHAIN_ID=${CHAIN_ID:-gonka-devnet-community}

mode=dry wait=0 yes=0 amount="" gov=grants check=0
usage() { echo "usage: $0 [--run] [--yes] [--wait] [--amount NGONKA] [--gov grants|wait] | --check-gov" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --run) mode=run ;;
    --yes) yes=1 ;;
    --wait) wait=1 ;;
    --amount) [ $# -ge 2 ] || usage; amount=$2; shift ;;
    --gov) [ $# -ge 2 ] && [[ $2 =~ ^(grants|wait)$ ]] || usage; gov=$2; shift ;;
    --check-gov) check=1 ;;
    *) usage ;;
  esac
  shift
done
[ "$check" = 0 ] || { [ "$mode" = dry ] && [ "$gov" = grants ]; } || usage

# newest_passed SIZE AFTER: id of the newest passed proposal above AFTER that sets group_size to SIZE.
newest_passed() {
  chain "$GOV/proposals?proposal_status=PROPOSAL_STATUS_PASSED&pagination.reverse=true&pagination.limit=10" \
    > "$run_dir/proposals.json" || return 1
  python3 - "$run_dir/proposals.json" "$1" "$2" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1])).get("proposals", []):
    sizes = [str((m.get("params") or {}).get("devshard_escrow_params", {}).get("group_size")) for m in p.get("messages", [])]
    if int(p["id"]) > int(sys.argv[3]) and sys.argv[2] in sizes:
        print(p["id"])
        break
PY
}

# proposal_file SIZE: MsgUpdateParams from the live parameters with only group_size set to SIZE.
proposal_file() {
  chain_params
  python3 - "$run_dir/params.json" "$authority" "$1" "$run_dir/proposal-group-size-$1.json" "$deposit" <<'PY'
import json, sys
params = json.load(open(sys.argv[1]))["params"]
params["devshard_escrow_params"]["group_size"] = int(sys.argv[3])
json.dump({"messages": [{"@type": "/inference.inference.MsgUpdateParams", "authority": sys.argv[2], "params": params}],
           "metadata": "", "deposit": sys.argv[5] + "ngonka", "expedited": False,
           "title": "DevNet group_size %s for a group size change test" % sys.argv[3],
           "summary": "Set devshard_escrow_params.group_size to %s; every other parameter keeps its live value." % sys.argv[3]},
          open(sys.argv[4], "w"), indent=1)
PY
  log "proposal file: $run_dir/proposal-group-size-$1.json"
}

# wait_group_size SIZE SECONDS [BY]: poll the live group_size until SIZE; give up after SECONDS or past P+BY.
wait_group_size() {
  local until=$((SECONDS + $2)) size
  while [ "$SECONDS" -lt "$until" ]; do
    size=$(chain "$API/params" | python3 -c 'import json,sys; print(json.load(sys.stdin)["params"]["devshard_escrow_params"]["group_size"])') || size="?"
    read -r height _ _ _ offset < <(cycle)
    [ "$size" = "$1" ] && { log "group_size is $1 at height $height (P+$offset)"; return 0; }
    [ -z "${3:-}" ] || [ "$offset" -le "$3" ] || return 1
    sleep 5
  done
  return 1
}

# grants_check: the share of bonded tokens behind valid vote grants to the run account, then those guardians;
# one line per guardian into grants.txt.
grants_check() {
  python3 - "$CHAIN" "$gov_address" "$run_dir/grants.txt" <<'PY'
import json, sys, time, urllib.parse, urllib.request
chain, grantee = sys.argv[1], sys.argv[2]
CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def get(path):
    with urllib.request.urlopen(chain + path, timeout=20) as reply:
        return json.load(reply)
def account(valoper):
    def polymod(v):
        g, c = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3], 1
        for x in v:
            b, c = c >> 25, (c & 0x1ffffff) << 5 ^ x
            for i in range(5):
                c ^= g[i] if (b >> i) & 1 else 0
        return c
    data = [CH.find(x) for x in valoper.rsplit("1", 1)[1]][:-6]
    p = polymod([ord(x) >> 5 for x in "gonka"] + [0] + [ord(x) & 31 for x in "gonka"] + data + [0] * 6) ^ 1
    return "gonka1" + "".join(CH[x] for x in data + [(p >> 5 * (5 - i)) & 31 for i in range(6)])
valopers = get("/chain-api/productscience/inference/inference/params")["params"]["genesis_guardian_params"]["guardian_addresses"]
bonded = get("/chain-api/cosmos/staking/v1beta1/validators?status=BOND_STATUS_BONDED&pagination.limit=200")["validators"]
tokens = {v["operator_address"]: int(v["tokens"]) for v in bonded}
total = sum(tokens.values()) or 1
now, voters, share, rows = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()), [], 0, []
for valoper in valopers:
    query = urllib.parse.urlencode({"granter": account(valoper), "grantee": grantee, "msg_type_url": "/cosmos.gov.v1.MsgVote"})
    grants = get("/chain-api/cosmos/authz/v1beta1/grants?" + query).get("grants") or []
    until = "vote grant until " + (grants[0].get("expiration") or "no expiry") if grants else "no vote grant"
    if grants and (grants[0].get("expiration") or "9")[:19] > now:
        voters.append(account(valoper))
        share += tokens.get(valoper, 0)
    rows.append("%s %.1f%% %s" % (account(valoper), 100.0 * tokens.get(valoper, 0) / total, until))
open(sys.argv[3], "w").write("\n".join(rows) + "\n")
print("%.1f" % (100.0 * share / total), " ".join(voters))
PY
}

# gov_tx ARGS...: one transaction of the run account; its hash in tx_hash, or the reason logged and status 1.
gov_tx() {
  local out
  out=$("$INFERENCED" "$@" --from "$GOV_KEY" --keyring-backend test --keyring-dir "$GOV_HOME" --chain-id "$CHAIN_ID" \
    --node "$CHAIN/chain-rpc/" --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --broadcast-mode sync \
    --output json --yes </dev/null 2>"$run_dir/gov-tx.err" | tail -n 1) \
    || { log "$2 $3: $(tail -c 300 "$run_dir/gov-tx.err")"; return 1; }
  tx_hash=$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(1) if r.get("code") else print(r["txhash"])' "$out") \
    || { log "$2 $3 refused: $out"; return 1; }
}

# wait_tx HASH NAME: the committed transaction into NAME.json; status 1 unless it passed.
wait_tx() {
  for _ in $(seq 1 60); do
    chain "/chain-api/cosmos/tx/v1beta1/txs/$1" > "$run_dir/$2.json" 2>/dev/null && break
    sleep 2
  done
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["tx_response"]; sys.exit(int(r.get("code") or 0))' \
    "$run_dir/$2.json" 2>/dev/null || { log "$2: transaction $1 failed or not found"; return 1; }
}

# submit_and_vote SIZE: proposal SIZE from the run account, then yes for every guardian behind a vote grant.
submit_and_vote() {
  proposal_id=""
  gov_tx tx gov submit-proposal "$run_dir/proposal-group-size-$1.json" || return 1
  changed=1
  wait_tx "$tx_hash" "submit-$1" || return 1
  proposal_id=$(python3 -c '
import json, sys
for ev in json.load(open(sys.argv[1]))["tx_response"].get("events", []):
    for a in ev.get("attributes", []):
        if ev["type"] == "submit_proposal" and a["key"] == "proposal_id":
            print(a["value"]); sys.exit(0)
sys.exit(1)' "$run_dir/submit-$1.json") || { log "no proposal id in transaction $tx_hash"; return 1; }
  python3 - "$proposal_id" "$run_dir/votes-$proposal_id.json" "${voters[@]}" <<'PY' || return 1
import json, sys
votes = [{"@type": "/cosmos.gov.v1.MsgVote", "proposal_id": sys.argv[1], "voter": v, "option": "VOTE_OPTION_YES",
          "metadata": ""} for v in sys.argv[3:]]
json.dump({"body": {"messages": votes, "memo": "", "timeout_height": "0", "extension_options": [],
                    "non_critical_extension_options": []},
           "auth_info": {"signer_infos": [], "fee": {"amount": [], "gas_limit": "0", "payer": "", "granter": ""}},
           "signatures": []}, open(sys.argv[2], "w"))
PY
  gov_tx tx authz exec "$run_dir/votes-$proposal_id.json" || return 1
  wait_tx "$tx_hash" "votes-$proposal_id" || return 1
  log "proposal $proposal_id submitted, yes for ${#voters[@]} guardians in transaction $tx_hash"
}

# rollback_after_stop: once the last proposal is final, the 9 -> 5 proposal through the grants if group_size is 9.
rollback_after_stop() {
  for _ in $(seq 1 24); do
    [ -n "$proposal_id" ] || break
    chain "$GOV/proposals/$proposal_id" | python3 -c 'import json,sys
sys.exit(json.load(sys.stdin)["proposal"]["status"] in ("PROPOSAL_STATUS_DEPOSIT_PERIOD", "PROPOSAL_STATUS_VOTING_PERIOD"))' && break
    sleep 5
  done
  chain_params
  [ "$group_size" = 9 ] || { log "group_size is $group_size after the stop, nothing to roll back"; return 0; }
  log "group_size is 9 after the stop: 9 -> 5 through the vote grants"
  proposal_file 5
  submit_and_vote 5 && wait_group_size 5 600
}

changed=0 rolled=0 rolling=0 proposal_id=""
remind() {
  [ "$changed" = 1 ] && [ "$rolled" = 0 ] || return 0
  if [ "$gov" = grants ] && [ "$rolling" = 0 ] && (rollback_after_stop); then return 0; fi
  log "REMINDER: group_size may still be 9 on DevNet; the 9 -> 5 proposal is $run_dir/proposal-group-size-5.json"
}

run_kind=$mode
[ "$check" = 0 ] || run_kind=check
start_run live "$run_kind"
trap remind EXIT
log "run $run_dir, mode $run_kind"
log "1/9 chain checks"
chain_params
log "group_size $group_size, max_escrows_per_epoch $max_escrows"
[ "$group_size" = 5 ] || stop "group_size is $group_size, the run starts at 5"
amount=${amount:-$(jget "$run_dir/params.json" params.devshard_escrow_params.min_amount)}
[[ $amount =~ ^[1-9][0-9]*$ ]] || die "escrow amount '$amount' is not a positive integer; pass --amount"
authority=$(chain /chain-api/cosmos/auth/v1beta1/module_accounts/gov \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["account"]["base_account"]["address"])') \
  || die "gov module account is unreadable"
last_passed=$(chain "$GOV/proposals?proposal_status=PROPOSAL_STATUS_PASSED&pagination.reverse=true&pagination.limit=1" \
  | python3 -c 'import json,sys; p=json.load(sys.stdin).get("proposals") or [{"id": 0}]; print(p[0]["id"])') \
  || die "proposals are unreadable"
deposit=$(chain "$GOV/params/deposit" | python3 -c 'import json,sys; print(json.load(sys.stdin)["params"]["min_deposit"][0]["amount"])') \
  || die "gov deposit is unreadable"
log "gov authority $authority, newest passed proposal $last_passed, deposit $deposit ngonka"
if [ "$gov" = grants ]; then
  [ -x "$INFERENCED" ] || die "inferenced not found: $INFERENCED"
  gov_address=$("$INFERENCED" keys show "$GOV_KEY" -a --keyring-backend test --keyring-dir "$GOV_HOME" </dev/null) \
    || die "run account $GOV_KEY is not in $GOV_HOME"
  read -r share guardians < <(grants_check) || die "vote grants are unreadable"
  read -ra voters <<<"$guardians"
  balance=$(chain "/chain-api/cosmos/bank/v1beta1/balances/$gov_address" | python3 -c \
    'import json,sys; print(sum(int(c["amount"]) for c in json.load(sys.stdin)["balances"] if c["denom"] == "ngonka"))') \
    || die "balance of $gov_address is unreadable"
  log "run account $gov_address: $balance ngonka; vote grants from ${#voters[@]} guardians, $share% of bonded tokens"
  while read -r guardian weight until; do
    log "  guardian $guardian, $weight of bonded tokens, $until"
  done < "$run_dir/grants.txt"
  gov_ok=1
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 40 else 1)' "$share" \
    || { gov_ok=0; stop "vote grants cover $share% of bonded tokens; a proposal needs more than 33.4%, the run wants 40%"; }
  [ "$balance" -ge $((2 * deposit)) ] \
    || { gov_ok=0; stop "the run account has $balance ngonka; two deposits need $((2 * deposit))"; }
  if [ "$check" = 1 ]; then
    if [ "$gov_ok" = 1 ]; then log "governance check: PASS"; exit 0; fi
    log "governance check: FAIL"
    exit 1
  fi
fi

log "2/9 gateway A admin API on $GATEWAY_HOST:127.0.0.1:$GATEWAY_PORT"
gateway_settings

log "3/9 window"
wait_window 220
free_places 2
proposal_file 9
proposal_file 5

if [ "$mode" = dry ]; then
  log "plan, all in epoch $epoch:"
  log "  escrow A of $amount ngonka at 5 slots, $REQUESTS requests into it"
  if [ "$gov" = grants ]; then
    log "  then the run account submits $run_dir/proposal-group-size-9.json and votes yes for the guardians"
  else
    log "  then the key holder submits $run_dir/proposal-group-size-9.json and votes; the run waits until P+$CHANGE_BY"
  fi
  log "  escrow B at 9 slots, $REQUESTS requests; settle A, then B, before P+$rotate_at"
  log "  then the 9 -> 5 proposal the same way; then gcheck escrow record and verdict"
  log "dry run: nothing sent; run with --run, add --wait to wait for the window"
  exit 0
fi

if [ "$yes" != 1 ]; then
  printf 'Run the group size change in epoch %s with escrows of %s ngonka on gateway A? Type yes: ' "$epoch" "$amount"
  read -r answer
  [ "$answer" = yes ] || die "not confirmed"
fi

log "4/9 escrow A at group_size 5"
create_escrow a
a_escrow=$escrow a_id=$id
escrow_on_chain a "$a_escrow" 5
send_requests a "$a_id"

log "5/9 proposal 5 -> 9"
if [ "$gov" = grants ]; then
  submit_and_vote 9 || { settle_escrow a "$a_id"; die "the 5 -> 9 proposal failed; escrow A settled"; }
  change=$proposal_id
else
  log "NOW: submit $run_dir/proposal-group-size-9.json and vote yes; waiting for group_size 9 until P+$CHANGE_BY"
fi
if ! wait_group_size 9 3600 "$CHANGE_BY"; then
  settle_escrow a "$a_id"
  die "group_size did not reach 9 by P+$CHANGE_BY; escrow A settled"
fi
changed=1
[ "$gov" = grants ] || change=$(newest_passed 9 "$last_passed") || true
log "change proposal ${change:-not found}"

log "6/9 escrow B at group_size 9"
create_escrow b
b_escrow=$escrow b_id=$id
escrow_on_chain b "$b_escrow" 9
send_requests b "$b_id"

log "7/9 settle A, then B"
settle_escrow a "$a_id"
a_tx=$settle_tx
settle_escrow b "$b_id"
b_tx=$settle_tx

log "8/9 rollback 9 -> 5"
proposal_file 5
rollback="" rolling=1
if [ "$gov" = wait ]; then
  log "NOW: submit $run_dir/proposal-group-size-5.json and vote yes; waiting for group_size 5"
elif submit_and_vote 5; then
  rollback=$proposal_id
fi
if [ "$gov" = grants ] && [ -z "$rollback" ]; then
  log "the 9 -> 5 proposal failed; recording without it"
elif wait_group_size 5 "$ROLLBACK_WAIT_S"; then
  rolled=1
  [ "$gov" = grants ] || rollback=$(newest_passed 5 "${change:-$last_passed}") || true
  log "rollback proposal ${rollback:-not found}"
else
  log "no rollback within $ROLLBACK_WAIT_S s; recording without it"
fi

log "9/9 gcheck escrow record and verdict"
set -- --a "$a_escrow" --b "$b_escrow" --attempt "a=$a_tx" --attempt "b=$b_tx"
[ -z "${change:-}" ] || set -- "$@" --change "$change"
[ -z "$rollback" ] || set -- "$@" --rollback "$rollback"
verdict=0
record_and_verdict "$@" || verdict=$?
log "done: A $a_escrow, B $b_escrow, change ${change:-?}, rollback ${rollback:-?}, verdict exit $verdict"
exit "$verdict"
