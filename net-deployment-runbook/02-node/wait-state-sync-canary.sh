#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 DEPLOY_DIR REFERENCE_RPC" >&2; exit 2; }
deploy="$1"; reference="${2%/}"
[[ -d "$deploy" && "$reference" =~ ^https://[A-Za-z0-9.-]+/chain-rpc$ ]] || { echo 'invalid canary wait input' >&2; exit 2; }
deadline=$((SECONDS + ${GDC_JOIN_SYNC_TIMEOUT_SECONDS:-3600}))
while (( SECONDS < deadline )); do
  local_status="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" exec -T node sh -c 'curl -fsS http://127.0.0.1:26657/status' 2>/dev/null || true)"
  reference_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$reference/status" 2>/dev/null || true)"
  local_height="$(jq -r '.result.sync_info.latest_block_height // 0' <<<"$local_status" 2>/dev/null || true)"
  reference_height="$(jq -r '.result.sync_info.latest_block_height // 0' <<<"$reference_status" 2>/dev/null || true)"
  catching_up="$(jq -r '.result.sync_info.catching_up // true' <<<"$local_status" 2>/dev/null || true)"
  if [[ "$local_height" =~ ^[1-9][0-9]*$ && "$reference_height" =~ ^[1-9][0-9]*$ && "$catching_up" == false && "$local_height" -ge "$reference_height" ]]; then
    printf 'PASS signerless state-sync canary caught up height=%s\n' "$local_height"
    exit 0
  fi
  sleep 15
done
echo 'lineage_snapshot_unavailable: signerless P2P canary did not restore and catch up before deadline' >&2
exit 1
