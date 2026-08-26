#!/usr/bin/env bash
set -Eeuo pipefail

# Resumable, single-Host upgrade observation. The state file is immutable in
# target identity and mutable only in the last observed lifecycle state.
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 || -n "${UPGRADE_FROM_PROFILE:-}" ]] || die 'host upgrade watch requires an upgrade-capable release profile'

NODE="$(node_name "${1:-}")"
PROPOSAL_ID="${2:-}"
[[ "$PROPOSAL_ID" =~ ^[1-9][0-9]*$ ]] || die 'usage: host upgrade watch <ssh-alias> <proposal-id>'
STATE_FILE="$STATE/upgrade/$NODE-$PROPOSAL_ID.env"
[[ -s "$STATE_FILE" ]] || die "no prepared state for $NODE proposal $PROPOSAL_ID; run host upgrade prepare first"
grep -qx "node=$NODE" "$STATE_FILE" && grep -qx "proposal_id=$PROPOSAL_ID" "$STATE_FILE" \
  || die 'prepared Host upgrade state belongs to another Host or proposal'
initial_state="$(awk -F= '$1 == "state" {print $2; exit}' "$STATE_FILE")"
case "$initial_state" in
  PREPARED|WAITING_HEIGHT|ACTIVATED|SYNCED) ;;
  VALIDATOR_EFFECTIVE)
    printf 'READY %s is already VALIDATOR_EFFECTIVE for immutable proposal %s\n' "$NODE" "$PROPOSAL_ID"
    exit 0
    ;;
  FAILED) die 'prepared Host upgrade state is FAILED; inspect its evidence before explicitly preparing the same immutable target again' ;;
  *) die 'prepared Host upgrade state is malformed or cannot be resumed safely' ;;
esac

record_phase_profile "host-upgrade-watch-$NODE"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/host-upgrade-watch-$NODE-$PROPOSAL_ID"
export EVIDENCE_PHASE_NAME="host-upgrade-watch-$NODE"
mkdir -p "$RUN"
install_evidence_exit_trap 'Host upgrade watch'
CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-https://$GENESIS_PUBLIC_HOST}"
CHAIN_BASE="${CHAIN_BASE%/}"
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" || die 'cannot read canonical Genesis'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
grep -qx "genesis_sha256=$GENESIS_SHA256" "$STATE_FILE" || die 'prepared state belongs to a different Genesis lineage'
CHAIN_ID="$(jq -er .chain_id "$RUN/genesis.json")"
write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256"
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-api/cosmos/gov/v1/proposals/$PROPOSAL_ID" >"$RUN/proposal.json"
plan_height="$("$ROOT/scripts/verify-upgrade-proposal-binding.sh" "$RUN/proposal.json" "v$GONKA_RELEASE" \
  "$INFERENCED_UPGRADE_URL" "$INFERENCED_UPGRADE_SHA256" "$DAPI_UPGRADE_URL" "$DAPI_UPGRADE_SHA256")" \
  || die "proposal $PROPOSAL_ID does not match this immutable target"
grep -qx "plan_height=$plan_height" "$STATE_FILE" || die 'prepared state has a different activation height'

write_state() {
  local state="$1"
  sed -i -E "s/^state=.*/state=$state/" "$STATE_FILE"
  printf 'observed_at=%s\n' "$(date -u +%FT%TZ)" >>"$STATE_FILE"
}
write_receipt() {
  local state="$1" reason="$2"
  jq -n --arg state "$state" --arg reason "$reason" --arg node "$NODE" --arg proposal_id "$PROPOSAL_ID" \
    --argjson plan_height "$plan_height" --arg genesis_sha256 "$GENESIS_SHA256" \
    '{schema_version:1,state:$state,reason:$reason,node:$node,proposal_id:$proposal_id,
      plan_height:$plan_height,genesis_sha256:$genesis_sha256}' >"$RUN/receipt.json"
}

IDENTITY="$(node_identity_file "$NODE")"
[[ -s "$IDENTITY" ]] || die "$NODE has no local public consensus identity"
VALIDATOR_KEY="$(jq -er .consensus_pubkey "$IDENTITY")"
NODE_URL="$(node_url "$NODE")"
watch_timeout="${GDC_HOST_UPGRADE_WATCH_TIMEOUT_SECONDS:-}"
watch_poll="${GDC_HOST_UPGRADE_WATCH_POLL_SECONDS:-}"
[[ "$watch_timeout" =~ ^[1-9][0-9]*$ && "$watch_poll" =~ ^[1-9][0-9]*$ ]] \
  || die 'release profile must define positive Host upgrade watch bounds'
deadline=$((SECONDS + watch_timeout))
while (( SECONDS < deadline )); do
  chain_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" 2>/dev/null || true)"
  height="$(jq -r '.result.sync_info.latest_block_height // 0 | tonumber' <<<"$chain_status" 2>/dev/null || printf 0)"
  if (( height < plan_height )); then
    write_state WAITING_HEIGHT
    printf 'WAIT  %s state=WAITING_HEIGHT height=%s target=%s remaining=%s\n' "$NODE" "$height" "$plan_height" "$((deadline - SECONDS))"
    sleep "$watch_poll"; continue
  fi
  write_state ACTIVATED
  versions="$(curl -fsS --connect-timeout 5 --max-time 15 "$NODE_URL/v1/versions" 2>/dev/null || true)"
  if ! jq -e --arg version "$GONKA_RELEASE" --arg commit "$GONKA_COMMIT" '(.node_version.version | ltrimstr("v")) == $version and .node_version.commit == $commit' <<<"$versions" >/dev/null 2>&1; then
    printf 'WAIT  %s state=ACTIVATED target runtime not yet public\n' "$NODE"
    sleep "$watch_poll"; continue
  fi
  node_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$NODE_URL/chain-rpc/status" 2>/dev/null || true)"
  node_height="$(jq -r '.result.sync_info.latest_block_height // 0 | tonumber' <<<"$node_status" 2>/dev/null || printf 0)"
  catching_up="$(jq -r '.result.sync_info.catching_up // true' <<<"$node_status" 2>/dev/null || printf true)"
  lag=$((height - node_height)); (( lag >= 0 )) || lag=0
  if [[ "$catching_up" != false || "$lag" -gt "${GDC_MAX_NODE_LAG_BLOCKS:-5}" ]]; then
    printf 'WAIT  %s state=ACTIVATED sync height=%s lag=%s catching_up=%s\n' "$NODE" "$node_height" "$lag" "$catching_up"
    sleep "$watch_poll"; continue
  fi
  write_state SYNCED
  curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/validators?per_page=100" >"$RUN/validators.json"
  if jq -e --arg key "$VALIDATOR_KEY" '.result.validators | any(.[]; .pub_key.value == $key and (.voting_power | tonumber) > 0)' "$RUN/validators.json" >/dev/null; then
    write_state VALIDATOR_EFFECTIVE
    write_receipt VALIDATOR_EFFECTIVE 'target runtime, synchronization, and positive consensus voting power observed'
    cat >"$RUN/verdict.md" <<EOF
# Host upgrade watch: PASS

$NODE reached target runtime, synchronized after activation height $plan_height,
and restored positive consensus voting power. No other Host was changed.
EOF
    printf 'PASS Host upgrade evidence: %s\n' "$RUN"; exit 0
  fi
  printf 'WAIT  %s state=SYNCED validator is not effective\n' "$NODE"
  sleep "$watch_poll"
done
write_state FAILED
write_receipt FAILED 'bounded upgrade watch deadline expired before validator effectiveness'
cat >"$RUN/verdict.md" <<EOF
# Host upgrade watch: INCONCLUSIVE

$NODE did not reach VALIDATOR_EFFECTIVE before the deadline. Resume the same
command; do not reset Genesis or replace the immutable proposal.
EOF
printf 'INCONCLUSIVE Host upgrade evidence: %s\n' "$RUN" >&2
exit 2
