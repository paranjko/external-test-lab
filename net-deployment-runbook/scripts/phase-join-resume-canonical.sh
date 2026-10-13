#!/usr/bin/env bash
# Resume the one safe interruption point before a returning validator's signer
# is enabled.  The canonical node is already running and has a retained
# signerless receipt, so this path never resets, re-syncs, or replaces keys.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
# shellcheck source=lib-join-resume.sh
source "$(dirname "$0")/lib-join-resume.sh"
# join_resume_prepare_post_sync deliberately exports these receipt-bound
# values to the signer continuation below.
# shellcheck disable=SC2154

[[ $# -eq 2 ]] || { echo "Usage: $0 NODE RUN_DIR" >&2; exit 2; }
NODE="$(node_name "$1")"
RUN="$2"

verify_inactive_restore_key() {
  local validators observed
  [[ -r "$RUN/restore-tmkms-signing-state.json" ]] || {
    echo 'canonical resume lacks the immutable restored TMKMS signing minimum' >&2
    exit 1
  }
  validators="$RUN/restore-validator-set-resume-before-enable.json"
  curl -fsS --connect-timeout 10 --max-time 30 \
    "https://${GENESIS_PUBLIC_HOST}/chain-rpc/validators?per_page=100" >"$validators" \
    || { echo 'canonical resume cannot read the complete public validator set for validator-backup recovery' >&2; exit 1; }
  chmod 600 "$validators"
  "$ROOT/scripts/verify-inactive-validator-key.sh" \
    --identity "$IDENTITY" --validators "$validators" \
    --output "$RUN/inactive-validator-key-resume-before-enable.json"
  observed="$RUN/restored-tmkms-signing-state-resume-before-enable.json"
  ssh -T "$NODE" "sudo -n cat '/srv/dai/signer/tmkms/state/priv_validator_state.json'" >"$observed"
  chmod 600 "$observed"
  "$ROOT/scripts/verify-tmkms-signing-state.sh" \
    --minimum "$RUN/restore-tmkms-signing-state.json" --observed "$observed" \
    || { echo 'canonical resume refused: restored signer state is lower than the immutable validator-backup minimum' >&2; exit 1; }
}

join_resume_prepare_post_sync restore

participant_body="$(curl --connect-timeout 5 --max-time 10 -fsS "https://$GENESIS_PUBLIC_HOST/v2/participants/$ADDRESS" 2>/dev/null || true)"
participant_status="$(jq -r '.participant.status // empty' <<<"$participant_body" 2>/dev/null || true)"
[[ "$(participant_onboarding_state "$participant_status")" == active ]] || {
  echo 'canonical resume refused: retained returning participant is not ACTIVE on chain' >&2; exit 1;
}
# shellcheck disable=SC2154 # join_resume_prepare_post_sync binds the retained state.
if [[ "$resume_state" != MEMBERSHIP_RECONCILED ]]; then
  record_join_state "$NODE" MEMBERSHIP_RECONCILED "$ADDRESS"
  join_resume_append_transition MEMBERSHIP_RECONCILED
fi
record_join_state "$NODE" PERMISSIONS_RECONCILED "$ADDRESS"
join_resume_append_transition PERMISSIONS_RECONCILED
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
ML_HOST="$(node_ml_host "$NODE" || true)"
[[ -z "$ML_HOST" ]] || "$ROOT/scripts/phase-ml-attach.sh" "$NODE"

if reset_metadata="$(bash "$ROOT/scripts/resolve-reset-dai-backup.sh" "$STATE/reset/$NODE" 2>/dev/null)"; then
  # shellcheck disable=SC2154 # join_resume_prepare_post_sync binds the profile chain ID.
  bash "$ROOT/scripts/same-host-restore.sh" bind "$NODE" "$IDENTITY" "$expected_chain_id" \
    "$reset_metadata" "$RUN/reset-dai-backup-before-enable.json"
else
  printf 'READY canonical resume uses the inactive restored validator-key fence\n'
  verify_inactive_restore_key
fi
consensus_pubkey="$(jq -er .consensus_pubkey "$IDENTITY")"
# shellcheck disable=SC2154 # join_resume_prepare_post_sync binds the fixed deployment path.
fence_remote="$deploy/.gdc/runs/$GDC_RUN_ID/signer-fence-receipt.v1.json"
ssh "$NODE" "sudo '$deploy/fence-existing-signer.sh' '$deploy' '$GDC_RUN_ID' '$consensus_pubkey' '$NODE'"
ssh "$NODE" "sudo cat '$fence_remote'" >"$RUN/signer-fence-receipt.v1.json"
chmod 600 "$RUN/signer-fence-receipt.v1.json"
"$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$RUN/signer-fence-receipt.v1.json" --run-id "$GDC_RUN_ID" --consensus-pubkey "$consensus_pubkey"
record_join_state "$NODE" SIGNER_FENCE_VERIFIED "$ADDRESS"
join_resume_append_transition SIGNER_FENCE_VERIFIED

before="$RUN/tmkms-signing-state-before-enable.json"
ssh "$NODE" "sudo cat '/srv/dai/signer/tmkms/state/priv_validator_state.json'" >"$before"
chmod 600 "$before"
status="$(ssh -T "$NODE" 'curl -fsS --max-time 10 http://127.0.0.1:26657/status')"
jq -e --slurpfile state "$before" '.result.sync_info.catching_up == false and (.result.sync_info.latest_block_height | tonumber) > ($state[0].height | tonumber)' <<<"$status" >/dev/null || {
  echo 'canonical resume refused: restored chain has not passed the last signed height' >&2; exit 1;
}
# Record the conservative outcome before sending the only command that may
# start a signer.  `run_phase` replaces it only after this dispatcher returns
# successfully and has read back the signer state.
guard="$(mktemp "$RUN/.canonical-resume-guard.XXXXXX")"
jq -cn --arg profile "$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"manual_recovery_required",phase:"signer",category:"signer",reason:"signer_activation_readback_required",exit_code:1,mutation:"signer_may_be_on",signer_state:"unknown",resume:"automatic_retry_forbidden",join_profile_sha256:$profile,evidence:[]}' >"$guard"
"$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$guard" >/dev/null
rm -f "$guard"
join_resume_append_transition SIGNER_ACTIVATING true
ssh "$NODE" "cd '$deploy' && ./start-node.sh --enable-signer"
# Enabling the signer recreates Core. Its RPC answers and leaves block sync
# some seconds later, so one immediate readback fails on a healthy Host.
readback_deadline=$((SECONDS + 300))
# shellcheck disable=SC2154 # join_resume_prepare_post_sync binds profile runtime expectations and deployment.
until ssh "$NODE" "cd '$deploy' && ./verify-active-signer-state.sh '$deploy' '$expected_chain_id' '$expected_core_version'" >"$RUN/active-signer-readback.log" 2>&1; do
  if (( SECONDS >= readback_deadline )); then
    cat "$RUN/active-signer-readback.log" >&2
    die 'active signer readback did not pass after signer enablement'
  fi
  printf 'WAIT active signer readback for %s: %s\n' "$NODE" "$(tail -n 1 "$RUN/active-signer-readback.log")"
  sleep 5
done
cat "$RUN/active-signer-readback.log"
signing_wait_seconds=300
deadline=$((SECONDS + signing_wait_seconds)); advanced=false
while (( SECONDS < deadline )); do
  after="$RUN/tmkms-signing-state-after-enable.json"
  # The signer is already on; one failed read is not evidence about it.
  ssh "$NODE" "sudo cat '/srv/dai/signer/tmkms/state/priv_validator_state.json'" >"$after" \
    || { sleep 2; continue; }
  chmod 600 "$after"
  if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$before" --observed "$after" --require-advance >/dev/null; then advanced=true; break; fi
  sleep 2
done
record_join_state "$NODE" SIGNER_ENABLED "$ADDRESS"
if [[ "$advanced" == true ]]; then
  join_resume_append_transition SIGNER_ACTIVE_VERIFIED true
else
  # An inactive restored validator is deliberately absent from the current
  # validator set, so Comet has no signature request for its armed signer.
  # Treat this as the same bounded pending-eligibility state as fresh JOIN.
  join_resume_append_transition SIGNER_ARMED_PENDING_ELIGIBILITY true
  printf 'READY %s signer is armed; positive consensus eligibility remains pending accepted PoC evidence\n' "$NODE"
fi
"$ROOT/scripts/validator-backup.sh" create "$NODE" resume-canonical
join_resume_append_transition RECOVERY_ARCHIVE_VERIFIED true
join_resume_append_transition COMPLETE true
# Staging cleanup says nothing about the validator and must not fail its JOIN.
# shellcheck disable=SC2154 # join_resume_prepare_post_sync binds the staging directory.
ssh "$NODE" "rm -rf '$remote'" \
  || printf 'WARN staging directory %s was not removed on %s\n' "$remote" "$NODE"
printf 'PASS Host JOIN resumed from signerless canonical state without reset or re-sync\n'
