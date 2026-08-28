#!/usr/bin/env bash
set -Eeuo pipefail

# Fast, fixture-only regression coverage for the false positives addressed by
# Gate B. Live acceptance remains the responsibility of the public observer.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

topology="$tmp/topology.json"
printf '%s\n' '{"schema_version":1,"chain_id":"gonka-devnet-community","genesis_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","participants":[{"address":"gonka1one","validator_key":"key-one","runtime_id":"qwen3-0.6b:gonka1one","public_host":"node1.example","poc_participant_weight":1,"poc_accepted_weight_sum":5,"poc_committed_total":5,"poc_distribution_tx_code":0},{"address":"gonka1two","validator_key":"key-two","runtime_id":"qwen3-0.6b:gonka1two","public_host":"node2.example","poc_participant_weight":1,"poc_accepted_weight_sum":5,"poc_committed_total":5,"poc_distribution_tx_code":0}]}' >"$topology"
jq -e --arg hash aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '
  .genesis_sha256 == $hash and ([.participants[].runtime_id] | unique | length == 2)
  and all(.participants[]; (.poc_distribution_tx_code | tonumber) == 0
    and (.poc_accepted_weight_sum | tonumber) == (.poc_committed_total | tonumber))
' "$topology" >/dev/null
if jq -e --arg hash bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '.genesis_sha256 == $hash' "$topology" >/dev/null; then
  echo 'stale Genesis lineage was accepted' >&2
  exit 1
fi
if jq -e '.participants[0].poc_distribution_tx_code = 7 | all(.participants[]; (.poc_distribution_tx_code | tonumber) == 0)' "$topology" >/dev/null; then
  echo 'rejected PoC transaction was accepted' >&2
  exit 1
fi

observations="$tmp/cpoc-observations.json"
printf '%s\n' '[{"epoch":7,"trigger_height":700,"active_event":{"event":{"phase":"CONFIRMATION_POC_GRACE_PERIOD"}},"events":{"events":[{"phase":"CONFIRMATION_POC_GENERATION"},{"phase":"CONFIRMATION_POC_VALIDATION"},{"phase":"CONFIRMATION_POC_COMPLETED","epoch_index":"7","confirmation_weight":"3"}]},"epoch_group":{"epoch_group_data":{"validation_weights":[]}}},{"epoch":8,"trigger_height":800,"active_event":{"event":{"phase":"CONFIRMATION_POC_COMPLETED"}},"events":{"events":[]},"epoch_group":{"epoch_group_data":{"validation_weights":[{"confirmation_weight":"3"}]}}}]' >"$observations"
jq -e '
  [.. | objects | .phase? | strings] as $phases
  | ($phases | index("CONFIRMATION_POC_GRACE_PERIOD") != null)
  and ($phases | index("CONFIRMATION_POC_GENERATION") != null)
  and ($phases | index("CONFIRMATION_POC_VALIDATION") != null)
  and ($phases | index("CONFIRMATION_POC_COMPLETED") != null)
' "$observations" >/dev/null
jq -e '[.. | objects | (.confirmation_weight? // empty) | tonumber | select(. > 0)] | length > 0' "$observations" >/dev/null
jq -e '[.[].trigger_height | tonumber | select(. > 0)] | length > 0' "$observations" >/dev/null
phase_sequence_ok() {
  jq -e '
    [.[] | .epoch as $epoch | .. | objects | .phase? | strings
      | select(. == "CONFIRMATION_POC_GRACE_PERIOD" or . == "CONFIRMATION_POC_GENERATION"
        or . == "CONFIRMATION_POC_VALIDATION" or . == "CONFIRMATION_POC_COMPLETED")
      | {epoch:$epoch,phase:.}]
    | def position($phase): first(to_entries[] | select(.value.phase == $phase) | .key) // -1;
      (position("CONFIRMATION_POC_GRACE_PERIOD")) as $grace
      | (position("CONFIRMATION_POC_GENERATION")) as $generation
      | (position("CONFIRMATION_POC_VALIDATION")) as $validation
      | (position("CONFIRMATION_POC_COMPLETED")) as $completed
      | $grace >= 0 and $generation > $grace and $validation > $generation and $completed > $validation
  ' "$1" >/dev/null
}
phase_sequence_ok "$observations"
reversed="$tmp/cpoc-reversed.json"
jq '.[0].events.events |= [.[1], .[0], .[2]]' "$observations" >"$reversed"
if phase_sequence_ok "$reversed"; then
  echo 'out-of-order confirmation-PoC phases were accepted' >&2
  exit 1
fi
jq -e '
  any(.[]; (.epoch > 7) and ([ .epoch_group.epoch_group_data.validation_weights[]?
    | (.confirmation_weight? // 0 | tonumber) | select(. > 0) ] | length > 0))
' "$observations" >/dev/null
if jq -e '[.. | objects | (.confirmation_weight? // empty) | tonumber | select(. > 0)] | length > 0' \
  <(jq 'walk(if type == "object" and has("confirmation_weight") then .confirmation_weight = "0" else . end)' "$observations") >/dev/null; then
  echo 'fleet-wide zero confirmation weight was accepted' >&2
  exit 1
fi

grep -Fq 'Gate B requires the externally attested Gate A receipt' "$ROOT/scripts/phase-public-network-verify.sh"
grep -Fq '[[ ! -s "$RECEIPT_ROOT/receipt.json" ]] || receipts+=' "$ROOT/scripts/render-current-lineage-topology.sh"
grep -Fq '# JOIN acceptance: PASS' "$ROOT/scripts/phase-public-network-verify.sh"
grep -Fq 'issue #28 external JOIN receipt' "$ROOT/scripts/phase-public-network-verify.sh"
grep -Fq 'write_phase_lineage' "$ROOT/scripts/phase-public-network-verify.sh"
! grep -Fq 'credential from the public bootstrap' "$ROOT/scripts/phase-public-network-verify.sh"
! grep -Fq 'different Genesis lineage' "$ROOT/scripts/phase-confirmation-poc.sh"
grep -Fq 'resolve_expected_network_participants "$RUN/expected-participants.json"' "$ROOT/scripts/phase-confirmation-poc.sh"
! grep -Fq 'current-lineage topology is absent; import sanitized JOIN receipts' "$ROOT/scripts/phase-confirmation-poc.sh"
grep -Fq 'if [[ "$COMMAND" == confirmation-poc ]]; then' "$ROOT/gdc.sh"
grep -Fq 'use_network_owner_data_home' "$ROOT/gdc.sh"
grep -Fq 'write_phase_lineage' "$ROOT/scripts/phase-confirmation-poc.sh"
grep -Fq 'phase sequence is incomplete or out of order' "$ROOT/scripts/phase-confirmation-poc.sh"
grep -Fq 'trigger_height' "$ROOT/scripts/phase-confirmation-poc.sh"
grep -Fq 'GDC_UPGRADE_MIN_LEAD_BLOCKS' "$ROOT/scripts/phase-host-upgrade-prepare.sh"
grep -Fq 'GDC_HOST_UPGRADE_WATCH_TIMEOUT_SECONDS' "$ROOT/profiles/releases/v2026.08.06.lock"
grep -Fq 'GDC_GATE_B_PROGRESS_TIMEOUT_SECONDS' "$ROOT/profiles/releases/v2026.07.23.lock"
grep -Fq 'GDC_MAX_NODE_LAG_BLOCKS' "$ROOT/profiles/releases/v2026.07.23.lock"
grep -Fq 'PREPARED|WAITING_HEIGHT|ACTIVATED|SYNCED|VALIDATOR_EFFECTIVE' "$ROOT/scripts/phase-host-upgrade-watch.sh"
grep -Fq 'require_host_upgrade_state_target' "$ROOT/scripts/phase-host-upgrade-watch.sh"
grep -Fq 'No other Host was changed' "$ROOT/scripts/phase-host-upgrade-watch.sh"

# State validation rejects cross-profile resume even if state was VALIDATOR_EFFECTIVE
state_fixture="$tmp/state.env"
cat >"$state_fixture" <<'EOF'
state=VALIDATOR_EFFECTIVE
node=node1
proposal_id=1
release_profile=v2026.08.25-rc.0
profile_hash=1111111111111111111111111111111111111111111111111111111111111111
inferenced_sha256=2222222222222222222222222222222222222222222222222222222222222222
dapi_sha256=3333333333333333333333333333333333333333333333333333333333333333
EOF
validate_watch_state() {
  local file="$1" node="$2" proposal="$3" profile="$4" p_hash="$5" inf_hash="$6" dapi_hash="$7"
  grep -qx "node=$node" "$file" \
    && grep -qx "proposal_id=$proposal" "$file" \
    && grep -qx "release_profile=$profile" "$file" \
    && grep -qx "profile_hash=$p_hash" "$file" \
    && grep -qx "inferenced_sha256=$inf_hash" "$file" \
    && grep -qx "dapi_sha256=$dapi_hash" "$file"
}
validate_watch_state "$state_fixture" node1 1 v2026.08.25-rc.0 1111111111111111111111111111111111111111111111111111111111111111 2222222222222222222222222222222222222222222222222222222222222222 3333333333333333333333333333333333333333333333333333333333333333
! validate_watch_state "$state_fixture" node1 1 v2026.08.25-rc.1 1111111111111111111111111111111111111111111111111111111111111111 2222222222222222222222222222222222222222222222222222222222222222 3333333333333333333333333333333333333333333333333333333333333333
! validate_watch_state "$state_fixture" node1 1 v2026.08.25-rc.0 9999999999999999999999999999999999999999999999999999999999999999 2222222222222222222222222222222222222222222222222222222222222222 3333333333333333333333333333333333333333333333333333333333333333

upgrade_verifier="$ROOT/scripts/phase-public-upgrade-verify.sh"
grep -Fq 'load_profiles' "$upgrade_verifier"
grep -Fq 'VERIFICATION_SCOPE=cosmovisor-binaries' "$upgrade_verifier"
grep -Fq 'GATE_B_PROFILE="$UPGRADE_FROM_PROFILE"' "$upgrade_verifier"
grep -Fq 'GDC_RELEASE_PROFILE="$GATE_B_PROFILE"' "$upgrade_verifier"
! grep -Fq 'export GDC_RELEASE_PROFILE="$GATE_B_PROFILE"' "$upgrade_verifier"
grep -Fq '.release_profile == $profile' "$upgrade_verifier"
grep -Fq 'not the complete candidate stack' "$upgrade_verifier"

printf 'PASS Gate B, stale-lineage, canonical-PoC, CPoC, and upgrade-resume fixture contracts\n'
