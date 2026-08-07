#!/usr/bin/env bash
set -Eeuo pipefail

gateway_env="${GDC_GATEWAY_ENV:-/srv/dai/ops/gateway.env}"
output="${GDC_GATEWAY_HEALTH_FILE:-/srv/dai/ops/status/gateway-health.json}"
gateway_url="${GDC_GATEWAY_HEALTH_URL:-http://127.0.0.1:18080}"
reconciliation_file="${GDC_GATEWAY_RECONCILIATION_FILE:-/srv/dai/ops/status/gateway-reconciliation.json}"
mkdir -p "$(dirname "$output")"
tmp="${output}.tmp"
response="$(mktemp)"
trap 'rm -f "$tmp" "$response"' EXIT

started_ms="$(date +%s%3N)"
state=UNAVAILABLE
reason=credentials_unavailable
http_code=0

if [[ -s "$reconciliation_file" ]] && jq -e '.state == "RECOVERING"' "$reconciliation_file" >/dev/null 2>&1; then
  state=RECOVERING
  reason="$(jq -r '.reason // "replacement_escrow_recovering"' "$reconciliation_file")"
fi
if [[ -s "$reconciliation_file" ]] && jq -e '.state == "FAILED"' "$reconciliation_file" >/dev/null 2>&1; then
  state=UNAVAILABLE
  reason="$(jq -r '.reason // "replacement_escrow_failed"' "$reconciliation_file")"
fi

if [[ "$state" == UNAVAILABLE && "$reason" == credentials_unavailable && -s "$gateway_env" ]]; then
  # The public status must describe the credential a visitor can actually
  # receive, not a privileged technical key.  A successful technical probe
  # while Telegram-pool keys receive 429 is an availability false positive.
  pool_file="${GDC_GATEWAY_PUBLIC_KEY_POOL_FILE:-/srv/dai/gonka-devnet-bot/gateway-key-pool.json}"
  client_key=''
  if [[ -s "$pool_file" ]]; then
    client_key="$(jq -r '.keys[]? // empty' "$pool_file" | head -n1)"
  fi
  [[ -n "$client_key" ]] || client_key="$(awk -F= '$1 == "DEVSHARD_API_KEYS" {print $2; exit}' "$gateway_env" | cut -d, -f1)"
  model="$(awk -F= '$1 == "DEVSHARD_MODEL" {print substr($0, index($0, "=") + 1); exit}' "$gateway_env")"
  if [[ -n "$client_key" && -n "$model" ]]; then
    payload="$(jq -cn --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:8}')"
    set +e
    http_code="$(curl -sS --connect-timeout 3 --max-time 20 -o "$response" -w '%{http_code}' \
      "$gateway_url/v1/chat/completions" \
      -H "Authorization: Bearer $client_key" \
      -H 'Content-Type: application/json' \
      --data "$payload")"
    curl_rc=$?
    set -e
    if [[ "$curl_rc" == 0 && "$http_code" == 200 ]] \
      && jq -e '.choices | type == "array" and length > 0' "$response" >/dev/null 2>&1; then
      state=READY
      reason=completion_succeeded
    elif [[ "$curl_rc" != 0 ]]; then
      reason=request_failed
    elif [[ "$http_code" != 200 ]]; then
      reason="http_${http_code}"
    else
      reason=invalid_completion
    fi
  fi
fi

finished_ms="$(date +%s%3N)"
latency_ms=$((finished_ms - started_ms))
checked_at="$(date -u +%FT%TZ)"
if [[ "$http_code" =~ ^[0-9]{3}$ ]]; then
  http_status=$((10#$http_code))
else
  http_status=0
fi
jq -n \
  --arg state "$state" \
  --arg checked_at "$checked_at" \
  --arg reason "$reason" \
  --argjson http_status "$http_status" \
  --argjson latency_ms "$latency_ms" \
  '{state:$state,checked_at:$checked_at,http_status:$http_status,latency_ms:$latency_ms,reason:$reason}' >"$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$output"
