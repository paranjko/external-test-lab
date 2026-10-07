#!/usr/bin/env bash
# One group_size proposal from the run account: the guardian key holders vote on their side, the script waits for
# the result and checks that the proposal passed, group_size is SIZE and every other parameter kept its value.
# Without --submit it only reads: the run account, its balance and the proposal file.
# shellcheck disable=SC2034,SC2154  # variables are set by the lib.sh functions
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

mode=dry yes=0 size=""
usage() { echo "usage: $0 SIZE [--submit] [--yes]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --submit) mode=run ;;
    --yes) yes=1 ;;
    [1-9]|[1-9][0-9]) [ -z "$size" ] || usage; size=$1 ;;
    *) usage ;;
  esac
  shift
done
[ -n "$size" ] || usage

start_run gov "$mode"
log "run $run_dir, group_size $size, mode $mode"
chain_params
gov_params
log "group_size is $group_size now; the proposal sets $size$([ "$group_size" = "$size" ] && echo ', no change')"
ready=1
gov_account 1 || ready=0
proposal_file "$size"

if [ "$mode" = dry ]; then
  if [ "$ready" = 1 ]; then log "check: PASS; nothing sent, add --submit"; exit 0; fi
  log "check: FAIL; nothing sent"
  exit 1
fi
[ "$ready" = 1 ] || die "the run account cannot pay the deposit"

if [ "$yes" != 1 ]; then
  printf 'Submit the group_size %s proposal from %s? Type yes: ' "$size" "$gov_address"
  read -r answer
  [ "$answer" = yes ] || die "not confirmed"
fi
if gov_change "$size"; then
  log "accepted: proposal $proposal_id"
  exit 0
fi
log "not accepted${proposal_id:+: proposal $proposal_id}"
exit 1
