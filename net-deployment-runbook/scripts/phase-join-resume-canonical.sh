#!/usr/bin/env bash
# Resume the one safe interruption point before a returning validator's signer
# is enabled.  The canonical node is already running and has a retained
# signerless receipt, so this path never resets, re-syncs, or replaces keys.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

[[ $# -eq 2 ]] || { echo "Usage: $0 NODE RUN_DIR" >&2; exit 2; }
NODE="$(node_name "$1")"
RUN="$2"
[[ -d "$RUN" && -n "${GDC_RUN_ID:-}" && -r "${GDC_JOIN_PROFILE:-}" && -r "${GDC_JOIN_OBSERVATION:-}" && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || {
  echo 'canonical resume lacks retained run bindings' >&2; exit 2;
}

receipts="$RUN/receipts"
chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts")"
resume_state="$(jq -r .last_state <<<"$chain")"
[[ ( "$resume_state" == CANONICAL_RUNNING || "$resume_state" == APPLICATION_ACTIVE ) && "$(jq -r .signer_ever_started <<<"$chain")" == false ]] || {
  echo 'canonical resume requires retained signerless CANONICAL_RUNNING or APPLICATION_ACTIVE state' >&2; exit 1;
}
head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
head="$receipts/$head_name"
jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" '
  .run_id == $run_id and .operation == "restore" and .node_name == $node and
  (.state == "CANONICAL_RUNNING" or .state == "APPLICATION_ACTIVE") and
  .signer_ever_started == false
' "$head" >/dev/null || { echo 'canonical resume receipt binding is invalid' >&2; exit 1; }

IDENTITY="$IDENTITIES/$NODE.json"
[[ -r "$IDENTITY" ]] || { echo 'canonical resume lacks retained identity' >&2; exit 1; }
# The Host identity contains its P2P, consensus and warm-key roots.  The
# immutable canonical receipt binds the on-chain participant identity, so do
# not invent or derive it from the local identity shape during a resume.
ADDRESS="$(jq -er .identity_fingerprints.participant_address "$head")"
expected_chain_id="$(jq -er '.spec.network.chain_id' "$GDC_JOIN_PROFILE")"
expected_p2p_node_id="$(jq -er .node_id "$IDENTITY")"
expected_core_version="$(jq -er '.spec.components.core.expected_runtime.version' "$GDC_JOIN_PROFILE")"
expected_core_commit="$(jq -er '.spec.components.core.expected_runtime.commit' "$GDC_JOIN_PROFILE")"
expected_dapi_version="$(jq -er '.spec.components.dapi.expected_runtime.version' "$GDC_JOIN_PROFILE")"
expected_dapi_commit="$(jq -er '.spec.components.dapi.expected_runtime.commit' "$GDC_JOIN_PROFILE")"
lineage="$RUN/lineage-state-sync-receipt.json"
[[ -r "$lineage" ]] || { echo 'canonical resume lacks retained lineage receipt' >&2; exit 1; }

append_transition() {
  local state="$1" signer_started="${2:-false}" input
  input="$(mktemp "$RUN/.canonical-resume-transition.XXXXXX")"
  jq --arg state "$state" --argjson signer_started "$signer_started" '
    del(.sequence, .recorded_at, .previous_receipt_sha256)
    | .state = $state | .signer_ever_started = $signer_started
    | .outcome = "in_progress" | .resume_policy = "resume_same_run"
  ' "$head" >"$input"
  "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$input" >/dev/null
  rm -f "$input"
  head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
  head="$receipts/$head_name"
}

remote="/tmp/gdc-canonical-resume-${GDC_RUN_ID}-${NODE}"
ssh "$NODE" "rm -rf '$remote' && mkdir -p '$remote'"
scp -q "$ROOT/02-node/verify-canonical-join-state.sh" "$NODE:$remote/verify-canonical-join-state.sh"
scp -q "$ROOT/scripts/verify-join-lineage-state.sh" "$NODE:$remote/verify-join-lineage-state.sh"
scp -q "$lineage" "$NODE:$remote/lineage-receipt.json"

deploy="/srv/dai/deploy"
tmkms="$(ssh "$NODE" "cd '$deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms")"
[[ -z "$(printf '%s\n' "$tmkms" | sed '/^$/d')" ]] || { echo 'canonical resume refused: signer is already running' >&2; exit 1; }
if [[ "$resume_state" == CANONICAL_RUNNING ]]; then
  "$ROOT/03-join/restart-api-after-sync.sh" "$NODE"
  append_transition APPLICATION_ACTIVE
fi
if [[ "$NODE" != "$PUBLIC_EDGE_NODE" ]]; then
  # A participant edge is Caddy only: gateway-admission belongs to the shared
  # gateway, and its script is installed only by `gateway apply`.
  start_stack "$NODE" "/srv/dai/deploy/edge" caddy
else
  printf 'READY retained shared public edge on %s during participant JOIN resume\n' "$NODE"
fi
start_stack "$NODE" "/srv/dai/deploy/monitoring-agent"
ssh "$NODE" "cd '$deploy' && bash '$remote/verify-canonical-join-state.sh' '$deploy' '$expected_chain_id' '$expected_p2p_node_id' '$expected_core_version' '$expected_core_commit' '$expected_dapi_version' '$expected_dapi_commit'"
# State was already imported and verified before this receipt-bound resume.
# The original short-lived trust decision must not block a current common-head
# comparison after that import has completed; the verifier still compares the
# running node with every recorded trusted origin before signer activation.
ssh "$NODE" "bash '$remote/verify-join-lineage-state.sh' http://127.0.0.1:26657 '$remote/lineage-receipt.json' --resume-current"
append_transition CANONICAL_VERIFIED

participant_body="$(curl --connect-timeout 5 --max-time 10 -fsS "https://$GENESIS_PUBLIC_HOST/v2/participants/$ADDRESS" 2>/dev/null || true)"
participant_status="$(jq -r '.participant.status // empty' <<<"$participant_body" 2>/dev/null || true)"
[[ "$(participant_onboarding_state "$participant_status")" == active ]] || {
  echo 'canonical resume refused: retained returning participant is not ACTIVE on chain' >&2; exit 1;
}
record_join_state "$NODE" MEMBERSHIP_RECONCILED "$ADDRESS"
append_transition MEMBERSHIP_RECONCILED
record_join_state "$NODE" PERMISSIONS_RECONCILED "$ADDRESS"
append_transition PERMISSIONS_RECONCILED
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
ML_HOST="$(node_ml_host "$NODE" || true)"
[[ -z "$ML_HOST" ]] || "$ROOT/scripts/phase-ml-attach.sh" "$NODE"

reset_metadata="$(bash "$ROOT/scripts/resolve-reset-dai-backup.sh" "$STATE/reset/$NODE")" \
  || { echo 'canonical resume refused: verified reset archive metadata is missing' >&2; exit 1; }
bash "$ROOT/scripts/same-host-restore.sh" bind "$NODE" "$IDENTITY" "$expected_chain_id" \
  "$reset_metadata" "$RUN/reset-dai-backup-before-enable.json"
consensus_pubkey="$(jq -er .consensus_pubkey "$IDENTITY")"
fence_remote="$deploy/.gdc/runs/$GDC_RUN_ID/signer-fence-receipt.v1.json"
ssh "$NODE" "sudo '$deploy/fence-existing-signer.sh' '$deploy' '$GDC_RUN_ID' '$consensus_pubkey' '$NODE'"
ssh "$NODE" "sudo cat '$fence_remote'" >"$RUN/signer-fence-receipt.v1.json"
chmod 600 "$RUN/signer-fence-receipt.v1.json"
"$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$RUN/signer-fence-receipt.v1.json" --run-id "$GDC_RUN_ID" --consensus-pubkey "$consensus_pubkey"
record_join_state "$NODE" SIGNER_FENCE_VERIFIED "$ADDRESS"
append_transition SIGNER_FENCE_VERIFIED

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
append_transition SIGNER_ACTIVATING true
ssh "$NODE" "cd '$deploy' && ./start-node.sh --enable-signer"
# Enabling the signer recreates Core. Its RPC answers and leaves block sync
# some seconds later, so one immediate readback fails on a healthy Host.
readback_deadline=$((SECONDS + 300))
until ssh "$NODE" "cd '$deploy' && ./verify-active-signer-state.sh '$deploy' '$expected_chain_id' '$expected_core_version'" >"$RUN/active-signer-readback.log" 2>&1; do
  if (( SECONDS >= readback_deadline )); then
    cat "$RUN/active-signer-readback.log" >&2
    die 'active signer readback did not pass after signer enablement'
  fi
  printf 'WAIT active signer readback for %s: %s\n' "$NODE" "$(tail -n 1 "$RUN/active-signer-readback.log")"
  sleep 5
done
cat "$RUN/active-signer-readback.log"
deadline=$((SECONDS + 2400)); advanced=false
while (( SECONDS < deadline )); do
  after="$RUN/tmkms-signing-state-after-enable.json"
  # The signer is already on; one failed read is not evidence about it.
  ssh "$NODE" "sudo cat '/srv/dai/signer/tmkms/state/priv_validator_state.json'" >"$after" \
    || { sleep 2; continue; }
  chmod 600 "$after"
  if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$before" --observed "$after" --require-advance >/dev/null; then advanced=true; break; fi
  sleep 2
done
[[ "$advanced" == true ]] || { echo 'canonical resume failed: TMKMS did not advance after enablement' >&2; exit 1; }
record_join_state "$NODE" SIGNER_ENABLED "$ADDRESS"
append_transition SIGNER_ACTIVE_VERIFIED true
"$ROOT/scripts/validator-backup.sh" create "$NODE" resume-canonical
append_transition RECOVERY_ARCHIVE_VERIFIED true
append_transition COMPLETE true
# Staging cleanup says nothing about the validator and must not fail its JOIN.
ssh "$NODE" "rm -rf '$remote'" \
  || printf 'WARN staging directory %s was not removed on %s\n' "$remote" "$NODE"
printf 'PASS Host JOIN resumed from signerless canonical state without reset or re-sync\n'
