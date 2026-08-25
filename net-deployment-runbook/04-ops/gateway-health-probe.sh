#!/usr/bin/env bash
set -Eeuo pipefail

gateway_env="${GDC_GATEWAY_ENV:-/srv/dai/ops/gateway.env}"
output="${GDC_GATEWAY_HEALTH_FILE:-/srv/dai/ops/status/gateway-health.json}"
gateway_url="${GDC_GATEWAY_HEALTH_URL:-http://127.0.0.1:18080}"
max_output_tokens="${GDC_GATEWAY_HEALTH_MAX_OUTPUT_TOKENS:-512}"
reconciliation_file="${GDC_GATEWAY_RECONCILIATION_FILE:-/srv/dai/ops/status/gateway-reconciliation.json}"
reserve_file="${GDC_GATEWAY_RESERVE_FILE:-/srv/dai/ops/status/gateway-reserve.json}"
mkdir -p "$(dirname "$output")"
tmp="$(mktemp "${output}.tmp.XXXXXX")"
response="$(mktemp)"
curl_error="$(mktemp)"
trap 'rm -f "$tmp" "$response" "$curl_error"' EXIT

started_ms="$(date +%s%3N)"
state=UNAVAILABLE
reason=credentials_unavailable
http_code=0
curl_exit=0
recovery_escrow=''
recovery_started_at=''
next_check_seconds=0
[[ "$max_output_tokens" =~ ^[1-9][0-9]*$ ]] || {
  echo 'GDC_GATEWAY_HEALTH_MAX_OUTPUT_TOKENS must be a positive integer' >&2
  exit 2
}

if [[ -s "$reconciliation_file" ]] && jq -e '.state == "RECOVERING"' "$reconciliation_file" >/dev/null 2>&1; then
  state=RECOVERING
  reason="$(jq -r '.reason // "replacement_escrow_recovering"' "$reconciliation_file")"
  recovery_escrow="$(jq -r '.replacement_escrow // empty' "$reconciliation_file")"
  recovery_started_at="$(jq -r '.entered_at // .checked_at // empty' "$reconciliation_file")"
  next_check_seconds=15
fi
if [[ -s "$reconciliation_file" ]] && jq -e '.state == "FAILED"' "$reconciliation_file" >/dev/null 2>&1; then
  state=UNAVAILABLE
  reason="$(jq -r '.reason // "replacement_escrow_failed"' "$reconciliation_file")"
  recovery_escrow="$(jq -r '.replacement_escrow // empty' "$reconciliation_file")"
  recovery_started_at="$(jq -r '.entered_at // .checked_at // empty' "$reconciliation_file")"
fi

if [[ "$state" == UNAVAILABLE && "$reason" == credentials_unavailable && -s "$gateway_env" ]]; then
  # Readiness uses the gateway-owned assurance credential. Consumer services
  # such as Telegram must not control or mask the gateway state.
  client_key="$(awk -F= '$1 == "DEVSHARD_API_KEYS" {print $2; exit}' "$gateway_env" | cut -d, -f1)"
  model="$(awk -F= '$1 == "DEVSHARD_MODEL" {print substr($0, index($0, "=") + 1); exit}' "$gateway_env")"
  if [[ -n "$client_key" && -n "$model" ]]; then
    # READY must prove the same response budget offered to interactive
    # consumers. A tiny probe can pass while normal requests are rejected for
    # exhausted participant capacity, which would mislead the public status.
    payload="$(jq -cn --arg model "$model" --argjson max_tokens "$max_output_tokens" '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:$max_tokens}')"
    set +e
    http_code="$(curl -sS --connect-timeout 3 --max-time 20 -o "$response" -w '%{http_code}' \
      "$gateway_url/v1/chat/completions" \
      -H "Authorization: Bearer $client_key" \
      -H 'Content-Type: application/json' \
      --data "$payload" 2>"$curl_error")"
    curl_rc=$?
    curl_exit=$curl_rc
    set -e
    if [[ "$curl_rc" == 0 && "$http_code" == 200 ]] \
      && jq -e '.choices | type == "array" and length > 0' "$response" >/dev/null 2>&1; then
      gateway_status="$(curl -fsS --connect-timeout 3 --max-time 10 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" 2>/dev/null || true)"
      if ! "$(dirname "$0")/gateway-status-routable.sh" <<<"$gateway_status" >/dev/null 2>&1; then
        state=UNAVAILABLE
        reason=runtime_not_routable
      elif ! jq -e '.state == "READY" and (.current_balance|tonumber) >= (.low_watermark|tonumber)' "$reserve_file" >/dev/null 2>&1; then
        state=DEGRADED
        reason=escrow_reserve_low
      else
        state=READY
        reason=completion_succeeded
      fi
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
  --arg recovery_escrow "$recovery_escrow" \
  --arg recovery_started_at "$recovery_started_at" \
  --argjson http_status "$http_status" \
  --argjson curl_exit "$curl_exit" \
  --argjson latency_ms "$latency_ms" \
  --argjson next_check_seconds "$next_check_seconds" \
  '{state:$state,checked_at:$checked_at,http_status:$http_status,curl_exit:$curl_exit,latency_ms:$latency_ms,reason:$reason}
   + if $state == "RECOVERING" and $recovery_started_at != "" then {
       recovery:{stage:$reason,escrow_id:$recovery_escrow,started_at:$recovery_started_at,next_check_seconds:$next_check_seconds}
     } else {} end' >"$tmp"
chmod 0644 "$tmp"
mv -fT -- "$tmp" "$output"
