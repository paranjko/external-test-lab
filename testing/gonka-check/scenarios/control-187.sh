#!/usr/bin/env bash
# Control run at group size 5 on gateway A: one escrow created and settled through the gateway admin API, then
# gcheck escrow record and verdict. Reads only unless --run; the gateway keys never leave the gateway host.
# shellcheck disable=SC2034,SC2154  # variables are set by the lib.sh functions
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

mode=dry wait=0 yes=0 amount=""
usage() { echo "usage: $0 [--run] [--yes] [--wait] [--amount NGONKA]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --run) mode=run ;;
    --yes) yes=1 ;;
    --wait) wait=1 ;;
    --amount) [ $# -ge 2 ] || usage; amount=$2; shift ;;
    *) usage ;;
  esac
  shift
done

start_run control "$mode"
log "run $run_dir, mode $mode"
log "1/8 chain checks; gcheck preflight reads gateway A through the public edge and is kept for the record only"
set +e
"$GCHECK" escrow preflight --source devnet --gateway a --from 5 --need 1 2>&1 | tee -a "$run_dir/$run_name.log"
log "gcheck preflight exit ${PIPESTATUS[0]}; the run does not depend on it"
set -e
chain_params
log "group_size $group_size, max_escrows_per_epoch $max_escrows"
[ "$group_size" = 5 ] || stop "group_size is $group_size, the control runs at 5"

log "2/8 gateway A admin API on $GATEWAY_HOST:127.0.0.1:$GATEWAY_PORT"
gateway_settings
amount=${amount:-$rot_amount}
[[ $amount =~ ^[1-9][0-9]*$ ]] || die "escrow amount '$amount' is not a positive integer; pass --amount"

log "3/8 window"
wait_window 60
free_places 1

if [ "$mode" = dry ]; then
  log "plan: create an escrow of $amount ngonka for $model on gateway A, send $REQUESTS requests to /devshard/<id>,"
  log "      settle it before P+$rotate_at, then gcheck escrow record --a <id> --attempt a=<tx> and verdict"
  log "dry run: nothing sent; run with --run, add --wait to wait for the window"
  exit 0
fi

if [ "$yes" != 1 ]; then
  printf 'Create an escrow of %s ngonka for %s on gateway A in epoch %s and settle it? Type yes: ' \
    "$amount" "$model" "$epoch"
  read -r answer
  [ "$answer" = yes ] || die "not confirmed"
fi

log "4/8 create"
create_escrow a
log "5/8 escrow on chain"
escrow_on_chain a "$escrow" 5
log "6/8 $REQUESTS requests into escrow $escrow"
send_requests a "$id"
log "7/8 settle"
settle_escrow a "$id"
log "8/8 gcheck escrow record and verdict"
verdict=0
record_and_verdict --a "$escrow" --attempt "a=$settle_tx" || verdict=$?
log "done: escrow $escrow, create $create_tx, settle $settle_tx, verdict exit $verdict"
exit "$verdict"
