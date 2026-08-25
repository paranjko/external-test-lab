#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 5 ]] || {
  echo 'Usage: capture-poc-snapshot.sh CHAIN_BASE TARGET_ANCHOR WINDOW_BLOCKS TIMEOUT_SECONDS OUTPUT_JSON' >&2
  exit 2
}

chain_base="${1%/}"
target_anchor="$2"
window_blocks="$3"
timeout_seconds="$4"
output="$5"
[[ "$chain_base" =~ ^https?:// && "$target_anchor" =~ ^[1-9][0-9]*$ && "$window_blocks" =~ ^[1-9][0-9]*$ && "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo 'invalid PoC snapshot capture arguments' >&2
  exit 2
}

deadline=$((SECONDS + timeout_seconds))
last_height=0
while (( SECONDS < deadline )); do
  height="$(curl -fsS --connect-timeout 5 --max-time 15 "$chain_base/chain-rpc/status" | jq -er '.result.sync_info.latest_block_height | tonumber')" || {
    sleep 1
    continue
  }
  last_height="$height"
  if (( height < target_anchor )); then
    sleep 1
    continue
  fi
  if (( height > target_anchor + window_blocks )); then
    break
  fi
  snapshot="$(curl -sS --connect-timeout 5 --max-time 15 "$chain_base/chain-api/productscience/inference/inference/preserved_nodes_snapshot" || true)"
  if jq -e --argjson target "$target_anchor" '.found == true and (.snapshot | type == "object") and (.snapshot.episode_anchor_height | tonumber? == $target)' <<<"$snapshot" >/dev/null 2>&1; then
    temp="$(mktemp "${output}.tmp.XXXXXX")"
    jq --arg captured_at "$(date -u +%FT%TZ)" --argjson captured_height "$height" '. + {capture:{captured_at:$captured_at,captured_height:$captured_height}}' <<<"$snapshot" >"$temp"
    chmod 0644 "$temp"
    mv -fT "$temp" "$output"
    exit 0
  fi
  sleep 1
done
printf 'PoC snapshot for anchor %s was not captured before height %s\n' "$target_anchor" "$last_height" >&2
exit 2
