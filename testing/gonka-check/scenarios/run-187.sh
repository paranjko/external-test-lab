#!/usr/bin/env bash
# Live run of a group size change on gateway A: escrow A at 5 slots, the 5 -> 9 proposal, escrow B at 9 slots, both
# settled by hand in the same epoch, the 9 -> 5 rollback, then gcheck escrow record and verdict. The run account
# submits each proposal, the guardian key holders vote, and the run checks the result (gov_change in lib.sh);
# with --gov wait it only writes the proposal files, says when, and waits for group_size. --check-gov reads only
# the run account and its balance.
# shellcheck disable=SC2034,SC2154  # variables are set by the lib.sh functions
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

CHANGE_BY=${CHANGE_BY:-200}
ROLLBACK_WAIT_S=${ROLLBACK_WAIT_S:-1800}

mode=dry wait=0 yes=0 amount="" gov=submit check=0
usage() { echo "usage: $0 [--run] [--yes] [--wait] [--amount NGONKA] [--gov submit|wait] | --check-gov" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --run) mode=run ;;
    --yes) yes=1 ;;
    --wait) wait=1 ;;
    --amount) [ $# -ge 2 ] || usage; amount=$2; shift ;;
    --gov) [ $# -ge 2 ] && [[ $2 =~ ^(submit|wait)$ ]] || usage; gov=$2; shift ;;
    --check-gov) check=1 ;;
    *) usage ;;
  esac
  shift
done
[ "$check" = 0 ] || { [ "$mode" = dry ] && [ "$gov" = submit ]; } || usage

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

# rollback_after_stop: once the last proposal is final, the 9 -> 5 proposal if group_size is 9.
rollback_after_stop() {
  [ -z "$proposal_id" ] || proposal_final "$proposal_id" >/dev/null || true
  chain_params
  [ "$group_size" = 9 ] || { log "group_size is $group_size after the stop, nothing to roll back"; return 0; }
  log "group_size is 9 after the stop: proposal 9 -> 5"
  gov_change 5
}

changed=0 rolled=0 rolling=0 proposal_id=""
remind() {
  [ "$changed" = 1 ] && [ "$rolled" = 0 ] || return 0
  if [ "$gov" = submit ] && [ "$rolling" = 0 ] && (rollback_after_stop); then return 0; fi
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
gov_params
last_passed=$(chain "$GOV/proposals?proposal_status=PROPOSAL_STATUS_PASSED&pagination.reverse=true&pagination.limit=1" \
  | python3 -c 'import json,sys; p=json.load(sys.stdin).get("proposals") or [{"id": 0}]; print(p[0]["id"])') \
  || die "proposals are unreadable"
log "gov authority $authority, newest passed proposal $last_passed, deposit $deposit ngonka"
if [ "$gov" = submit ]; then
  if ! gov_account 2; then
    [ "$check" = 0 ] || { log "governance check: FAIL"; exit 1; }
    stop "the run account cannot pay two deposits"
  fi
  [ "$check" = 0 ] || { log "governance check: PASS; the guardian key holders vote on their side"; exit 0; }
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
  if [ "$gov" = submit ]; then
    log "  then the run account submits the 5 -> 9 proposal, the guardians vote, the run checks the result"
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
if [ "$gov" = submit ]; then
  changed=1
  gov_change 9 || { settle_escrow a "$a_id"; die "the 5 -> 9 proposal was not accepted; escrow A settled"; }
  change=$proposal_id
else
  log "NOW: submit $run_dir/proposal-group-size-9.json and vote yes; waiting for group_size 9 until P+$CHANGE_BY"
fi
if ! wait_group_size 9 3600 "$CHANGE_BY"; then
  settle_escrow a "$a_id"
  die "group_size did not reach 9 by P+$CHANGE_BY; escrow A settled"
fi
changed=1
[ "$gov" = submit ] || change=$(newest_passed 9 "$last_passed") || true
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
rollback="" rolling=1
if [ "$gov" = wait ]; then
  proposal_file 5
  log "NOW: submit $run_dir/proposal-group-size-5.json and vote yes; waiting for group_size 5"
elif gov_change 5; then
  rollback=$proposal_id
fi
if [ "$gov" = submit ] && [ -z "$rollback" ]; then
  log "the 9 -> 5 proposal was not accepted; recording without it"
elif wait_group_size 5 "$ROLLBACK_WAIT_S"; then
  rolled=1
  [ "$gov" = submit ] || rollback=$(newest_passed 5 "${change:-$last_passed}") || true
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
