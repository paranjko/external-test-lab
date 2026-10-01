#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Execute the actual remote readiness predicate and continuity calculation.
awk '/^      height="/ {capture=1} capture {print} capture && /^      \(\( position/ {exit}' \
  "$ROOT/scripts/phase-ops.sh" | sed "s/))'; then/))/" >"$tmp/readiness.sh"
awk '/^step .*Capture the live topology/ {capture=1} capture {print} /^current_height=/ {exit}' \
  "$ROOT/scripts/phase-gateway-continuity.sh" >"$tmp/continuity.sh"
[[ -s "$tmp/readiness.sh" && -s "$tmp/continuity.sh" ]]

curl() {
  case "${!#}" in
    */status) printf '{"result":{"sync_info":{"latest_block_height":"%s"}}}\n' "$test_height" ;;
    */params) printf '%s\n' '{"params":{"epoch_params":{"epoch_length":"330","poc_stage_duration":"2","poc_exchange_duration":"2","poc_validation_delay":"2","poc_validation_duration":"2","set_new_validators_delay":"19"}}}' ;;
    */epoch_info) printf '{"latest_epoch":{"poc_start_block_height":"%s"}}\n' "$test_anchor" ;;
    */genesis) printf '%s\n' '{"result":{"genesis":{"chain_id":"test"}}}' ;;
    *) printf '%s\n' '{}' ;;
  esac
}
continuity_curl() { curl "$@"; }
step() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
genesis_sha256() { printf '%s\n' test; }

test_anchor=540800
for offset in 28 70 320; do
  test_height=$((test_anchor + offset))
  (source "$tmp/readiness.sh")
done
for offset in -1 0 27 321 330; do
  test_height=$((test_anchor + offset))
  if (source "$tmp/readiness.sh") >"$tmp/refused.out" 2>&1; then
    echo "readiness accepted unsafe offset=$offset" >&2
    exit 1
  fi
done

RUN="$tmp/evidence"
mkdir -p "$RUN"
export chain_base=https://chain.example
target_anchor=0
for test_anchor in 540800 541130; do
  test_height=$((test_anchor + 70))
  # shellcheck disable=SC1091
  source "$tmp/continuity.sh"
  [[ "$target_anchor" == "$((test_anchor + 330))" ]]
done
test_height=$((test_anchor + 330))
if (source "$tmp/continuity.sh") >"$tmp/refused.out" 2>&1; then
  echo 'continuity accepted a stale epoch anchor' >&2
  exit 1
fi
printf 'PASS gateway readiness and continuity follow the actual PoC anchor\n'
