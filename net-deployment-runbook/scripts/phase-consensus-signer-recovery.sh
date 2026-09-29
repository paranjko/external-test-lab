#!/usr/bin/env bash
# Explicit consensus-only recovery; ordinary JOIN never selects this phase.
set -Eeuo pipefail
{ set +x; } 2>/dev/null
umask 077
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/lib.sh"
load_project

recovery_stage() {
  bash -Eeuo pipefail -c 'source "$1"; shift; "$@"' bash \
    "$ROOT/scripts/consensus-signer-recovery.sh" "$@"
}

[[ $# -eq 4 ]] || { echo "Usage: $0 NODE RUN_DIR BOOTSTRAP start|readback" >&2; exit 2; }
NODE="$(node_name "$1")" RUN="$2" BOOTSTRAP="$3" MODE="$4"
[[ "$MODE" == start || "$MODE" == readback ]] || exit 2
[[ -d "$RUN" && ! -L "$RUN" && "${GDC_JOIN_PROFILE:-}" == "$RUN/join-profile.v1.json" &&
   "${GDC_JOIN_RESULT_OUTPUT:-}" == "$RUN/join-result.v1.json" ]] || exit 2
jq -e --arg node "$NODE" --arg run "${GDC_RUN_ID:-}" \
  '.run_id == $run and .spec.target.node_name == $node and .operation == "restore"' "$GDC_JOIN_PROFILE" >/dev/null
"$ROOT/scripts/verify-join-resume-inputs.sh" --run-dir "$RUN" --run-id "$GDC_RUN_ID" \
  --node-name "$NODE" --public-host "$(jq -er .spec.target.public_host "$GDC_JOIN_PROFILE")" >/dev/null
chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$RUN/receipts")"
receipt_state="$(jq -er .last_state <<<"$chain")"
if [[ "$MODE" == start ]]; then
  [[ "$receipt_state" == RUN_CREATED ]] || { echo 'Recovery start requires a new run; use readback after activation' >&2; exit 2; }
  recovery_stage recovery_execute "$RUN" "$BOOTSTRAP" "$STATE/operator-home" "$SECRETS/operator.keyring"
  receipt_state=SIGNER_ACTIVATING
else
  case "$receipt_state" in
    SIGNER_FENCE_VERIFIED)
      recovery_stage recovery_resume_fenced "$RUN" "$BOOTSTRAP"
      receipt_state=SIGNER_ACTIVATING ;;
    RUN_CREATED)
      recovery_stage recovery_continue_installed "$RUN" "$BOOTSTRAP" "$STATE/operator-home" "$SECRETS/operator.keyring"
      receipt_state=SIGNER_ACTIVATING ;;
    SIGNER_ACTIVATING|SIGNER_ACTIVE_VERIFIED|RECOVERY_ARCHIVE_VERIFIED) ;;
    *) echo "Recovery cannot resume mutation from state=$receipt_state; preserve evidence" >&2; exit 2 ;;
  esac
fi

# Every readback gets a new evidence directory. It never retries installation,
# broadcasts a transaction, starts a container, or erases a failed observation.
validation="$RUN/validation-$(date -u +%Y%m%dT%H%M%SZ)-$$"
recovery_stage recovery_wait_validating "$RUN" "$RUN/preparation-observation" "$validation"
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$NODE" \
  'sudo cat /srv/dai/signer/tmkms/state/priv_validator_state.json' >"$validation/signing-state.json"
"$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$RUN/recovery-boundary.json" \
  --observed "$validation/signing-state.json" --require-advance >/dev/null
if [[ "$receipt_state" == SIGNER_ACTIVATING ]]; then
  recovery_stage recovery_record_transition "$RUN" SIGNER_ACTIVE_VERIFIED \
    "$validation/result.json" "$validation/signing-state.json" >/dev/null
  receipt_state=SIGNER_ACTIVE_VERIFIED
fi
recovery_stage recovery_update_operator_identity "$RUN" "$IDENTITIES/$NODE.json" "$RUN/preparation-observation"
record_join_state "$NODE" SIGNER_ENABLED "$(jq -er .participant_address "$RUN/preparation-observation/intent.json")"
"$ROOT/scripts/validator-backup.sh" create "$NODE" consensus-recovery
archive="$GDC_DATA_ROOT/$NODE-validator-backup-$GDC_RUN_ID-consensus-recovery.tar"
[[ -f "$archive" && ! -L "$archive" ]] || exit 1
if [[ "$receipt_state" == SIGNER_ACTIVE_VERIFIED ]]; then
  recovery_stage recovery_record_transition "$RUN" RECOVERY_ARCHIVE_VERIFIED "$archive" "$validation/signing-state.json" >/dev/null
fi
destination="/srv/backup/consensus-recovery-$GDC_RUN_ID"
[[ "$GDC_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || exit 2
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$NODE" \
  "sudo bash -c 'set -Eeuo pipefail; umask 077; cat >\"\$1/validation.json.tmp\"; sync -f \"\$1\"; mv -T \"\$1/validation.json.tmp\" \"\$1/validation.json\"' bash '$destination'" \
  <"$validation/result.json"
ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$NODE" \
  "sudo bash '$destination/install-consensus-signer.sh' --finalize /srv/dai/deploy '$destination' '$destination/tmkms-softsign-public-key.sh' '$destination/validation.json'"
recovery_stage recovery_record_transition "$RUN" COMPLETE "$validation/result.json" "$validation/signing-state.json" >/dev/null
profile_sha="$(sha256sum "$GDC_JOIN_PROFILE")"; evidence_sha="$(sha256sum "$validation/result.json")"
jq -cn --arg profile "${profile_sha%% *}" --arg evidence "${evidence_sha%% *}" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"succeeded",phase:"acceptance",category:"internal",
    reason:"join_complete",exit_code:0,mutation:"signer_may_be_on",signer_state:"enabled",
    resume:"not_applicable",join_profile_sha256:$profile,evidence:[{kind:"validating",sha256:$evidence}]}' \
  >"$validation/join-result.json"
"$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$validation/join-result.json" >/dev/null
printf 'PASS %s consensus recovery VALIDATING; evidence=%s\n' "$NODE" "$validation"
