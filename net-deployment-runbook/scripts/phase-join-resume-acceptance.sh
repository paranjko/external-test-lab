#!/usr/bin/env bash
# Complete only the post-signer portion of a receipt-bound JOIN. It is a
# separate dispatcher so a signer cutover cannot silently turn into acceptance.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

[[ $# -eq 2 ]] || { echo "Usage: $0 NODE RUN_DIR" >&2; exit 2; }
NODE="$(node_name "$1")"
RUN="$2"
[[ -d "$RUN" && -n "${GDC_RUN_ID:-}" && -r "${GDC_JOIN_PROFILE:-}" && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || {
  echo 'invalid receipt-bound acceptance resume input' >&2; exit 2;
}
receipts="$RUN/receipts"
"$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts" >/dev/null
head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
head="$receipts/$head_name"
resume_state="$(jq -er .state "$head")"
jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" '
  .run_id == $run_id and (.operation == "new" or .operation == "restore") and
  .node_name == $node and
  (.state == "SIGNER_ARMED_PENDING_ELIGIBILITY" or .state == "SIGNER_ACTIVE_VERIFIED" or .state == "RECOVERY_ARCHIVE_VERIFIED") and
  .signer_ever_started == true
' "$head" >/dev/null || { echo 'acceptance resume requires retained signer-active restore state' >&2; exit 1; }
if ! jq -e '
  .kind == "gdc-host-join-result" and .outcome == "manual_recovery_required" and
  .reason == "resume_signer_active_acceptance_pending" and .signer_state == "enabled" and
  .resume == "resume_same_run"
' "$GDC_JOIN_RESULT_OUTPUT" >/dev/null; then
  # Runs produced before the acceptance guard was narrowed retain the
  # conservative pre-start result. The verified receipt chain above is newer,
  # proves signer activation and permits only this explicit acceptance resume.
  jq -e '
    .kind == "gdc-host-join-result" and .outcome == "manual_recovery_required" and
    .reason == "signer_activation_readback_required" and .signer_state == "unknown" and
    .resume == "automatic_retry_forbidden"
  ' "$GDC_JOIN_RESULT_OUTPUT" >/dev/null \
    || { echo 'acceptance resume requires retained signer-active result' >&2; exit 1; }
fi

remote_deploy=/srv/dai/deploy
tmkms="$(ssh "$NODE" "cd '$remote_deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms")"
[[ "$(printf '%s\n' "$tmkms" | sed '/^$/d' | wc -l)" == 1 ]] || {
  echo 'acceptance resume refused: target does not have exactly one signer' >&2; exit 1;
}

append_transition() {
  local state="$1" input
  input="$(mktemp "$RUN/.acceptance-transition.XXXXXX")"
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

step "Verify $NODE through independent chain eligibility and gateway acceptance"
"$ROOT/scripts/phase-join-acceptance.sh" "$NODE"
if [[ "$resume_state" == SIGNER_ARMED_PENDING_ELIGIBILITY || "$resume_state" == SIGNER_ACTIVE_VERIFIED ]]; then
  append_transition ACTIVE_CONFIRMED
  step "Create a new verified validator recovery archive for $NODE"
  "$ROOT/scripts/validator-backup.sh" create "$NODE"
  append_transition RECOVERY_ARCHIVE_VERIFIED
fi
append_transition COMPLETE
input="$(mktemp "$RUN/.acceptance-result.XXXXXX")"
jq -cn --arg profile "$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"succeeded",phase:"acceptance",category:"internal",reason:"join_complete",exit_code:0,mutation:"signer_may_be_on",signer_state:"enabled",resume:"resume_same_run",join_profile_sha256:$profile,evidence:[]}' >"$input"
"$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$input" >/dev/null
rm -f "$input"
printf 'PASS receipt-bound restore acceptance complete\n'
