#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 DEPLOY_DIR REFERENCE_RPC" >&2; exit 2; }
deploy="$1"; reference="${2%/}"
[[ -d "$deploy" && "$reference" =~ ^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?/chain-rpc$ ]] || { echo 'invalid canary wait input' >&2; exit 2; }
max_lag="${GDC_JOIN_CANARY_MAX_LAG_BLOCKS:-5}"
[[ "$max_lag" =~ ^[0-9]+$ ]] || { echo 'invalid canary lag bound' >&2; exit 2; }
timeout_seconds="${GDC_JOIN_SYNC_TIMEOUT_SECONDS:-3600}"
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || { echo 'invalid canary sync timeout' >&2; exit 2; }
started_seconds=$SECONDS
deadline=$((started_seconds + timeout_seconds))
last_local_height=unknown
last_reference_height=unknown
last_lag=unknown
last_catching_up=unknown
previous_local_height=unknown
previous_reference_height=unknown
previous_observed_seconds=unknown
while (( SECONDS < deadline )); do
  # `inferenced` images do not promise an in-container curl binary. The node
  # RPC is deliberately loopback-published by compose, so observe it from the
  # Host instead of making a tool-presence assumption inside the runtime.
  local_status="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status 2>/dev/null || true)"
  reference_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$reference/status" 2>/dev/null || true)"
  local_height="$(jq -r '.result.sync_info.latest_block_height // 0' <<<"$local_status" 2>/dev/null || true)"
  reference_height="$(jq -r '.result.sync_info.latest_block_height // 0' <<<"$reference_status" 2>/dev/null || true)"
  catching_up="$(jq -r 'if .result.sync_info.catching_up == true then "true" elif .result.sync_info.catching_up == false then "false" else "true" end' <<<"$local_status" 2>/dev/null || true)"
  last_local_height="$local_height"
  last_reference_height="$reference_height"
  last_catching_up="$catching_up"
  lag=unknown
  if [[ "$local_height" =~ ^[1-9][0-9]*$ && "$reference_height" =~ ^[1-9][0-9]*$ && "$catching_up" == false ]]; then
    lag=$((reference_height - local_height))
    last_lag="$lag"
    if (( lag <= max_lag )); then
      printf 'PASS signerless state-sync canary caught up height=%s reference=%s lag=%s\n' "$local_height" "$reference_height" "$lag"
      exit 0
    fi
  fi
  if [[ "$lag" == unknown && "$local_height" =~ ^[1-9][0-9]*$ && "$reference_height" =~ ^[1-9][0-9]*$ ]]; then
    lag=$((reference_height - local_height))
    last_lag="$lag"
  fi
  elapsed_seconds=$((SECONDS - started_seconds))
  progress_local_delta=unknown
  progress_reference_delta=unknown
  progress_net_delta=unknown
  progress_state=unavailable
  progress_rate_blocks_per_minute=unknown
  progress_estimated_remaining_seconds=unknown
  if [[ "$previous_local_height" =~ ^[1-9][0-9]*$ && "$previous_reference_height" =~ ^[1-9][0-9]*$ && "$previous_observed_seconds" =~ ^[0-9]+$ && "$local_height" =~ ^[1-9][0-9]*$ && "$reference_height" =~ ^[1-9][0-9]*$ ]]; then
    progress_elapsed_seconds=$((elapsed_seconds - previous_observed_seconds))
    progress_local_delta=$((local_height - previous_local_height))
    progress_reference_delta=$((reference_height - previous_reference_height))
    progress_net_delta=$((progress_local_delta - progress_reference_delta))
    if (( progress_net_delta > 0 )); then
      progress_state=advancing
      if (( progress_elapsed_seconds > 0 && lag > 0 )); then
        progress_rate_blocks_per_minute=$((progress_net_delta * 60 / progress_elapsed_seconds))
        progress_estimated_remaining_seconds=$(((lag * progress_elapsed_seconds + progress_net_delta - 1) / progress_net_delta))
      fi
    elif (( progress_net_delta == 0 )); then
      progress_state=stalled
    else
      progress_state=falling_behind
    fi
  fi
  remaining_seconds=$((deadline - SECONDS))
  (( remaining_seconds >= 0 )) || remaining_seconds=0
  printf 'WAIT signerless P2P canary syncing local_height=%s reference_height=%s lag=%s catching_up=%s elapsed_seconds=%s remaining_seconds=%s\n' \
    "$local_height" "$reference_height" "$lag" "$catching_up" "$elapsed_seconds" "$remaining_seconds"
  if [[ "$progress_net_delta" != unknown ]]; then
    printf 'WAIT signerless P2P canary progress local_delta=%s reference_delta=%s net_delta=%s state=%s rate_blocks_per_minute=%s estimated_remaining_seconds=%s\n' \
      "$progress_local_delta" "$progress_reference_delta" "$progress_net_delta" "$progress_state" "$progress_rate_blocks_per_minute" "$progress_estimated_remaining_seconds"
  fi
  previous_local_height="$local_height"
  previous_reference_height="$reference_height"
  previous_observed_seconds="$elapsed_seconds"
  sleep 15
done
echo "lineage_snapshot_unavailable: signerless P2P canary exceeded lag bound max_lag=$max_lag before deadline last_local_height=$last_local_height last_reference_height=$last_reference_height last_lag=$last_lag last_catching_up=$last_catching_up" >&2
exit 1
