#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 DEPLOY_DIR REFERENCE_RPC" >&2; exit 2; }
deploy="$1"; reference="${2%/}"
[[ -d "$deploy" && "$reference" =~ ^https://[A-Za-z0-9.-]+/chain-rpc$ ]] || { echo 'invalid canary wait input' >&2; exit 2; }
max_lag="${GDC_JOIN_CANARY_MAX_LAG_BLOCKS:-5}"
[[ "$max_lag" =~ ^[0-9]+$ ]] || { echo 'invalid canary lag bound' >&2; exit 2; }
deadline=$((SECONDS + ${GDC_JOIN_SYNC_TIMEOUT_SECONDS:-3600}))
while (( SECONDS < deadline )); do
  # `inferenced` images do not promise an in-container curl binary. The node
  # RPC is deliberately loopback-published by compose, so observe it from the
  # Host instead of making a tool-presence assumption inside the runtime.
  local_status="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status 2>/dev/null || true)"
  reference_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$reference/status" 2>/dev/null || true)"
  local_height="$(jq -r '.result.sync_info.latest_block_height // 0' <<<"$local_status" 2>/dev/null || true)"
  reference_height="$(jq -r '.result.sync_info.latest_block_height // 0' <<<"$reference_status" 2>/dev/null || true)"
  catching_up="$(jq -r 'if .result.sync_info.catching_up == true then "true" elif .result.sync_info.catching_up == false then "false" else "true" end' <<<"$local_status" 2>/dev/null || true)"
  if [[ "$local_height" =~ ^[1-9][0-9]*$ && "$reference_height" =~ ^[1-9][0-9]*$ && "$catching_up" == false ]]; then
    lag=$((reference_height - local_height))
    if (( lag <= max_lag )); then
      printf 'PASS signerless state-sync canary caught up height=%s reference=%s lag=%s\n' "$local_height" "$reference_height" "$lag"
      exit 0
    fi
  fi
  sleep 15
done
echo "lineage_snapshot_unavailable: signerless P2P canary exceeded lag bound max_lag=$max_lag before deadline" >&2
exit 1
