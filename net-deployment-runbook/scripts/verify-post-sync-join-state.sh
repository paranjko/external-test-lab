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
[[ "$last_state" == APPLICATION_ACTIVE || "$last_state" == MEMBERSHIP_RECONCILED ]] || {
  echo 'post-sync JOIN verification requires APPLICATION_ACTIVE or retained MEMBERSHIP_RECONCILED receipt state' >&2; exit 1;
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

generation="/srv/dai/data.generations/${GDC_RUN_ID:?GDC_RUN_ID is required}"
ssh "$NODE" bash -s -- "$NODE" "$generation" "$REMOTE" "$EXPECTED_CHAIN_ID" "$EXPECTED_P2P_NODE_ID" "$EXPECTED_CORE_VERSION" "$EXPECTED_CORE_COMMIT" "$EXPECTED_DAPI_VERSION" "$EXPECTED_DAPI_COMMIT" <<'EOF'
set -Eeuo pipefail
node="$1"; generation="$2"; remote="$3"; chain_id="$4"; p2p_node_id="$5"
core_version="$6"; core_commit="$7"; dapi_version="$8"; dapi_commit="$9"
deploy=/srv/dai/deploy
jq -e --arg node "$node" --arg generation "$generation" '
  .schema_version == 1 and .kind == "gdc-state-sync-promotion" and
  .state == "PROMOTED" and .node_name == $node and .generation == $generation
' "$deploy/.promotion-receipt.json" >/dev/null
test -L /srv/dai/data
test "$(readlink /srv/dai/data)" = "$generation"
cd "$deploy"
bash "$deploy/verify-canonical-join-state.sh" "$deploy" "$chain_id" "$p2p_node_id" "$core_version" "$core_commit" "$dapi_version" "$dapi_commit"
bash "$remote/verify-join-lineage-state.sh" http://127.0.0.1:26657 "$remote/lineage-receipt.json" --resume-current
EOF
printf 'PASS JOIN post-sync current state matches the verified promoted signerless generation\n'
