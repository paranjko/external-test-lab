#!/usr/bin/env bash
# Shared signerless boundary for the two receipt-bound JOIN resumptions. Source
# this only after lib.sh has loaded the retained project configuration.
# shellcheck source=lib-post-sync-join.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-post-sync-join.sh"

join_resume_append_transition() {
  local state="$1" signer_started="${2:-false}" input
  input="$(mktemp "$RUN/.join-resume-transition.XXXXXX")"
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

join_resume_prepare_post_sync() {
  local operation="$1" label
  [[ "$operation" == new || "$operation" == restore ]] || {
    echo 'invalid canonical resume operation' >&2; return 2;
  }
  [[ -d "$RUN" && -n "${GDC_RUN_ID:-}" && -r "${GDC_JOIN_PROFILE:-}" && -r "${GDC_JOIN_OBSERVATION:-}" && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || {
    echo 'canonical resume lacks retained run bindings' >&2; return 2;
  }

  receipts="$RUN/receipts"
  chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts")"
  resume_state="$(jq -r .last_state <<<"$chain")"
  [[ ( "$resume_state" == CANONICAL_RUNNING || "$resume_state" == APPLICATION_ACTIVE || ( "$operation" == restore && "$resume_state" == MEMBERSHIP_RECONCILED ) ) && "$(jq -r .signer_ever_started <<<"$chain")" == false ]] || {
    echo 'canonical resume requires retained signerless CANONICAL_RUNNING, APPLICATION_ACTIVE, or restore MEMBERSHIP_RECONCILED state' >&2; return 1;
  }
  head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
  head="$receipts/$head_name"
  jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" --arg operation "$operation" '
    .run_id == $run_id and .operation == $operation and .node_name == $node and
    (.state == "CANONICAL_RUNNING" or .state == "APPLICATION_ACTIVE" or ($operation == "restore" and .state == "MEMBERSHIP_RECONCILED")) and
    .signer_ever_started == false
  ' "$head" >/dev/null || { echo 'canonical resume receipt binding is invalid' >&2; return 1; }

  IDENTITY="$IDENTITIES/$NODE.json"
  [[ -r "$IDENTITY" ]] || { echo 'canonical resume lacks retained identity' >&2; return 1; }
  ADDRESS="$(jq -er .identity_fingerprints.participant_address "$head")"
  if [[ "$operation" == new ]]; then
    # load_project in lib.sh owns the operator account root.
    # shellcheck disable=SC2153
    ACCOUNT="$ACCOUNTS/$NODE-cold.json"
    [[ -r "$ACCOUNT" && "$(jq -er .address "$ACCOUNT")" == "$ADDRESS" ]] || {
      echo 'new canonical resume cold account does not match the retained participant' >&2; return 1;
    }
  fi
  expected_chain_id="$(jq -er '.spec.network.chain_id' "$GDC_JOIN_PROFILE")"
  expected_p2p_node_id="$(jq -er .node_id "$IDENTITY")"
  expected_core_version="$(jq -er '.spec.components.core.expected_runtime.version' "$GDC_JOIN_PROFILE")"
  expected_core_commit="$(jq -er '.spec.components.core.expected_runtime.commit' "$GDC_JOIN_PROFILE")"
  expected_dapi_version="$(jq -er '.spec.components.dapi.expected_runtime.version' "$GDC_JOIN_PROFILE")"
  expected_dapi_commit="$(jq -er '.spec.components.dapi.expected_runtime.commit' "$GDC_JOIN_PROFILE")"
  lineage="$RUN/lineage-state-sync-receipt.json"
  [[ -r "$lineage" ]] || { echo 'canonical resume lacks retained lineage receipt' >&2; return 1; }

  remote="/tmp/gdc-${operation}-canonical-resume-${GDC_RUN_ID}-${NODE}"
  # The validated local staging path is intentionally expanded before SSH.
  # shellcheck disable=SC2029
  ssh "$NODE" "rm -rf '$remote' && mkdir -p '$remote'"
  scp -q "$ROOT/scripts/verify-join-lineage-state.sh" "$NODE:$remote/verify-join-lineage-state.sh"
  scp -q "$lineage" "$NODE:$remote/lineage-receipt.json"

  deploy=/srv/dai/deploy
  # The fixed deployment path is intentionally expanded before SSH.
  # shellcheck disable=SC2029
  tmkms="$(ssh "$NODE" "cd '$deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms")"
  [[ -z "$(printf '%s\n' "$tmkms" | sed '/^$/d')" ]] || { echo 'canonical resume refused: signer is already running' >&2; return 1; }
  if [[ "$resume_state" == CANONICAL_RUNNING ]]; then
    "$ROOT/03-join/restart-api-after-sync.sh" "$NODE"
    join_resume_append_transition APPLICATION_ACTIVE
  fi
  # Match the uninterrupted JOIN ordering: the local API/ML runtime must be
  # available for canonical readback, but participant-facing auxiliary
  # services are not started until the promoted generation matches the fresh
  # common checkpoint.
  join_verify_promoted_signerless_state \
    "$NODE" "$RUN" "$GDC_JOIN_PROFILE" "$remote" "$expected_chain_id" "$expected_p2p_node_id" \
    "$expected_core_version" "$expected_core_commit" "$expected_dapi_version" "$expected_dapi_commit"
  join_start_verified_auxiliary_services "$NODE" "$PUBLIC_EDGE_NODE"
  if [[ "$resume_state" != MEMBERSHIP_RECONCILED ]]; then
    join_resume_append_transition CANONICAL_VERIFIED
  fi
  label="$operation"
  printf 'READY %s retained signerless canonical state verified\n' "$label"
}

# Bind the one earlier safe interruption point to the retained candidate
# generation.  The caller must still prove the canary's current checkpoint,
# stop it, promote its generation, and start canonical Core before it may use
# join_resume_prepare_post_sync.
join_resume_prepare_caught_up_canary() {
  local operation="$1"
  [[ "$operation" == new || "$operation" == restore ]] || {
    echo 'invalid caught-up canary resume operation' >&2; return 2;
  }
  [[ -d "$RUN" && -n "${GDC_RUN_ID:-}" && -r "${GDC_JOIN_PROFILE:-}" && -r "${GDC_JOIN_OBSERVATION:-}" && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || {
    echo 'caught-up canary resume lacks retained run bindings' >&2; return 2;
  }

  receipts="$RUN/receipts"
  chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts")"
  [[ "$(jq -r .last_state <<<"$chain")" == CANARY_CAUGHT_UP && "$(jq -r .signer_ever_started <<<"$chain")" == false ]] || {
    echo 'caught-up canary resume requires retained signerless CANARY_CAUGHT_UP state' >&2; return 1;
  }
  head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
  head="$receipts/$head_name"
  jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" --arg operation "$operation" '
    .run_id == $run_id and .operation == $operation and .node_name == $node and
    .state == "CANARY_CAUGHT_UP" and .signer_ever_started == false
  ' "$head" >/dev/null || { echo 'caught-up canary resume receipt binding is invalid' >&2; return 1; }

  IDENTITY="$IDENTITIES/$NODE.json"
  [[ -r "$IDENTITY" ]] || { echo 'caught-up canary resume lacks retained identity' >&2; return 1; }
  ADDRESS="$(jq -er .identity_fingerprints.participant_address "$head")"
  if [[ "$operation" == new ]]; then
    # load_project in lib.sh owns the operator account root.
    # shellcheck disable=SC2153
    ACCOUNT="$ACCOUNTS/$NODE-cold.json"
    [[ -r "$ACCOUNT" && "$(jq -er .address "$ACCOUNT")" == "$ADDRESS" ]] || {
      echo 'caught-up canary resume cold account does not match the retained participant' >&2; return 1;
    }
  fi
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  warm_mnemonic="$GDC_HOME/mnemonics/$NODE-warm.mnemonic"
  [[ -r "$warm_mnemonic" ]] || { echo 'caught-up canary resume lacks retained warm mnemonic' >&2; return 1; }
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  warm_address="$(jq -er .warm_address "$IDENTITY")"
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  lineage="$RUN/lineage-preflight-canary.v1.json"
  [[ -r "$lineage" ]] || { echo 'caught-up canary resume lacks the retained canary lineage receipt' >&2; return 1; }
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  remote="/tmp/gdc-${operation}-canary-resume-${GDC_RUN_ID}-${NODE}"
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  deploy=/srv/dai/deploy
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  generation="/srv/dai/data.generations/${GDC_RUN_ID}"
}
