#!/usr/bin/env bash
# Verify a promoted signerless generation after the canary consumed its
# short-lived trust tuple. The current checkpoint remains mandatory.
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --node NODE --run-dir DIR --profile FILE --remote-dir DIR --expected-chain-id ID --expected-p2p-node-id ID --expected-core-version VERSION --expected-core-commit SHA --expected-dapi-version VERSION --expected-dapi-commit SHA" >&2
}

NODE=''; RUN=''; PROFILE=''; REMOTE=''
EXPECTED_CHAIN_ID=''; EXPECTED_P2P_NODE_ID=''; EXPECTED_CORE_VERSION=''; EXPECTED_CORE_COMMIT=''
EXPECTED_DAPI_VERSION=''; EXPECTED_DAPI_COMMIT=''
while (($#)); do
  case "$1" in
    --node) NODE="${2:-}"; shift 2 ;;
    --run-dir) RUN="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --remote-dir) REMOTE="${2:-}"; shift 2 ;;
    --expected-chain-id) EXPECTED_CHAIN_ID="${2:-}"; shift 2 ;;
    --expected-p2p-node-id) EXPECTED_P2P_NODE_ID="${2:-}"; shift 2 ;;
    --expected-core-version) EXPECTED_CORE_VERSION="${2:-}"; shift 2 ;;
    --expected-core-commit) EXPECTED_CORE_COMMIT="${2:-}"; shift 2 ;;
    --expected-dapi-version) EXPECTED_DAPI_VERSION="${2:-}"; shift 2 ;;
    --expected-dapi-commit) EXPECTED_DAPI_COMMIT="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$NODE" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && -d "$RUN/receipts" && -r "$PROFILE" ]] || {
  echo 'invalid post-sync JOIN verification input' >&2; exit 2;
}
[[ "$REMOTE" =~ ^/tmp/gdc-[A-Za-z0-9._-]+$ && "$EXPECTED_CHAIN_ID" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && "$EXPECTED_P2P_NODE_ID" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'invalid post-sync JOIN verification input' >&2; exit 2;
}

profile_sha256="$(sha256sum "$PROFILE" | awk '{print $1}')"
chain="$("$(dirname "$0")/verify-join-receipt-chain.sh" --receipt-dir "$RUN/receipts")"
[[ "$(jq -r .signer_ever_started <<<"$chain")" == false ]] || {
  echo 'post-sync JOIN verification requires a signerless receipt chain' >&2; exit 1;
}
last_state="$(jq -r .last_state <<<"$chain")"
[[ "$last_state" == APPLICATION_ACTIVE || "$last_state" == CANONICAL_VERIFIED || "$last_state" == MEMBERSHIP_RECONCILED ]] || {
  echo 'post-sync JOIN verification requires APPLICATION_ACTIVE, CANONICAL_VERIFIED, or retained MEMBERSHIP_RECONCILED receipt state' >&2; exit 1;
}

mapfile -t receipts < <(find "$RUN/receipts" -maxdepth 1 -type f -name '*.json' -printf '%p\n' | LC_ALL=C sort)
jq -es --arg run_id "${GDC_RUN_ID:-}" --arg node "$NODE" --arg profile "$profile_sha256" '
  length > 0 and
  all(.[]; .run_id == $run_id and .generation_id == $run_id and .node_name == $node and .join_profile_sha256 == $profile and .signer_ever_started == false) and
  any(.[]; .state == "CANARY_VERIFIED") and any(.[]; .state == "PROMOTED") and any(.[]; .state == "APPLICATION_ACTIVE")
' "${receipts[@]}" >/dev/null || {
  echo 'post-sync JOIN receipt proof is incomplete or does not match this run' >&2; exit 1;
}
if [[ "$last_state" == MEMBERSHIP_RECONCILED ]]; then
  jq -es 'any(.[]; .state == "CANONICAL_VERIFIED")' "${receipts[@]}" >/dev/null || {
    echo 'post-sync JOIN membership resume lacks prior canonical verification' >&2; exit 1;
  }
fi

# The retained preflight receipt is the authoritative discriminator here: the
# immutable join profile binds network/runtime inputs, while Bootstrap chooses
# either state-sync trust or the explicitly opted-in single-seed full-sync
# contract. Both modes share the same canonical runtime and generation proof.
lineage="$RUN/lineage-state-sync-receipt.json"
[[ -r "$lineage" && ! -L "$lineage" ]] || {
  echo 'post-sync JOIN verification lacks its retained lineage receipt' >&2; exit 1;
}
preflight_lineage="$RUN/lineage-preflight-canary.v1.json"
lineage_mode="$(jq -er '.bootstrap.mode' "$lineage")"
jq -e --arg chain "$EXPECTED_CHAIN_ID" '.spec.network.chain_id == $chain' "$PROFILE" >/dev/null \
  || { echo 'post-sync JOIN profile chain does not match its expected chain' >&2; exit 1; }
case "$lineage_mode" in
  state_sync)
    ;;
  full_sync)
    [[ -r "$preflight_lineage" && ! -L "$preflight_lineage" \
      && "$(sha256sum "$lineage" | awk '{print $1}')" == "$(sha256sum "$preflight_lineage" | awk '{print $1}')" ]] || {
      echo 'post-sync JOIN full-sync receipt differs from the retained canary preflight' >&2; exit 1;
    }
    jq -e --arg chain "$EXPECTED_CHAIN_ID" --arg genesis "$(jq -er '.spec.network.genesis_sha256' "$PROFILE")" '
      .schema_version == 1 and .kind == "gdc-host-join-lineage-preflight" and
      .bootstrap.mode == "full_sync" and .bootstrap.chain_id == $chain and
      .bootstrap.genesis_sha256 == $genesis and
      (.bootstrap.genesis_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.bootstrap.seed.node_id | type == "string" and test("^[0-9a-f]{40}$")) and
      (.bootstrap.seed.rpc_url | type == "string" and test("^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?/chain-rpc$")) and
      .trust_authority.kind == "genesis_single_seed" and
      .trust_authority.rpc_url == .bootstrap.seed.rpc_url and
      (.fault_domains | length) == 1 and
      .fault_domains[0].id == "genesis-single-seed" and
      .fault_domains[0].rpc_url == .bootstrap.seed.rpc_url and
      .fault_domains[0].chain_id == $chain and
      .fault_domains[0].genesis_sha256 == .bootstrap.genesis_sha256 and
      .checkpoints == null
    ' "$lineage" >/dev/null || {
      echo 'post-sync JOIN full-sync lineage receipt does not match the single-seed contract' >&2; exit 1;
    }
    jq -e --arg chain "$EXPECTED_CHAIN_ID" --arg genesis "$(jq -er '.bootstrap.genesis_sha256' "$lineage")" \
      --arg seed "$(jq -er '.bootstrap.seed.node_id' "$lineage")" \
      --arg rpc "$(jq -er '.bootstrap.seed.rpc_url' "$lineage")" --arg join "$EXPECTED_P2P_NODE_ID" '
        .kind == "gdc-genesis-single-seed-canary" and .chain_id == $chain and
        .genesis_sha256 == $genesis and .seed_node_id == $seed and .seed_rpc == $rpc and
        .join_node_id == $join and (.common_height | type == "number" and . > 0) and
        (.common_block.height | type == "number" and . > 0)
      ' "$RUN/genesis-single-seed-canary.json" >/dev/null 2>&1 || {
      echo 'post-sync JOIN lacks a retained full-sync canary receipt bound to this seed, Genesis, and identity' >&2; exit 1;
    }
    ;;
  *)
    echo "post-sync JOIN lineage receipt has unsupported bootstrap mode: $lineage_mode" >&2
    exit 1
    ;;
esac

generation="/srv/dai/data.generations/${GDC_RUN_ID:?GDC_RUN_ID is required}"
deploy=/srv/dai/deploy
active_data=/srv/dai/data
local_output=''; remote_output=''
if [[ "$lineage_mode" == full_sync ]]; then
  local_output="$RUN/full-sync-post-canonical-canary.$(date -u +%Y%m%dT%H%M%SZ).$$.json"
  remote_output="$REMOTE/$(basename "$local_output")"
  remote_lineage="$REMOTE/post-canonical-lineage.$(date -u +%Y%m%dT%H%M%SZ).$$.json"
  [[ ! -e "$local_output" ]] || { echo 'post-canonical full-sync evidence path already exists' >&2; exit 1; }
  scp -q "$lineage" "$NODE:$remote_lineage"
  scp -q "$(dirname "$0")/verify-genesis-single-seed-canary.sh" "$NODE:$REMOTE/verify-genesis-single-seed-canary.sh"
else
  remote_lineage="$REMOTE/lineage-receipt.json"
fi
ssh "$NODE" bash -s -- "$NODE" "$generation" "$REMOTE" "$EXPECTED_CHAIN_ID" "$EXPECTED_P2P_NODE_ID" "$EXPECTED_CORE_VERSION" "$EXPECTED_CORE_COMMIT" "$EXPECTED_DAPI_VERSION" "$EXPECTED_DAPI_COMMIT" "$deploy" "$active_data" "$lineage_mode" "$remote_output" "$remote_lineage" <<'EOF'
set -Eeuo pipefail
node="$1"; generation="$2"; remote="$3"; chain_id="$4"; p2p_node_id="$5"
core_version="$6"; core_commit="$7"; dapi_version="$8"; dapi_commit="$9"
deploy="${10}"; active_data="${11}"; lineage_mode="${12}"; output="${13}"; lineage="${14}"
jq -e --arg node "$node" --arg generation "$generation" '
  .schema_version == 1 and .kind == "gdc-state-sync-promotion" and
  .state == "PROMOTED" and .node_name == $node and .generation == $generation
' "$deploy/.promotion-receipt.json" >/dev/null
test -L "$active_data"
test "$(readlink "$active_data")" = "$generation"
cd "$deploy"
bash "$deploy/verify-canonical-join-state.sh" "$deploy" "$chain_id" "$p2p_node_id" "$core_version" "$core_commit" "$dapi_version" "$dapi_commit"
if [[ "$lineage_mode" == full_sync ]]; then
  bash "$remote/verify-genesis-single-seed-canary.sh" \
    "$lineage" http://127.0.0.1:26657 "$p2p_node_id" "$output"
else
  bash "$remote/verify-join-lineage-state.sh" http://127.0.0.1:26657 "$lineage" --resume-current
fi
EOF
if [[ "$lineage_mode" == full_sync ]]; then
  scp -q "$NODE:$remote_output" "$local_output"
  chmod 0600 "$local_output"
  jq -e --arg chain "$(jq -er '.bootstrap.chain_id' "$lineage")" \
    --arg genesis "$(jq -er '.bootstrap.genesis_sha256' "$lineage")" \
    --arg seed "$(jq -er '.bootstrap.seed.node_id' "$lineage")" \
    --arg rpc "$(jq -er '.bootstrap.seed.rpc_url' "$lineage")" \
    --arg join "$EXPECTED_P2P_NODE_ID" '
      .kind == "gdc-genesis-single-seed-canary" and .chain_id == $chain and
      .genesis_sha256 == $genesis and .seed_node_id == $seed and .seed_rpc == $rpc and
      .join_node_id == $join and (.common_height | type == "number" and . > 0) and
      (.common_block.height | type == "number" and . > 0) and
      (.common_block.block_id | type == "string" and test("^[0-9A-Fa-f]+$")) and
      (.common_block.app_hash | type == "string" and test("^[0-9A-Fa-f]+$"))
    ' "$local_output" >/dev/null || {
      echo 'post-canonical full-sync canary evidence does not match its retained lineage receipt' >&2; exit 1;
    }
fi
printf 'PASS JOIN post-sync current state matches the verified promoted signerless generation\n'
