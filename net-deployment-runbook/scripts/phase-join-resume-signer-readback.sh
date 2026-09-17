#!/usr/bin/env bash
# Complete a same-Host restore only when the conservative signer-start record
# is followed by independent proof that the already-running signer advanced.
# This path deliberately never starts, stops, resets, or re-syncs a Host.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

[[ $# -eq 2 ]] || { echo "Usage: $0 NODE RUN_DIR" >&2; exit 2; }
NODE="$(node_name "$1")"
RUN="$2"
[[ -d "$RUN" && -n "${GDC_RUN_ID:-}" && -r "${GDC_JOIN_PROFILE:-}" && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || {
  echo 'signer readback resume lacks retained run bindings' >&2; exit 2;
}

receipts="$RUN/receipts"
chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts")"
[[ "$(jq -r .last_state <<<"$chain")" == SIGNER_ACTIVATING && "$(jq -r .signer_ever_started <<<"$chain")" == true ]] || {
  echo 'signer readback resume requires retained SIGNER_ACTIVATING restore state' >&2; exit 1;
}
head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
head="$receipts/$head_name"
jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" '
  .run_id == $run_id and .operation == "restore" and .node_name == $node and
  .state == "SIGNER_ACTIVATING" and .signer_ever_started == true
' "$head" >/dev/null || { echo 'signer readback resume receipt binding is invalid' >&2; exit 1; }

ADDRESS="$(jq -er .identity_fingerprints.participant_address "$head")"
expected_chain_id="$(jq -er '.spec.network.chain_id' "$GDC_JOIN_PROFILE")"
expected_core_version="$(jq -er '.spec.components.core.expected_runtime.version' "$GDC_JOIN_PROFILE")"
deploy="/srv/dai/deploy/$NODE"
before="$RUN/tmkms-signing-state-before-enable.json"
[[ -s "$before" ]] || { echo 'signer readback resume lacks the pre-enable TMKMS state' >&2; exit 1; }

tmkms="$(ssh "$NODE" "cd '$deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms")"
[[ "$(printf '%s\n' "$tmkms" | sed '/^$/d' | wc -l)" == 1 ]] || {
  echo 'signer readback resume refused: target does not have exactly one signer' >&2; exit 1;
}
ssh "$NODE" "cd '$deploy' && ./verify-active-signer-state.sh '$deploy' '$expected_chain_id' '$expected_core_version'"
after="$RUN/tmkms-signing-state-after-enable.json"
ssh "$NODE" "sudo cat '/srv/dai/signer/$NODE/tmkms/state/priv_validator_state.json'" >"$after"
chmod 600 "$after"
"$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$before" --observed "$after" --require-advance >/dev/null || {
  echo 'signer readback resume refused: TMKMS has not advanced after the recorded enablement' >&2; exit 1;
}

append_transition() {
  local state="$1" input
  input="$(mktemp "$RUN/.signer-readback-transition.XXXXXX")"
  jq --arg state "$state" '
    del(.sequence, .recorded_at, .previous_receipt_sha256)
    | .state = $state | .signer_ever_started = true
    | .outcome = "in_progress" | .resume_policy = "resume_same_run"
  ' "$head" >"$input"
  "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$input" >/dev/null
  rm -f "$input"
  head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
  head="$receipts/$head_name"
}

record_join_state "$NODE" SIGNER_ENABLED "$ADDRESS"
append_transition SIGNER_ACTIVE_VERIFIED
"$ROOT/scripts/validator-backup.sh" create "$NODE"
append_transition RECOVERY_ARCHIVE_VERIFIED
append_transition COMPLETE
result="$(mktemp "$RUN/.signer-readback-result.XXXXXX")"
jq -cn --arg profile "$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"succeeded",phase:"signer",category:"internal",reason:"join_complete",exit_code:0,mutation:"signer_may_be_on",signer_state:"enabled",resume:"resume_same_run",join_profile_sha256:$profile,evidence:[]}' >"$result"
"$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$result" >/dev/null
rm -f "$result"
printf 'PASS Host JOIN signer readback completed without Host mutation\n'
