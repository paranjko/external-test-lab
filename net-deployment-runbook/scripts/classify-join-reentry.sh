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
for file in "$profile" "$result"; do
  [[ -f "$file" && ! -L "$file" && "$(stat -c %a "$file")" == 600 ]] \
    || { emit blocked retained_input_missing_or_unsafe; exit 0; }
done
[[ -d "$receipts" && ! -L "$receipts" ]] || { emit blocked retained_receipts_missing_or_unsafe; exit 0; }
if ! "$ROOT/scripts/join-profile.sh" validate --allow-expired "$profile" >/dev/null 2>&1; then
  emit blocked retained_profile_invalid
  exit 0
fi
if ! chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts" 2>/dev/null)"; then
  emit blocked retained_receipt_chain_invalid
  exit 0
fi
if ! jq -e '
  .schema_version == 1 and .kind == "gdc-host-join-result" and
  (.outcome | IN("succeeded","no_op","refused","failed","manual_recovery_required")) and
  (.join_profile_sha256 == null or (.join_profile_sha256 | test("^[a-f0-9]{64}$")))
' "$result" >/dev/null 2>&1; then
  emit blocked retained_terminal_result_invalid
  exit 0
fi
previous_profile_id="$(jq -r .profile_id "$profile")"
previous_operation="$(jq -r .operation "$profile")"
previous_profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
current_profile_id="$(jq -r .profile_id "$current")"
last_state="$(jq -r .last_state <<<"$chain")"
signer_started="$(jq -r .signer_ever_started <<<"$chain")"
terminal_outcome="$(jq -r .outcome "$result")"
terminal_profile_sha256="$(jq -r '.join_profile_sha256 // empty' "$result")"

if [[ "$last_state" == COMPLETE && "$signer_started" == true && "$terminal_outcome" == succeeded && "$terminal_profile_sha256" == "$previous_profile_sha256" ]]; then
  if [[ "$current_profile_id" == "$previous_profile_id" ]]; then
    emit completed_matched complete_profile_matches "$previous_profile_id"
  else
    emit profile_changed complete_profile_differs "$previous_profile_id"
  fi
  exit 0
fi
# Only post-signer acceptance has a bounded non-mutating dispatcher.  Earlier
# state changes may have touched identity, deployment or a signer and require
# an explicitly designed recovery protocol rather than a generic retry.
if [[ "$last_state" == SIGNER_ACTIVE_VERIFIED && "$previous_operation" == restore ]]; then
  emit resume_required "last_state_${last_state}" "$previous_profile_id"
else
  emit manual_recovery_required "unsupported_resume_state_${last_state}" "$previous_profile_id"
fi
