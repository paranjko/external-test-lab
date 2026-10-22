#!/usr/bin/env bash
# Prove a full-sync JOIN canary matches its single declared Genesis seed.
set -Eeuo pipefail
[[ $# -eq 4 ]] || { echo "Usage: $0 LINEAGE_RECEIPT JOIN_RPC EXPECTED_NODE_ID OUTPUT" >&2; exit 2; }
receipt="$1"; join_rpc="${2%/}"; expected_join_node="$3"; output="$4"
[[ -r "$receipt" && "$join_rpc" == http://127.0.0.1:26657 ]] || { echo 'invalid single-seed canary inputs' >&2; exit 2; }
[[ "$expected_join_node" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid expected JOIN node ID' >&2; exit 2; }
jq -e '.bootstrap.mode == "full_sync" and .trust_authority.kind == "genesis_single_seed" and (.fault_domains|length) == 1' "$receipt" >/dev/null \
  || { echo 'lineage_verification_failed: receipt is not a single-seed full-sync contract' >&2; exit 1; }
source_rpc="$(jq -er '.bootstrap.seed.rpc_url' "$receipt")"
source_node="$(jq -er '.bootstrap.seed.node_id' "$receipt")"
source_host="$(jq -er '.fault_domains[0].host' "$receipt")"
source_port="$(jq -er '.fault_domains[0].port' "$receipt")"
source_ip="$(jq -er '.fault_domains[0].ip' "$receipt")"
chain_id="$(jq -er '.bootstrap.chain_id' "$receipt")"
genesis_sha="$(jq -er '.bootstrap.genesis_sha256' "$receipt")"
[[ "$source_host" =~ ^[A-Za-z0-9.-]+$ && "$source_port" =~ ^[1-9][0-9]{0,4}$ && "$source_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  || { echo 'lineage_verification_failed: invalid pinned seed endpoint in receipt' >&2; exit 1; }
seed_status="$(curl -fsS --connect-timeout 5 --max-time 15 --resolve "$source_host:$source_port:$source_ip" "${source_rpc%/}/status")"
join_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$join_rpc/status")"
jq -e --arg node "$source_node" --arg chain "$chain_id" '
  .result.node_info.id == $node and .result.node_info.network == $chain and
  (.result.sync_info.latest_block_height|tonumber) > 0
' <<<"$seed_status" >/dev/null || { echo 'lineage_verification_failed: pinned seed status differs from declared node or chain' >&2; exit 1; }
jq -e --arg chain "$chain_id" '
  .result.node_info.network == $chain and .result.sync_info.catching_up == false and
  (.result.sync_info.latest_block_height|tonumber) > 0
' <<<"$join_status" >/dev/null || { echo 'lineage_verification_failed: joining canary is not caught up on the expected chain' >&2; exit 1; }
jq -e --arg node "$expected_join_node" '.result.node_info.id == $node' <<<"$join_status" >/dev/null \
  || { echo 'lineage_verification_failed: joining canary node ID differs from its prepared identity' >&2; exit 1; }
seed_height="$(jq -er '.result.sync_info.latest_block_height|tonumber' <<<"$seed_status")"
join_height="$(jq -er '.result.sync_info.latest_block_height|tonumber' <<<"$join_status")"
height="$seed_height"; (( join_height < height )) && height="$join_height"
seed_block="$(curl -fsS --connect-timeout 5 --max-time 15 --resolve "$source_host:$source_port:$source_ip" "${source_rpc%/}/block?height=$height" | jq -cer '{height:(.result.block.header.height|tonumber),block_id:(.result.block_id.hash|ascii_downcase),app_hash:(.result.block.header.app_hash|ascii_downcase)}')"
join_block="$(curl -fsS --connect-timeout 5 --max-time 15 "$join_rpc/block?height=$height" | jq -cer '{height:(.result.block.header.height|tonumber),block_id:(.result.block_id.hash|ascii_downcase),app_hash:(.result.block.header.app_hash|ascii_downcase)}')"
[[ "$seed_block" == "$join_block" ]] || { echo 'apphash_divergence: full-sync JOIN differs from its declared Genesis seed at common height' >&2; exit 1; }
mkdir -p "$(dirname "$output")"
jq -n --arg chain "$chain_id" --arg genesis "$genesis_sha" --arg seed "$source_node" --arg rpc "$source_rpc" --arg join "$expected_join_node" --argjson height "$height" --argjson block "$seed_block" \
  '{schema_version:1,kind:"gdc-genesis-single-seed-canary",chain_id:$chain,genesis_sha256:$genesis,seed_node_id:$seed,seed_rpc:$rpc,join_node_id:$join,common_height:$height,common_block:$block}' >"$output"
chmod 0600 "$output"
printf 'PASS full-sync signerless canary matches declared seed at height=%s\n' "$height"
