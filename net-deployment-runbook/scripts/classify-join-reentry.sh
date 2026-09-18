#!/usr/bin/env bash
# Decide whether a normal Host JOIN invocation may finish as a read-only no-op.
# An earlier partial run is never re-entered through the normal command: its
# immutable receipt chain selects the only supported --resume dispatcher.
set -Eeuo pipefail

usage() { echo "Usage: $0 --previous-run-dir DIR --current-profile FILE" >&2; }
previous=''; current=''
while (($#)); do
  case "$1" in
    --previous-run-dir) previous="${2:-}"; shift 2 ;;
    --current-profile) current="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$current" && ! -L "$current" && -n "$previous" ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/join-profile.sh" validate "$current" >/dev/null

emit() {
  local classification="$1" reason="$2" previous_profile_id="${3:-}"
  jq -cn --arg classification "$classification" --arg reason "$reason" \
    --arg previous_run_dir "$previous" --arg previous_profile_id "$previous_profile_id" \
    '{schema_version:1,kind:"gdc-host-join-reentry",classification:$classification,reason:$reason,previous_run_dir:$previous_run_dir,previous_profile_id:($previous_profile_id | if . == "" then null else . end)}'
}

if [[ ! -e "$previous" ]]; then
  emit no_prior_run none
  exit 0
fi
[[ -d "$previous" && ! -L "$previous" ]] || { emit blocked previous_run_path_unsafe; exit 0; }
profile="$previous/join-profile.v1.json"
receipts="$previous/receipts"
result="$previous/join-result.v1.json"
[[ -f "$profile" && ! -L "$profile" && "$(stat -c %a "$profile")" == 600 ]] \
  || { emit blocked retained_input_missing_or_unsafe; exit 0; }
if ! "$ROOT/scripts/join-profile.sh" validate --allow-expired "$profile" >/dev/null 2>&1; then
  emit blocked retained_profile_invalid
  exit 0
fi
result_missing=false
if [[ ! -e "$result" ]]; then
  result_missing=true
elif [[ ! -f "$result" || -L "$result" || "$(stat -c %a "$result" 2>/dev/null || true)" != 600 ]]; then
  emit blocked retained_input_missing_or_unsafe
  exit 0
elif ! jq -e '
  .schema_version == 1 and .kind == "gdc-host-join-result" and
  (.outcome | IN("succeeded","no_op","refused","failed","manual_recovery_required")) and
  (.join_profile_sha256 == null or (.join_profile_sha256 | test("^[a-f0-9]{64}$")))
' "$result" >/dev/null 2>&1; then
  emit blocked retained_terminal_result_invalid
  exit 0
fi
previous_profile_id="$(jq -r .profile_id "$profile")"
terminal_profile_sha256=''
terminal_outcome=''; terminal_phase=''; terminal_category=''; terminal_reason=''; terminal_exit=''; terminal_mutation=''; terminal_signer_state=''; terminal_resume=''
if [[ "$result_missing" != true ]]; then
  terminal_profile_sha256="$(jq -r '.join_profile_sha256 // empty' "$result")"
  terminal_outcome="$(jq -r .outcome "$result")"
  terminal_phase="$(jq -r .phase "$result")"
  terminal_category="$(jq -r .category "$result")"
  terminal_reason="$(jq -r .reason "$result")"
  terminal_exit="$(jq -r .exit_code "$result")"
  terminal_mutation="$(jq -r .mutation "$result")"
  terminal_signer_state="$(jq -r .signer_state "$result")"
  terminal_resume="$(jq -r .resume "$result")"
fi
# The first JOIN mutation occurs only after lineage preflight, where the phase
# creates the lifecycle receipt directory.  A terminal preflight refusal with
# no receipt directory therefore has not touched a remote Host. Keep it for
# diagnosis and allow a fresh observation/retry.
if [[ ! -e "$receipts" && "$terminal_outcome" == refused && "$terminal_phase" == profile \
  && "$terminal_mutation" == none && "$terminal_signer_state" == absent ]]; then
  emit preflight_retry_allowed failed_before_host_mutation "$previous_profile_id"
  exit 0
fi
[[ -d "$receipts" && ! -L "$receipts" ]] || { emit blocked retained_receipts_missing_or_unsafe; exit 0; }
if ! chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts" 2>/dev/null)"; then
  emit blocked retained_receipt_chain_invalid
  exit 0
fi
previous_operation="$(jq -r .operation "$profile")"
previous_profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
current_profile_id="$(jq -r .profile_id "$current")"
last_state="$(jq -r .last_state <<<"$chain")"
signer_started="$(jq -r .signer_ever_started <<<"$chain")"

if [[ "$last_state" == COMPLETE && "$signer_started" == true && "$terminal_outcome" == succeeded && "$terminal_profile_sha256" == "$previous_profile_sha256" ]]; then
  if [[ "$current_profile_id" == "$previous_profile_id" ]]; then
    emit completed_matched complete_profile_matches "$previous_profile_id"
  else
    emit profile_changed complete_profile_differs "$previous_profile_id"
  fi
  exit 0
fi
# Host preparation may install an NVIDIA driver and intentionally stop before
# identity creation. A retry creates a fresh profile and repeats public
# observation after reboot. Support the old receipt form as well: it has the
# exact early lifecycle state and exit-194 verdict, so it cannot have created
# a signer or deployment.
if [[ "$last_state" == TARGET_CLASSIFIED && "$signer_started" == false && "$previous_operation" == new ]]; then
  if [[ "$terminal_outcome" == failed && "$terminal_phase" == staging && "$terminal_category" == host \
    && "$terminal_reason" == host_prepare_reboot_required && "$terminal_exit" == 194 \
    && "$terminal_mutation" == staging_only && "$terminal_signer_state" == disabled && "$terminal_resume" == new_profile ]]; then
    emit preparation_retry_allowed host_prepare_reboot_required "$previous_profile_id"
    exit 0
  fi
  if [[ "$terminal_outcome" == failed && "$terminal_phase" == staging && "$terminal_category" == host \
    && "$terminal_reason" == host_prepare_failed_before_identity \
    && "$terminal_exit" =~ ^[1-9][0-9]*$ && "$terminal_mutation" == staging_only \
    && "$terminal_signer_state" == disabled && "$terminal_resume" == new_profile ]]; then
    emit preparation_retry_allowed host_prepare_failed_before_identity "$previous_profile_id"
    exit 0
  fi
  # Older launchers wrote a generic terminal result for a failure in
  # phase-prepare. The receipt chain proves this was still before
  # HOST_BASE_PREPARED, which is before identity/deployment/signer mutation.
  # Accept only that exact legacy shape so an existing operator can rerun the
  # safe preparation step; no later phase is eligible for automatic retry.
  if [[ "$terminal_outcome" == failed && "$terminal_phase" == signer && "$terminal_category" == internal \
    && "$terminal_reason" == join_phase_failed && "$terminal_exit" =~ ^[1-9][0-9]*$ \
    && "$terminal_mutation" == signer_may_be_on && "$terminal_signer_state" == unknown \
    && "$terminal_resume" == automatic_retry_forbidden ]]; then
    emit preparation_retry_allowed legacy_host_prepare_failed_before_identity "$previous_profile_id"
    exit 0
  fi
  if [[ "$result_missing" == true && -f "$previous/verdict.md" && ! -L "$previous/verdict.md" ]] \
    && grep -Fqx 'The phase stopped with exit code 194 before it could write its final verdict.' "$previous/verdict.md"; then
    emit preparation_retry_allowed legacy_host_prepare_reboot_required "$previous_profile_id"
    exit 0
  fi
fi
# Only post-signer acceptance has a bounded non-mutating dispatcher.  Earlier
# state changes may have touched identity, deployment or a signer and require
# an explicitly designed recovery protocol rather than a generic retry.
if [[ "$last_state" == SIGNER_ACTIVE_VERIFIED && "$previous_operation" == restore ]]; then
  emit resume_required "last_state_${last_state}" "$previous_profile_id"
else
  emit manual_recovery_required "unsupported_resume_state_${last_state}" "$previous_profile_id"
fi
