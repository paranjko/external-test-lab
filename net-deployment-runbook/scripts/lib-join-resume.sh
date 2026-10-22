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

# Retain the exact full-sync lineage preflight after a verified single-seed
# canary. The post-sync verifier expects this canonical path and independently
# checks it against the retained preflight and canary proof. This repairs only
# an omitted copy; conflicting evidence is never replaced.
join_resume_retain_full_sync_lineage() {
  local operation="$1" boundary="$2" source="$RUN/lineage-preflight-canary.v1.json"
  local target="$RUN/lineage-state-sync-receipt.json" proof="$RUN/genesis-single-seed-canary.json"
  local canary_observation="$RUN/network-observation-canary.v1.json"
  local profile_sha observation_sha chain_id genesis_sha raw_genesis_sha seed_node seed_rpc bootstrap_sha bootstrap_url temp retained_chain retained_state head_name retained_head
  [[ ( "$operation" == new || "$operation" == restore ) && ( "$boundary" == canary || "$boundary" == canonical ) ]] || {
    echo 'invalid full-sync lineage retention context' >&2; return 2;
  }
  [[ -f "$source" && ! -L "$source" && -f "$proof" && ! -L "$proof" &&
    -f "$canary_observation" && ! -L "$canary_observation" &&
    -r "$GDC_JOIN_PROFILE" && -f "$IDENTITY" && ! -L "$IDENTITY" ]] || {
    echo 'full-sync lineage retention lacks regular retained proof inputs' >&2; return 1;
  }
  profile_sha="$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')"
  observation_sha="$(sha256sum "$GDC_JOIN_OBSERVATION" | awk '{print $1}')"
  chain_id="$(jq -er '.spec.network.chain_id' "$GDC_JOIN_PROFILE")"
  genesis_sha="$(jq -er '.spec.network.genesis_sha256' "$GDC_JOIN_PROFILE")"
  raw_genesis_sha="$(jq -er '.spec.network.bootstrap_genesis_sha256' "$GDC_JOIN_PROFILE")"
  bootstrap_sha="$(jq -er '.spec.network.bootstrap_sha256' "$GDC_JOIN_PROFILE")"
  bootstrap_url="$(jq -er '.spec.network.bootstrap_url' "$GDC_JOIN_PROFILE")"
  seed_node="$(jq -er '.bootstrap.seed.node_id' "$source")"
  seed_rpc="$(jq -er '.bootstrap.seed.rpc_url' "$source")"
  local join_node
  join_node="$(jq -er .node_id "$IDENTITY")"
  jq -e --arg chain "$chain_id" --arg genesis "$genesis_sha" --arg raw_genesis "$raw_genesis_sha" '
    .schema_version == 1 and .kind == "gdc-host-join-lineage-preflight" and
    .bootstrap.mode == "full_sync" and .bootstrap.chain_id == $chain and
    .bootstrap.genesis_sha256 == $genesis and
    .bootstrap.distribution_sha256 == $raw_genesis and
    (.bootstrap.seed.node_id | type == "string" and test("^[0-9a-f]{40}$")) and
    (.bootstrap.seed.rpc_url | type == "string" and test("^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?/chain-rpc$")) and
    (.bootstrap.seed.p2p | type == "string" and test("^tcp://[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$")) and
    .trust_authority == {kind:"genesis_single_seed",rpc_url:.bootstrap.seed.rpc_url} and
    (.runtime.network_fingerprint | type == "string" and test("^[0-9a-f]{64}$")) and
    .runtime.network_fingerprint == .runtime.source.id and
    (.runtime.observation_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.fault_domains | length) == 1 and
    .fault_domains[0].id == "genesis-single-seed" and
    .fault_domains[0].rpc_url == .bootstrap.seed.rpc_url and
    .fault_domains[0].chain_id == $chain and .fault_domains[0].genesis_sha256 == $genesis and
    (.fault_domains[0].host | type == "string" and test("^[A-Za-z0-9.-]+$")) and
    (.fault_domains[0].port | type == "number" and . > 0 and . <= 65535) and
    (.fault_domains[0].ip | type == "string" and test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")) and
    .checkpoints == null and ((.bootstrap | has("trust") or has("snapshot")) | not)
  ' "$source" >/dev/null || { echo 'full-sync lineage preflight does not match retained profile and single-seed schema' >&2; return 1; }
  jq -e --arg fingerprint "$(jq -er '.runtime.network_fingerprint' "$source")" \
    --arg source_id "$(jq -er '.runtime.source.id' "$source")" \
    --arg bootstrap_sha "$bootstrap_sha" --arg bootstrap_url "$bootstrap_url" \
    --arg chain "$chain_id" --arg genesis "$genesis_sha" --arg raw_genesis "$raw_genesis_sha" '
      .network_state_id == $fingerprint and .network_state_id == $source_id and
      .bootstrap.document_sha256 == $bootstrap_sha and .bootstrap.url == $bootstrap_url and
      .bootstrap.chain_id == $chain and .bootstrap.genesis_sha256 == $raw_genesis and
      .bootstrap.chain_identity_sha256 == $genesis and
      (.network_state_id | type == "string" and test("^[0-9a-f]{64}$"))
    ' "$canary_observation" >/dev/null \
    && [[ "$(jq -er '.runtime.observation_sha256' "$source")" == "$(sha256sum "$canary_observation" | awk '{print $1}')" ]] \
    || { echo 'full-sync lineage does not bind the retained canary network observation and reviewed Bootstrap' >&2; return 1; }
  jq -e --arg chain "$chain_id" --arg genesis "$genesis_sha" --arg seed "$seed_node" --arg rpc "$seed_rpc" --arg join "$join_node" '
    .schema_version == 1 and .kind == "gdc-genesis-single-seed-canary" and
    .chain_id == $chain and .genesis_sha256 == $genesis and
    .seed_node_id == $seed and .seed_rpc == $rpc and .join_node_id == $join and
    (.common_height | type == "number" and . > 0) and
    .common_block.height == .common_height and
    (.common_block.block_id | type == "string" and test("^[0-9A-Fa-f]{64}$")) and
    (.common_block.app_hash | type == "string" and test("^[0-9A-Fa-f]{64}$"))
  ' "$proof" >/dev/null || { echo 'full-sync canary proof does not match retained profile, seed, and JOIN identity' >&2; return 1; }

  retained_chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts")" || return 1
  retained_state="$(jq -er .last_state <<<"$retained_chain")"
  [[ "$(jq -r .signer_ever_started <<<"$retained_chain")" == false ]] || {
    echo 'full-sync lineage retention refuses a run whose signer was started' >&2; return 1;
  }
  head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
  retained_head="$receipts/$head_name"
  jq -e --arg run "$GDC_RUN_ID" --arg node "$NODE" --arg operation "$operation" \
    --arg state "$retained_state" --arg profile "$profile_sha" --arg observation "$observation_sha" '
      .run_id == $run and .generation_id == $run and .node_name == $node and
      .operation == $operation and .state == $state and
      .join_profile_sha256 == $profile and .network_observation_sha256 == $observation and
      .signer_ever_started == false
    ' "$retained_head" >/dev/null || { echo 'full-sync lineage retention receipt binding is invalid' >&2; return 1; }
  if [[ "$boundary" == canonical ]]; then
    [[ "$retained_state" == CANONICAL_RUNNING || "$retained_state" == APPLICATION_ACTIVE || "$retained_state" == CANONICAL_VERIFIED ]] || {
      echo 'full-sync lineage repair requires retained signerless canonical state' >&2; return 1;
    }
    jq -es --arg run "$GDC_RUN_ID" --arg node "$NODE" --arg operation "$operation" \
      --arg profile "$profile_sha" --arg observation "$observation_sha" --arg last "$retained_state" '
        length >= 3 and
        all(.[]; .run_id == $run and .generation_id == $run and .node_name == $node and
          .operation == $operation and .join_profile_sha256 == $profile and
          .network_observation_sha256 == $observation and .signer_ever_started == false) and
        any(.[]; .state == "CANARY_VERIFIED") and any(.[]; .state == "PROMOTED") and
        any(.[]; .state == "CANONICAL_RUNNING") and
        (.[-1].state == $last)
      ' "$receipts"/*.json >/dev/null 2>&1 || {
      echo 'full-sync lineage repair receipt chain lacks its retained canary and promotion proof' >&2; return 1;
    }
  else
    [[ "$retained_state" == CANARY_CAUGHT_UP ]] || {
      echo 'full-sync lineage retention requires a caught-up signerless canary' >&2; return 1;
    }
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]] && cmp -s "$source" "$target" || {
      echo 'full-sync lineage retention refuses to replace conflicting evidence' >&2; return 1;
    }
    return 0
  fi
  temp="$(mktemp "$RUN/.lineage-state-sync-receipt.XXXXXX")"
  if ! cp -- "$source" "$temp" || ! chmod 0600 "$temp" || ! sync -f "$temp" || ! ln -- "$temp" "$target"; then
    rm -f -- "$temp"
    if [[ -f "$target" && ! -L "$target" ]] && cmp -s "$source" "$target"; then return 0; fi
    echo 'failed to retain full-sync lineage proof without overwriting evidence' >&2
    return 1
  fi
  rm -f -- "$temp"
  sync -f "$RUN"
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
  [[ ( "$resume_state" == CANONICAL_RUNNING || "$resume_state" == APPLICATION_ACTIVE || ( "$operation" == new && "$resume_state" == CANONICAL_VERIFIED ) || ( "$operation" == restore && "$resume_state" == MEMBERSHIP_RECONCILED ) ) && "$(jq -r .signer_ever_started <<<"$chain")" == false ]] || {
    echo 'canonical resume requires retained signerless CANONICAL_RUNNING, APPLICATION_ACTIVE, new-JOIN CANONICAL_VERIFIED, or restore MEMBERSHIP_RECONCILED state' >&2; return 1;
  }
  head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
  head="$receipts/$head_name"
  jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" --arg operation "$operation" '
    .run_id == $run_id and .operation == $operation and .node_name == $node and
    (.state == "CANONICAL_RUNNING" or .state == "APPLICATION_ACTIVE" or ($operation == "new" and .state == "CANONICAL_VERIFIED") or ($operation == "restore" and .state == "MEMBERSHIP_RECONCILED")) and
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
  if [[ "$(jq -r '.bootstrap.mode // empty' "$RUN/lineage-preflight-canary.v1.json" 2>/dev/null || true)" == full_sync ]]; then
    join_resume_retain_full_sync_lineage "$operation" canonical || return 1
  fi
  [[ -r "$lineage" && ! -L "$lineage" ]] || { echo 'canonical resume lacks retained lineage receipt' >&2; return 1; }

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
  if [[ "$resume_state" != MEMBERSHIP_RECONCILED && "$resume_state" != CANONICAL_VERIFIED ]]; then
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
  local operation="$1" profile_sha observation_sha expected_chain expected_genesis
  [[ "$operation" == new || "$operation" == restore ]] || {
    echo 'invalid caught-up canary resume operation' >&2; return 2;
  }
  [[ -d "$RUN" && -n "${GDC_RUN_ID:-}" && -r "${GDC_JOIN_PROFILE:-}" && -r "${GDC_JOIN_OBSERVATION:-}" && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || {
    echo 'caught-up canary resume lacks retained run bindings' >&2; return 2;
  }

  receipts="$RUN/receipts"
  chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts")"
  resume_state="$(jq -er .last_state <<<"$chain")"
  [[ "$(jq -r .signer_ever_started <<<"$chain")" == false ]] || {
    echo 'caught-up canary resume refuses a run whose signer was started' >&2; return 1;
  }
  head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
  head="$receipts/$head_name"
  jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" --arg operation "$operation" --arg state "$resume_state" '
    .run_id == $run_id and .operation == $operation and .node_name == $node and
    .generation_id == $run_id and .state == $state and .signer_ever_started == false
  ' "$head" >/dev/null || { echo 'caught-up canary resume receipt binding is invalid' >&2; return 1; }

  IDENTITY="$IDENTITIES/$NODE.json"
  lineage="$RUN/lineage-preflight-canary.v1.json"
  [[ -r "$lineage" ]] || { echo 'caught-up canary resume lacks the retained canary lineage receipt' >&2; return 1; }
  bootstrap_mode="$(jq -er '.bootstrap.mode' "$lineage")" || {
    echo 'caught-up canary resume lineage lacks a recognized Bootstrap mode' >&2; return 1;
  }
  case "$bootstrap_mode" in
    state_sync)
      [[ "$resume_state" == CANARY_CAUGHT_UP ]] || {
        echo 'state-sync canary resume requires retained CANARY_CAUGHT_UP state' >&2; return 1;
      }
      ;;
    full_sync)
      [[ "$resume_state" == CANARY_RUNNING || "$resume_state" == CANARY_CAUGHT_UP ]] || {
        echo 'full-sync canary resume requires retained signerless CANARY_RUNNING or CANARY_CAUGHT_UP state' >&2; return 1;
      }
      profile_sha="$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')"
      observation_sha="$(sha256sum "$GDC_JOIN_OBSERVATION" | awk '{print $1}')"
      expected_chain="$(jq -er '.spec.network.chain_id' "$GDC_JOIN_PROFILE")"
      expected_genesis="$(jq -er '.spec.network.genesis_sha256' "$GDC_JOIN_PROFILE")"
      jq -e --arg profile "$profile_sha" --arg observation "$observation_sha" \
        '.join_profile_sha256 == $profile and .network_observation_sha256 == $observation
        ' "$head" >/dev/null || { echo 'full-sync canary resume profile or observation binding is invalid' >&2; return 1; }
      jq -e --arg chain "$expected_chain" --arg genesis "$expected_genesis" '
          .bootstrap.mode == "full_sync" and .bootstrap.chain_id == $chain and
          .bootstrap.genesis_sha256 == $genesis and
          .trust_authority.kind == "genesis_single_seed" and
          (.fault_domains | length) == 1 and (.checkpoints == null) and
          ((.bootstrap | has("trust") or has("snapshot")) | not)
        ' "$lineage" >/dev/null || { echo 'full-sync canary resume single-seed lineage binding is invalid' >&2; return 1; }
      jq -e '.spec.state_acquisition.mode == "pending" and (.spec.state_acquisition.providers | length) == 0 and .spec.state_acquisition.minimum_providers == 0' \
        "$GDC_JOIN_PROFILE" >/dev/null || { echo 'full-sync canary resume profile unexpectedly enables state-sync providers' >&2; return 1; }
      ;;
    *) echo 'caught-up canary resume refuses an unsupported lineage mode' >&2; return 1 ;;
  esac

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
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  remote="/tmp/gdc-${operation}-canary-resume-${GDC_RUN_ID}-${NODE}"
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  deploy=/srv/dai/deploy
  # shellcheck disable=SC2034 # Bound here for the immediately following caught-up resume phase.
  generation="/srv/dai/data.generations/${GDC_RUN_ID}"
}
