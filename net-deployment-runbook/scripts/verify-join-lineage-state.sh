#!/usr/bin/env bash
# Verify a restored JOIN node at a fresh post-sync checkpoint. State sync does
# not retain early historical blocks, so receipt checkpoints are evidence for
# the remote trust quorum only and must never be queried from the new node.
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 JOIN_RPC_URL LINEAGE_RECEIPT" >&2; exit 2; }
rpc="${1%/}"; receipt="$2"
[[ ( "$rpc" =~ ^https://[A-Za-z0-9.-]+/chain-rpc$ || "$rpc" == http://127.0.0.1:26657 ) && -r "$receipt" ]] || { echo 'invalid lineage verification input' >&2; exit 2; }

status_height() {
  curl -fsS --connect-timeout 5 --max-time 15 "${1%/}/status" |
    jq -er '.result.sync_info.latest_block_height | tonumber'
}
block_record() {
  curl -fsS --connect-timeout 5 --max-time 15 "${1%/}/block?height=$2" |
    jq -cer '{height:(.result.block.header.height|tonumber),block_id:(.result.block_id.hash|ascii_downcase),app_hash:(.result.block.header.app_hash|ascii_downcase)}'
}

mapfile -t trusted_rpcs < <(jq -r '.fault_domains[].rpc_url' "$receipt")
(( ${#trusted_rpcs[@]} >= 2 )) || { echo 'lineage_verification_failed: receipt lacks two trusted RPC origins' >&2; exit 1; }
join_height="$(status_height "$rpc")" || { echo 'lineage_verification_failed: cannot read restored JOIN height' >&2; exit 1; }
heights=("$join_height")
for origin in "${trusted_rpcs[@]}"; do
  height="$(status_height "$origin")" || { echo "lineage_verification_failed: cannot read trusted RPC height from $origin" >&2; exit 1; }
  heights+=("$height")
done
mapfile -t ordered < <(printf '%s\n' "${heights[@]}" | LC_ALL=C sort -n)
fresh_height="${ordered[0]}"
trust_height="$(jq -er '.bootstrap.trust.height | tonumber' "$receipt")"
(( fresh_height > trust_height )) || { echo 'lineage_verification_failed: restored JOIN has not reached a post-trust checkpoint' >&2; exit 1; }

declare -a origin_records=()
for origin in "${trusted_rpcs[@]}"; do
  origin_records+=("$(block_record "$origin" "$fresh_height")") || { echo "lineage_verification_failed: cannot read fresh checkpoint from $origin" >&2; exit 1; }
done
mapfile -t unique < <(printf '%s\n' "${origin_records[@]}" | LC_ALL=C sort -u)
(( ${#unique[@]} == 1 )) || { echo 'lineage_verification_failed: trusted RPC origins disagree at fresh checkpoint' >&2; exit 1; }
actual="$(block_record "$rpc" "$fresh_height")" || { echo 'lineage_verification_failed: cannot read fresh checkpoint from restored JOIN' >&2; exit 1; }
[[ "$actual" == "${unique[0]}" ]] || { echo 'apphash_divergence: restored JOIN disagrees with trusted origins at fresh checkpoint' >&2; exit 1; }
printf 'PASS JOIN fresh post-sync checkpoint matches independent trust origins height=%s\n' "$fresh_height"
