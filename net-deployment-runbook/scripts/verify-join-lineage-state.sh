#!/usr/bin/env bash
# Verify a restored JOIN node at a fresh post-sync checkpoint. State sync does
# not retain early historical blocks, so receipt checkpoints are evidence for
# the remote trust quorum only and must never be queried from the new node.
set -Eeuo pipefail
[[ $# -eq 2 || ( $# -eq 3 && "$3" == --resume-current ) ]] || { echo "Usage: $0 JOIN_RPC_URL LINEAGE_RECEIPT [--resume-current]" >&2; exit 2; }
rpc="${1%/}"; receipt="$2"; resume_current="${3:-}"
[[ ( "$rpc" =~ ^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?/chain-rpc$ || "$rpc" == http://127.0.0.1:26657 ) && -r "$receipt" ]] || { echo 'invalid lineage verification input' >&2; exit 2; }
[[ "$(jq -r '.bootstrap.mode // empty' "$receipt")" == state_sync ]] || { echo 'lineage_verification_failed: receipt is not a state-sync contract' >&2; exit 1; }
if [[ "$resume_current" != --resume-current ]]; then
  expires_at="$(jq -er '.bootstrap.trust.expires_at // empty' "$receipt" 2>/dev/null || true)"
  expires_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null || true)"
  [[ "$expires_epoch" =~ ^[0-9]+$ && "$expires_epoch" -gt "$(date -u +%s)" ]] || {
    echo 'lineage_trust_expired: state-sync trust receipt has expired; run a fresh JOIN lineage preflight before accepting the canary' >&2
    exit 1
  }
fi

status_height() {
  local endpoint="$1" host="${2:-}" port="${3:-}" ip="${4:-}"; shift 4 || true
  local -a resolve=()
  [[ -z "$host" ]] || resolve=(--resolve "${host}:${port}:${ip}")
  curl -fsS --connect-timeout 5 --max-time 15 "${resolve[@]}" "${endpoint%/}/status" |
    jq -er '.result.sync_info.latest_block_height | tonumber'
}
block_record() {
  local endpoint="$1" height="$2" host="${3:-}" port="${4:-}" ip="${5:-}"; shift 5 || true
  local -a resolve=()
  [[ -z "$host" ]] || resolve=(--resolve "${host}:${port}:${ip}")
  curl -fsS --connect-timeout 5 --max-time 15 "${resolve[@]}" "${endpoint%/}/block?height=$height" |
    jq -cer '{height:(.result.block.header.height|tonumber),block_id:(.result.block_id.hash|ascii_downcase),app_hash:(.result.block.header.app_hash|ascii_downcase)}'
}

mapfile -t trusted_origins < <(jq -r '.fault_domains[] | [.rpc_url,.host,(.port|tostring),.ip] | @tsv' "$receipt")
trusted_rpcs=()
for origin in "${trusted_origins[@]}"; do IFS=$'\t' read -r origin_rpc origin_host origin_port origin_ip <<<"$origin"; trusted_rpcs+=("$origin_rpc")
done
required_origins=2
if jq -e '.trust_authority.kind == "operator_source" and (.fault_domains | length) == 1 and .trust_authority.rpc_url == .fault_domains[0].rpc_url' "$receipt" >/dev/null; then
  required_origins=1
fi
(( ${#trusted_rpcs[@]} >= required_origins )) || { echo 'lineage_verification_failed: receipt lacks the required trusted RPC origins' >&2; exit 1; }
join_height="$(status_height "$rpc")" || { echo 'lineage_verification_failed: cannot read restored JOIN height' >&2; exit 1; }
heights=("$join_height")
for origin in "${trusted_origins[@]}"; do
  IFS=$'\t' read -r origin_rpc origin_host origin_port origin_ip <<<"$origin"
  height="$(status_height "$origin_rpc" "$origin_host" "$origin_port" "$origin_ip")" || { echo "lineage_verification_failed: cannot read trusted RPC height from $origin_rpc" >&2; exit 1; }
  heights+=("$height")
done
mapfile -t ordered < <(printf '%s\n' "${heights[@]}" | LC_ALL=C sort -n)
fresh_height="${ordered[0]}"
trust_height="$(jq -er '.bootstrap.trust.height | tonumber' "$receipt")"
(( fresh_height > trust_height )) || { echo 'lineage_verification_failed: restored JOIN has not reached a post-trust checkpoint' >&2; exit 1; }

declare -a origin_records=()
for origin in "${trusted_origins[@]}"; do
  IFS=$'\t' read -r origin_rpc origin_host origin_port origin_ip <<<"$origin"
  origin_records+=("$(block_record "$origin_rpc" "$fresh_height" "$origin_host" "$origin_port" "$origin_ip")") || { echo "lineage_verification_failed: cannot read fresh checkpoint from $origin_rpc" >&2; exit 1; }
done
mapfile -t unique < <(printf '%s\n' "${origin_records[@]}" | LC_ALL=C sort -u)
(( ${#unique[@]} == 1 )) || { echo 'lineage_verification_failed: trusted RPC origins disagree at fresh checkpoint' >&2; exit 1; }
actual="$(block_record "$rpc" "$fresh_height")" || { echo 'lineage_verification_failed: cannot read fresh checkpoint from restored JOIN' >&2; exit 1; }
[[ "$actual" == "${unique[0]}" ]] || { echo 'apphash_divergence: restored JOIN disagrees with trusted origins at fresh checkpoint' >&2; exit 1; }
printf 'PASS JOIN fresh post-sync checkpoint matches recorded trust origins=%s height=%s\n' "${#trusted_rpcs[@]}" "$fresh_height"
