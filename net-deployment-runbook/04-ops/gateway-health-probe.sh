#!/usr/bin/env bash
set -Eeuo pipefail

gateway_env="${GDC_GATEWAY_ENV:-/srv/dai/ops/gateway.env}"
output="${GDC_GATEWAY_HEALTH_FILE:-/srv/dai/ops/status/gateway-health.json}"
gateway_url="${GDC_GATEWAY_HEALTH_URL:-}"
# Public health runs every ten seconds. Keep its acknowledgement within the
# same small, bounded response budget as gateway verification so it observes
# a constrained one-model PoC without consuming the participant's window.
max_output_tokens="${GDC_GATEWAY_HEALTH_MAX_OUTPUT_TOKENS:-8}"
reconciliation_file="${GDC_GATEWAY_RECONCILIATION_FILE:-/srv/dai/ops/status/gateway-reconciliation.json}"
reserve_file="${GDC_GATEWAY_RESERVE_FILE:-/srv/dai/ops/status/gateway-reserve.json}"
mkdir -p "$(dirname "$output")"
tmp="$(mktemp "${output}.tmp.XXXXXX")"
response="$(mktemp)"
response_headers="$(mktemp)"
curl_error="$(mktemp)"
trap 'rm -f "$tmp" "$response" "$response_headers" "$curl_error"' EXIT

started_ms="$(date +%s%3N)"
state=UNAVAILABLE
reason=credentials_unavailable
http_code=0
curl_exit=0
recovery_escrow=''
recovery_started_at=''
next_check_seconds=0
admission='not_observed'
admission_id=''
arrival_height=0
permit_height=0
dispatch_height=0
response_height=0
safe_generation=''
[[ "$max_output_tokens" =~ ^[1-9][0-9]*$ ]] || {
  echo 'GDC_GATEWAY_HEALTH_MAX_OUTPUT_TOKENS must be a positive integer' >&2
  exit 2
}

if [[ -s "$reconciliation_file" ]]; then
  reconciliation_state="$(jq -er '.state | strings' "$reconciliation_file" 2>/dev/null || true)"
  reconciliation_reason="$(jq -r '.reason // empty' "$reconciliation_file" 2>/dev/null || true)"
  recovery_escrow="$(jq -r '.replacement_escrow // empty' "$reconciliation_file" 2>/dev/null || true)"
  recovery_started_at="$(jq -r '.entered_at // .checked_at // empty' "$reconciliation_file" 2>/dev/null || true)"
  case "$reconciliation_state" in
    READY)
      ;;
    RECOVERING)
      state=RECOVERING
      reason="${reconciliation_reason:-replacement_escrow_recovering}"
      next_check_seconds=15
      ;;
    PENDING)
      state=RECOVERING
      reason="${reconciliation_reason:-gateway_reconciliation_pending}"
      next_check_seconds=15
      ;;
    DEGRADED)
      state=DEGRADED
      reason="${reconciliation_reason:-gateway_reconciliation_degraded}"
      ;;
    FAILED)
      state=UNAVAILABLE
      reason="${reconciliation_reason:-replacement_escrow_failed}"
      ;;
    *)
      state=UNAVAILABLE
      reason=reconciliation_state_invalid
      ;;
  esac
fi

if [[ "$state" == UNAVAILABLE && "$reason" == credentials_unavailable && -s "$gateway_env" ]]; then
  # Readiness uses the gateway-owned assurance credential. Consumer services
  # such as Telegram must not control or mask the gateway state.
  client_key="$(awk -F= '$1 == "DEVSHARD_API_KEYS" {print $2; exit}' "$gateway_env" | cut -d, -f1)"
  model="$(awk -F= '$1 == "DEVSHARD_MODEL" {print substr($0, index($0, "=") + 1); exit}' "$gateway_env")"
  if [[ -z "$gateway_url" ]]; then
    gateway_url="$(awk -F= '$1 == "GDC_GATEWAY_ADMISSION_URL" {print substr($0, index($0, "=") + 1); exit}' "$gateway_env")"
  fi
  if [[ -z "$gateway_url" ]]; then
    api_host="$(awk -F= '$1 == "API_HOST" {print substr($0, index($0, "=") + 1); exit}' "$(dirname "$gateway_env")/.env" 2>/dev/null || true)"
    [[ "$api_host" =~ ^[A-Za-z0-9.-]+$ ]] && gateway_url="https://$api_host"
  fi
  if [[ -n "$client_key" && -n "$model" && "$gateway_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
    # READY must prove a bounded completion without consuming capacity needed
    # by interactive requests during a one-model PoC.
    payload="$(jq -cn --arg model "$model" --argjson max_tokens "$max_output_tokens" '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:$max_tokens}')"
    set +e
    request_deadline_ms="$(( $(date +%s%3N) + 20000 ))"
    http_code="$(curl -sS --connect-timeout 3 --max-time 20 -D "$response_headers" -o "$response" -w '%{http_code}' \
      "$gateway_url/v1/chat/completions" \
      -H "Authorization: Bearer $client_key" \
      -H "X-Request-Deadline-Ms: $request_deadline_ms" \
      -H 'Content-Type: application/json' \
      --data "$payload" 2>"$curl_error")"
    curl_rc=$?
    curl_exit=$curl_rc
    set -e
    header_value() {
      local name="$1"
      awk -v name="$name" 'tolower($0) ~ "^" tolower(name) ":" { value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/\r$/, "", value); print value; exit }' "$response_headers"
    }
    candidate_admission="$(header_value X-GDC-Admission)"
    candidate_admission_id="$(header_value X-GDC-Admission-ID)"
    candidate_arrival_height="$(header_value X-GDC-Arrival-Height)"
    candidate_permit_height="$(header_value X-GDC-Permit-Height)"
    candidate_dispatch_height="$(header_value X-GDC-Dispatch-Height)"
    candidate_response_height="$(header_value X-GDC-Response-Height)"
    candidate_safe_generation="$(header_value X-GDC-Safe-Generation)"
    [[ "$candidate_admission" =~ ^(dispatched_once|pre_dispatch_rejected|dispatch_attempt_failed)$ ]] && admission="$candidate_admission"
    [[ "$candidate_admission_id" =~ ^[a-f0-9]{32}$ ]] && admission_id="$candidate_admission_id"
    [[ "$candidate_arrival_height" =~ ^[0-9]+$ ]] && arrival_height="$candidate_arrival_height"
    [[ "$candidate_permit_height" =~ ^[0-9]+$ ]] && permit_height="$candidate_permit_height"
    [[ "$candidate_dispatch_height" =~ ^[0-9]+$ ]] && dispatch_height="$candidate_dispatch_height"
    [[ "$candidate_response_height" =~ ^[0-9]+$ ]] && response_height="$candidate_response_height"
    [[ "$candidate_safe_generation" =~ ^[A-Za-z0-9:,_-]{1,256}$ ]] && safe_generation="$candidate_safe_generation"
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
  elif [[ -n "$client_key" && -n "$model" ]]; then
    reason=admission_url_unavailable
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
  --arg admission "$admission" \
  --arg admission_id "$admission_id" \
  --arg safe_generation "$safe_generation" \
  --arg recovery_escrow "$recovery_escrow" \
  --arg recovery_started_at "$recovery_started_at" \
  --argjson http_status "$http_status" \
  --argjson curl_exit "$curl_exit" \
  --argjson latency_ms "$latency_ms" \
  --argjson arrival_height "$arrival_height" \
  --argjson permit_height "$permit_height" \
  --argjson dispatch_height "$dispatch_height" \
  --argjson response_height "$response_height" \
  --argjson next_check_seconds "$next_check_seconds" \
  '{state:$state,checked_at:$checked_at,http_status:$http_status,curl_exit:$curl_exit,latency_ms:$latency_ms,reason:$reason,admission:$admission,admission_id:$admission_id,safe_generation:$safe_generation,arrival_height:$arrival_height,permit_height:$permit_height,dispatch_height:$dispatch_height,response_height:$response_height}
   + if $state == "RECOVERING" and $recovery_started_at != "" then {
       recovery:{stage:$reason,escrow_id:$recovery_escrow,started_at:$recovery_started_at,next_check_seconds:$next_check_seconds}
     } else {} end' >"$tmp"
chmod 0644 "$tmp"
mv -fT -- "$tmp" "$output"
