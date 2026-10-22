#!/usr/bin/env bash
# Continue a fresh JOIN only after its participant registration was retained
# and before any signer operation. This is deliberately narrower than a
# general retry: it never creates an account or registers a participant. It
# may finish the retained participant's idempotent faucet claim.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

[[ $# -eq 2 ]] || { echo "Usage: $0 NODE RUN_DIR" >&2; exit 2; }
NODE="$(node_name "$1")"
RUN="$2"
[[ -d "$RUN" && -n "${GDC_RUN_ID:-}" && -r "${GDC_JOIN_PROFILE:-}" && -r "${GDC_JOIN_OBSERVATION:-}" && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || {
  echo 'membership resume lacks retained run bindings' >&2; exit 2;
}

receipts="$RUN/receipts"
chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts")"
[[ "$(jq -r .last_state <<<"$chain")" == MEMBERSHIP_RECONCILED && "$(jq -r .signer_ever_started <<<"$chain")" == false ]] || {
  echo 'membership resume requires retained signerless MEMBERSHIP_RECONCILED state' >&2; exit 1;
}
head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
head="$receipts/$head_name"
jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" '
  .run_id == $run_id and .operation == "new" and .node_name == $node and
  .state == "MEMBERSHIP_RECONCILED" and .signer_ever_started == false
' "$head" >/dev/null || { echo 'membership resume receipt binding is invalid' >&2; exit 1; }

IDENTITY="$IDENTITIES/$NODE.json"
[[ -r "$IDENTITY" ]] || { echo 'membership resume lacks retained identity' >&2; exit 1; }
ADDRESS="$(jq -er .identity_fingerprints.participant_address "$head")"
COLD_ACCOUNT="$ACCOUNTS/$NODE-cold.json"
[[ -r "$COLD_ACCOUNT" && "$(jq -er .address "$COLD_ACCOUNT")" == "$ADDRESS" ]] || {
  echo 'membership resume cold account does not match the retained participant' >&2; exit 1;
}
expected_chain_id="$(jq -er '.spec.network.chain_id' "$GDC_JOIN_PROFILE")"
expected_core_version="$(jq -er '.spec.components.core.expected_runtime.version' "$GDC_JOIN_PROFILE")"
join_profile_sha256="$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')"

append_transition() {
  local state="$1" signer_started="${2:-false}" input
  input="$(mktemp "$RUN/.membership-resume-transition.XXXXXX")"
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

record_activation_guard() {
  local input
  input="$(mktemp "$RUN/.membership-resume-guard.XXXXXX")"
  jq -cn --arg profile "$join_profile_sha256" \
    '{schema_version:1,kind:"gdc-host-join-result",outcome:"manual_recovery_required",phase:"signer",category:"signer",reason:"signer_activation_readback_required",exit_code:1,mutation:"signer_may_be_on",signer_state:"unknown",resume:"automatic_retry_forbidden",join_profile_sha256:$profile,evidence:[]}' >"$input"
  "$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$input" >/dev/null
  rm -f "$input"
}

ensure_membership_funding() {
  local onboarding_state="$1" address="$2" balance_body balance_stderr balance_http_status balance_curl_exit balance
  case "$onboarding_state" in
    registered)
      step "Claim bounded public DevNet funding for $NODE"
      "$ROOT/scripts/claim-devnet-faucet.sh" "$address"
      return
      ;;
    active) ;;
    *) echo 'membership resume refused: retained participant is no longer registered on chain' >&2; exit 1 ;;
  esac

  balance_body="$(mktemp)"; balance_stderr="$(mktemp)"
  if balance_http_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$balance_body" -w '%{http_code}' \
    "https://${GENESIS_PUBLIC_HOST}/chain-api/cosmos/bank/v1beta1/spendable_balances/$address" 2>"$balance_stderr")"; then
    balance_curl_exit=0
  else
    balance_curl_exit=$?
  fi
  if (( balance_curl_exit != 0 )) || [[ ! "$balance_http_status" =~ ^2[0-9][0-9]$ ]]; then
    rm -f "$balance_body" "$balance_stderr"
    echo "membership resume cannot determine participant spendable balance (http_status=${balance_http_status:-000} curl_exit=$balance_curl_exit)" >&2
    exit 1
  fi
  if ! balance="$(jq -er '
    if type == "object" and (.balances | type) == "array" and
       ([.balances[] | select(.denom == "ngonka")] | length) <= 1 and
       all(.balances[]; (.denom | type) == "string" and (.amount | type) == "string" and (.amount | test("^[0-9]+$")))
    then ([.balances[] | select(.denom == "ngonka") | .amount][0] // "0")
    else error("malformed spendable balance response") end
  ' "$balance_body")"; then
    rm -f "$balance_body" "$balance_stderr"
    echo 'membership resume received malformed participant spendable balance data' >&2
    exit 1
  fi
  rm -f "$balance_body" "$balance_stderr"
  balance="$(sed 's/^0*//' <<<"$balance")"; balance="${balance:-0}"
  if [[ "$balance" == 0 ]]; then
    step "Complete bounded public DevNet funding for active $NODE"
    "$ROOT/scripts/claim-devnet-faucet.sh" "$address"
  else
    printf 'READY %s active participant has positive spendable balance; skip duplicate claim\n' "$NODE"
  fi
}

participant_body="$(curl --connect-timeout 5 --max-time 15 -fsS "https://$GENESIS_PUBLIC_HOST/v2/participants/$ADDRESS" 2>/dev/null || true)"
participant_status="$(jq -r '.participant.status // empty' <<<"$participant_body" 2>/dev/null || true)"
ensure_membership_funding "$(participant_onboarding_state "$participant_status")" "$ADDRESS"

warm_address="$(jq -er .warm_address "$IDENTITY")"
warm_endpoint="https://${GENESIS_PUBLIC_HOST}/chain-api/cosmos/auth/v1beta1/accounts/$warm_address"
warm_body="$(mktemp)"; warm_stderr="$(mktemp)"
if warm_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$warm_body" -w '%{http_code}' "$warm_endpoint" 2>"$warm_stderr")"; then warm_rc=0; else warm_rc=$?; fi
rm -f "$warm_body" "$warm_stderr"
if (( warm_rc == 0 )) && [[ "$warm_status" == 404 ]]; then
  step "Grant ML operational permissions for $NODE"
  "$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITY" "$INVENTORY"
elif (( warm_rc == 0 )) && [[ "$warm_status" =~ ^2[0-9][0-9]$ ]]; then
  printf 'READY %s retained ML operational permissions; skip duplicate grant\n' "$NODE"
else
  echo "membership resume cannot determine warm account state (url=$warm_endpoint http_status=${warm_status:-000} curl_exit=$warm_rc)" >&2
  exit 1
fi

if [[ "$(participant_onboarding_state "$participant_status")" != active ]]; then
  ML_HOST="$(node_ml_host "$NODE" || true)"
  if [[ -z "$ML_HOST" ]]; then
    step "Start colocated ML inference for $NODE"
    "$ROOT/03-join/start-local-ml.sh" "$NODE" "$MODEL_ID" "$MODEL_REVISION" \
      "$MLNODE_DTYPE" "$MLNODE_TENSOR_PARALLEL_SIZE" "$MLNODE_MAX_NUM_SEQS" \
      "$MLNODE_GPU_MEMORY_UTILIZATION" "$MLNODE_CONTEXT_LENGTH"
  fi
  step "Wait until $NODE is ACTIVE"
  "$ROOT/03-join/wait-active.sh" "https://$GENESIS_PUBLIC_HOST" "$ADDRESS"
fi
record_join_state "$NODE" PERMISSIONS_RECONCILED "$ADDRESS"
append_transition PERMISSIONS_RECONCILED
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
ML_HOST="$(node_ml_host "$NODE" || true)"
[[ -z "$ML_HOST" ]] || "$ROOT/scripts/phase-ml-attach.sh" "$NODE"

deploy=/srv/dai/deploy
consensus_pubkey="$(jq -er .consensus_pubkey "$IDENTITY")"
fence_remote="$deploy/.gdc/runs/$GDC_RUN_ID/signer-fence-receipt.v1.json"
step "Fence existing $NODE signer after membership reconciliation"
ssh "$NODE" "sudo '$deploy/fence-existing-signer.sh' '$deploy' '$GDC_RUN_ID' '$consensus_pubkey' '$NODE'"
ssh "$NODE" "sudo cat '$fence_remote'" >"$RUN/signer-fence-receipt.v1.json"
chmod 600 "$RUN/signer-fence-receipt.v1.json"
"$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$RUN/signer-fence-receipt.v1.json" --run-id "$GDC_RUN_ID" --consensus-pubkey "$consensus_pubkey"
record_join_state "$NODE" SIGNER_FENCE_VERIFIED "$ADDRESS"
append_transition SIGNER_FENCE_VERIFIED

step "Enable $NODE consensus signer after application and membership verification"
record_activation_guard
append_transition SIGNER_ACTIVATING true
before="$RUN/tmkms-signing-state-before-enable.json"
ssh "$NODE" "sudo cat '/srv/dai/signer/tmkms/state/priv_validator_state.json'" >"$before"
chmod 600 "$before"
status="$(ssh -T "$NODE" 'curl -fsS --max-time 10 http://127.0.0.1:26657/status')"
jq -e --slurpfile state "$before" '.result.sync_info.catching_up == false and (.result.sync_info.latest_block_height | tonumber) > ($state[0].height | tonumber)' <<<"$status" >/dev/null || {
  echo 'membership resume refused: canonical chain has not advanced beyond the signer minimum' >&2; exit 1;
}
ssh "$NODE" "cd '$deploy' && ./start-node.sh --enable-signer"
readback_deadline=$((SECONDS + 300))
until ssh "$NODE" "cd '$deploy' && ./verify-active-signer-state.sh '$deploy' '$expected_chain_id' '$expected_core_version'" >"$RUN/active-signer-readback.log" 2>&1; do
  if (( SECONDS >= readback_deadline )); then cat "$RUN/active-signer-readback.log" >&2; echo 'active signer readback did not pass after signer enablement' >&2; exit 1; fi
  printf 'WAIT active signer readback for %s: %s\n' "$NODE" "$(tail -n 1 "$RUN/active-signer-readback.log")"
  sleep 5
done
cat "$RUN/active-signer-readback.log"

advanced=false; signing_wait_seconds=300; signing_started=$SECONDS; deadline=$((SECONDS + signing_wait_seconds)); reported=0
while (( SECONDS < deadline )); do
  after="$RUN/tmkms-signing-state-after-enable.json"
  ssh "$NODE" "sudo cat '/srv/dai/signer/tmkms/state/priv_validator_state.json'" >"$after" || { sleep 2; continue; }
  chmod 600 "$after"
  if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$before" --observed "$after" --require-advance >/dev/null 2>"$RUN/tmkms-signing-wait.err"; then advanced=true; break; fi
  if (( SECONDS - signing_started >= reported + 60 )); then reported=$((SECONDS - signing_started)); printf 'WAIT first %s signature after signer enablement elapsed=%ss deadline=%ss last=%s\n' "$NODE" "$reported" "$signing_wait_seconds" "$(tail -n1 "$RUN/tmkms-signing-wait.err" 2>/dev/null || true)"; fi
  sleep 2
done
record_join_state "$NODE" SIGNER_ENABLED "$ADDRESS"
if [[ "$advanced" == true ]]; then append_transition SIGNER_ACTIVE_VERIFIED true; else append_transition SIGNER_ARMED_PENDING_ELIGIBILITY true; printf 'READY %s signer is armed; positive consensus eligibility remains pending accepted PoC evidence\n' "$NODE"; fi
"$ROOT/scripts/validator-backup.sh" create "$NODE" resume-membership
append_transition RECOVERY_ARCHIVE_VERIFIED true
if [[ "${GDC_JOIN_VERIFICATION:-false}" == true ]]; then
  "$ROOT/scripts/phase-join-acceptance.sh" "$NODE"
fi
append_transition COMPLETE true
printf 'PASS Host JOIN resumed after retained membership without duplicate registration or funding\n'
