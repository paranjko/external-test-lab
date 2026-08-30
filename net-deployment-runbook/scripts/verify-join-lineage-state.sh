#!/usr/bin/env bash
# Compare a caught-up JOIN endpoint with the immutable preflight receipt.
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 JOIN_RPC_URL LINEAGE_RECEIPT" >&2; exit 2; }
rpc="${1%/}"; receipt="$2"
[[ "$rpc" =~ ^https://[A-Za-z0-9.-]+/chain-rpc$ && -r "$receipt" ]] || { echo 'invalid lineage verification input' >&2; exit 2; }
expires_at="$(jq -er '.bootstrap.trust.expires_at' "$receipt")" || { echo 'lineage_verification_failed: receipt lacks a trust expiry' >&2; exit 1; }
expires_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null || true)"
[[ "$expires_epoch" =~ ^[0-9]+$ && "$expires_epoch" -gt "$(date -u +%s)" ]] || { echo 'trust_expired: lineage receipt is no longer safe to resume' >&2; exit 1; }
for checkpoint in early post_upgrade trust; do
  height="$(jq -er --arg checkpoint "$checkpoint" '.checkpoints[$checkpoint].height' "$receipt")"
  expected="$(jq -cer --arg checkpoint "$checkpoint" '.checkpoints[$checkpoint] | {height,block_id,app_hash}' "$receipt")"
  actual="$(curl -fsS --connect-timeout 5 --max-time 15 "$rpc/block?height=$height" | jq -cer '{height:(.result.block.header.height|tonumber),block_id:(.result.block_id.hash|ascii_downcase),app_hash:(.result.block.header.app_hash|ascii_downcase)}')" \
    || { echo "lineage_verification_failed: cannot observe $checkpoint checkpoint" >&2; exit 1; }
  [[ "$actual" == "$expected" ]] || { echo "apphash_divergence: JOIN endpoint disagrees at $checkpoint checkpoint" >&2; exit 1; }
done
printf 'PASS JOIN lineage checkpoints match independent preflight receipt\n'
