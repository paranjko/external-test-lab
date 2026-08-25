#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only observer. Ordinary PoC, a local ML completion, or a current
# ACTIVE participant can never substitute for this phase sequence.
source "$(dirname "$0")/lib.sh"

CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-}"
[[ "$CHAIN_BASE" =~ ^https://[A-Za-z0-9.-]+$ ]] \
  || die 'GDC_CHAIN_PUBLIC_BASE must be an HTTPS public chain endpoint'
CHAIN_BASE="${CHAIN_BASE%/}"
RELEASE_PROFILE="${GDC_RELEASE_PROFILE:-v2026.07.23}"
PROFILE_FILE="$ROOT/profiles/releases/$RELEASE_PROFILE.lock"
[[ -s "$PROFILE_FILE" ]] || die "unknown release profile: $RELEASE_PROFILE"
profile_value() { awk -F= -v key="$1" '$1 == key { print $2; exit }' "$PROFILE_FILE"; }
EPOCHS="$(profile_value GDC_CPOC_PROBE_EPOCHS)"
TIMEOUT="$(profile_value GDC_CPOC_PROBE_TIMEOUT_SECONDS)"
POLL="$(profile_value GDC_CPOC_PROBE_POLL_SECONDS)"
[[ "$EPOCHS" =~ ^[1-9][0-9]*$ && "$TIMEOUT" =~ ^[1-9][0-9]*$ && "$POLL" =~ ^[1-9][0-9]*$ ]] \
  || die 'release profile must define positive confirmation-PoC probe bounds'

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/confirmation-poc"
export EVIDENCE_PHASE_NAME=confirmation-poc
TOPOLOGY="$STATE/lineage/current-topology.json"
mkdir -p "$RUN"
VERDICT_WRITTEN=false
GENESIS_SHA256=UNAVAILABLE

write_verdict() {
  local verdict="$1" reason="$2"
  jq -n --arg verdict "$verdict" --arg reason "$reason" --arg chain_base "$CHAIN_BASE" \
    --arg run_id "${GDC_RUN_ID:-manual}" --arg chain_id "${CHAIN_ID:-UNAVAILABLE}" \
    --arg genesis_sha256 "$GENESIS_SHA256" --arg release_profile "$RELEASE_PROFILE" \
    --arg release_profile_sha256 "${RELEASE_PROFILE_SHA256:-UNAVAILABLE}" \
    --argjson epochs "$EPOCHS" \
    '{schema_version:1,verdict:$verdict,reason:$reason,run_id:$run_id,chain_id:$chain_id,
      chain_base:$chain_base,genesis_sha256:$genesis_sha256,release_profile:$release_profile,
      release_profile_sha256:$release_profile_sha256,probe_epochs:$epochs}' \
    >"$RUN/receipt.json"
  cat >"$RUN/verdict.md" <<EOF
# Confirmation-PoC: $verdict

$reason
EOF
  VERDICT_WRITTEN=true
}
on_exit() {
  local rc=$?
  if (( rc != 0 )) && [[ "$VERDICT_WRITTEN" == false ]]; then
    write_verdict INCONCLUSIVE "observer stopped with exit code $rc before a final confirmation-PoC verdict"
  fi
}
trap on_exit EXIT
blocked() { write_verdict BLOCKED "$1"; printf 'BLOCKED %s; evidence: %s\n' "$1" "$RUN" >&2; exit 3; }
failed() { write_verdict FAIL "$1"; printf 'FAIL %s; evidence: %s\n' "$1" "$RUN" >&2; exit 1; }
inconclusive() { write_verdict INCONCLUSIVE "$1"; printf 'INCONCLUSIVE %s; evidence: %s\n' "$1" "$RUN" >&2; exit 2; }

capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" \
  || inconclusive 'cannot capture canonical Genesis'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
CHAIN_ID="$(jq -er .chain_id "$RUN/genesis.json")"
write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256"
RELEASE_PROFILE_SHA256="$(awk -F= '$1 == "release_profile_sha256" {print $2; exit}' "$(run_manifest_path)")"
[[ -s "$TOPOLOGY" ]] || blocked 'current-lineage topology is absent; import sanitized JOIN receipts and render it before observing confirmation-PoC'
jq -e --arg hash "$GENESIS_SHA256" '.genesis_sha256 == $hash and (.participants | length == 5)' "$TOPOLOGY" >/dev/null \
  || blocked 'current-lineage topology is incomplete or belongs to a different Genesis lineage'

jq -e '
  .app_state.inference.params as $params
  | $params.poc_params.confirmation_poc_v2_enabled == true
  and ($params.confirmation_poc_params.expected_confirmations_per_epoch | tonumber) > 0
  and ($params.confirmation_poc_params.upgrade_protection_window | tonumber) > 0
' "$RUN/genesis.json" >/dev/null \
  || blocked 'canonical Genesis has confirmation-PoC disabled or lacks a positive protection window'

epoch_url="$CHAIN_BASE/chain-api/productscience/inference/inference/get_current_epoch"
event_url="$CHAIN_BASE/chain-api/productscience/inference/inference/active_confirmation_poc_event"
events_url="$CHAIN_BASE/chain-api/productscience/inference/inference/confirmation_poc_events"
group_url="$CHAIN_BASE/chain-api/productscience/inference/inference/current_epoch_group_data"
curl -fsS --connect-timeout 5 --max-time 15 "$epoch_url" >"$RUN/initial-epoch.json" \
  || inconclusive 'cannot read initial confirmation-PoC epoch'
initial_epoch="$(jq -er '.epoch | tonumber' "$RUN/initial-epoch.json")"
(( initial_epoch > 1 )) || inconclusive 'confirmation-PoC cannot begin before epoch index 2'
deadline_epoch=$((initial_epoch + EPOCHS))
deadline_seconds=$((SECONDS + TIMEOUT))
printf '[]' >"$RUN/observations.json"

while (( SECONDS < deadline_seconds )); do
  curl -fsS --connect-timeout 5 --max-time 15 "$epoch_url" >"$RUN/current-epoch.json" \
    || inconclusive 'cannot read current confirmation-PoC epoch'
  epoch="$(jq -er '.epoch | tonumber' "$RUN/current-epoch.json")"
  curl -fsS --connect-timeout 5 --max-time 15 "$event_url" >"$RUN/active-event-$epoch.json" \
    || inconclusive 'cannot read active confirmation-PoC event'
  curl -fsS --connect-timeout 5 --max-time 15 "$events_url/$epoch" >"$RUN/events-$epoch.json" \
    || inconclusive 'cannot read confirmation-PoC events'
  curl -fsS --connect-timeout 5 --max-time 15 "$group_url" >"$RUN/epoch-group-$epoch.json" \
    || inconclusive 'cannot read current epoch group'
  trigger_height="$(jq -n --slurpfile active "$RUN/active-event-$epoch.json" --slurpfile events "$RUN/events-$epoch.json" '
    [[$active[0], $events[0]] | .. | objects
      | (.trigger_height? // .start_block_height? // .poc_start_block_height? // empty)
      | tonumber?] | first // 0
  ')"
  jq --arg observed_at "$(date -u +%FT%TZ)" --argjson epoch "$epoch" --argjson trigger_height "$trigger_height" \
    --slurpfile active "$RUN/active-event-$epoch.json" --slurpfile events "$RUN/events-$epoch.json" \
    --slurpfile group "$RUN/epoch-group-$epoch.json" \
    '. + [{observed_at:$observed_at,epoch:$epoch,trigger_height:$trigger_height,active_event:$active[0],events:$events[0],epoch_group:$group[0]}]' \
    "$RUN/observations.json" >"$RUN/observations.tmp"
  mv "$RUN/observations.tmp" "$RUN/observations.json"

  jq '[.[] | .epoch as $epoch | .. | objects | .phase? | strings
    | select(. == "CONFIRMATION_POC_GRACE_PERIOD" or . == "CONFIRMATION_POC_GENERATION"
      or . == "CONFIRMATION_POC_VALIDATION" or . == "CONFIRMATION_POC_COMPLETED")
    | {epoch:$epoch,phase:.}]' "$RUN/observations.json" >"$RUN/phase-sequence.json"
  phases_ok=false
  jq -e '
    def position($phase): first(to_entries[] | select(.value.phase == $phase) | .key) // -1;
    (position("CONFIRMATION_POC_GRACE_PERIOD")) as $grace
    | (position("CONFIRMATION_POC_GENERATION")) as $generation
    | (position("CONFIRMATION_POC_VALIDATION")) as $validation
    | (position("CONFIRMATION_POC_COMPLETED")) as $completed
    | $grace >= 0 and $generation > $grace and $validation > $generation and $completed > $validation
  ' "$RUN/phase-sequence.json" >/dev/null 2>&1 && phases_ok=true
  completed_epoch="$(jq -r '[.[] | .. | objects | select(.phase? == "CONFIRMATION_POC_COMPLETED") | (.epoch_index? // .epoch? // 0 | tonumber)] | max // 0' "$RUN/observations.json")"
  nonzero=false
  jq -e '
    [.. | objects | (.confirmation_weight? // empty) | tonumber | select(. > 0)] | length > 0
  ' "$RUN/observations.json" >/dev/null 2>&1 && nonzero=true
  applied=false
  if (( completed_epoch > 0 )); then
    jq -e --argjson completed "$completed_epoch" '
      any(.[]; (.epoch > $completed) and ([ .epoch_group.epoch_group_data.validation_weights[]?
        | (.confirmation_weight? // 0 | tonumber) | select(. > 0) ] | length > 0))
    ' "$RUN/observations.json" >/dev/null 2>&1 && applied=true
  fi
  trigger_observed=false
  jq -e '[.[].trigger_height | tonumber | select(. > 0)] | length > 0' "$RUN/observations.json" >/dev/null 2>&1 && trigger_observed=true
  if [[ "$phases_ok" == true && "$trigger_observed" == true && "$nonzero" == true && "$applied" == true ]]; then
    jq -n --argjson initial_epoch "$initial_epoch" --argjson completed_epoch "$completed_epoch" \
      --slurpfile sequence "$RUN/phase-sequence.json" --slurpfile observations "$RUN/observations.json" \
      '{schema_version:1,initial_epoch:$initial_epoch,completed_epoch:$completed_epoch,
        phase_sequence:$sequence[0],trigger_heights:[$observations[0][].trigger_height],
        application_observed_in_following_epoch:true}' >"$RUN/confirmation-poc-summary.json"
    write_verdict PASS "observed GRACE_PERIOD, GENERATION, VALIDATION, and COMPLETED in order with trigger-height evidence, non-zero confirmation evidence, and application in a following epoch"
    printf 'PASS confirmation-PoC evidence: %s\n' "$RUN"
    exit 0
  fi
  if [[ "$phases_ok" == true && "$nonzero" != true ]]; then
    failed 'confirmation-PoC completed with fleet-wide zero confirmation weight'
  fi
  if (( epoch >= deadline_epoch )); then
    inconclusive "confirmation-PoC deadline epoch $deadline_epoch reached (phase sequence is incomplete or out of order: $phases_ok; trigger_height=$trigger_observed nonzero=$nonzero applied=$applied); ordinary PoC and ML completion are not evidence"
  fi
  printf 'WAIT  confirmation-PoC epoch=%s/%s phases=%s trigger_height=%s nonzero=%s applied=%s\n' "$epoch" "$deadline_epoch" "$phases_ok" "$trigger_observed" "$nonzero" "$applied"
  sleep "$POLL"
done
inconclusive "confirmation-PoC wall-clock deadline reached before epoch $deadline_epoch"
