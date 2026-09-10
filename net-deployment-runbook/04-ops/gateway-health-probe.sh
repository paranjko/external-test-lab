#!/usr/bin/env bash
set -Eeuo pipefail

gateway_env="${GDC_GATEWAY_ENV:-/srv/dai/ops/gateway.env}"
output="${GDC_GATEWAY_HEALTH_FILE:-/srv/dai/ops/status/gateway-health.json}"
prom_output="${GDC_GATEWAY_HEALTH_PROM_FILE:-${output%.json}.prom}"
gateway_url="${GDC_GATEWAY_HEALTH_URL:-}"
# Public health runs every ten seconds. Keep its acknowledgement within the
# same small, bounded response budget as gateway verification so it observes
# a constrained one-model PoC without consuming the participant's window.
max_output_tokens="${GDC_GATEWAY_HEALTH_MAX_OUTPUT_TOKENS:-8}"
reconciliation_file="${GDC_GATEWAY_RECONCILIATION_FILE:-/srv/dai/ops/status/gateway-reconciliation.json}"
reserve_file="${GDC_GATEWAY_RESERVE_FILE:-/srv/dai/ops/status/gateway-reserve.json}"
mkdir -p "$(dirname "$output")"
tmp="$(mktemp "${output}.tmp.XXXXXX")"
prom_tmp="$(mktemp "${prom_output}.tmp.XXXXXX")"
response="$(mktemp)"
response_headers="$(mktemp)"
curl_error="$(mktemp)"
trap 'rm -f "$tmp" "$prom_tmp" "$response" "$response_headers" "$curl_error"' EXIT

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
readiness=UNAVAILABLE
completion_observed=false
completion_finished_ms=0
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
    canary_nonce="${started_ms}-$$-${RANDOM}"
    # The gateway validates top-level Chat Completions fields before dispatch.
    # Put the per-request cache buster in supported message content instead of
    # inventing a top-level parameter. The gateway cache key includes the
    # normalized request body, so this produces a distinct admission attempt.
    canary_prompt="Reply with OK [readiness-canary:${canary_nonce}]"
    payload="$(jq -cn --arg model "$model" --arg prompt "$canary_prompt" --argjson max_tokens "$max_output_tokens" '{model:$model,messages:[{role:"user",content:$prompt}],max_tokens:$max_tokens}')"
    set +e
    request_deadline_ms="$(( $(date +%s%3N) + 20000 ))"
    http_code="$(curl -sS --connect-timeout 3 --max-time 20 -D "$response_headers" -o "$response" -w '%{http_code}' \
      "$gateway_url/v1/chat/completions?gdc_canary=$canary_nonce" \
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
    [[ "$candidate_safe_generation" =~ ^sha256:[a-f0-9]{64}$ ]] && safe_generation="$candidate_safe_generation"
    if [[ "$curl_rc" == 0 && "$http_code" == 200 ]] \
      && [[ "$admission" == dispatched_once ]] \
      && [[ "$admission_id" =~ ^[a-f0-9]{32}$ ]] \
      && [[ -n "$safe_generation" ]] \
      && (( arrival_height > 0 && arrival_height <= permit_height && permit_height <= dispatch_height && dispatch_height <= response_height )) \
      && jq -e '.choices | type == "array" and length > 0' "$response" >/dev/null 2>&1; then
      completion_observed=true
      # This timestamp belongs to the completed canary itself, before the
      # follow-up status read. Consumers can therefore distinguish an old
      # completion from one executed during their verification window.
      completion_finished_ms="$(date +%s%3N)"
      gateway_status="$(curl -fsS --connect-timeout 3 --max-time 10 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key" 2>/dev/null || true)"
      if ! jq -e '
        def valid_flags:
          type == "object"
          # gateway-status-routable.sh consumes all three values and defaults
          # missing flags. A public traffic proof must not infer those defaults.
          and (has("phase") and (.phase | type == "string"))
          and (has("requests_blocked") and (.requests_blocked | type == "boolean"))
          and (has("chain_phase") and (.chain_phase | type == "string"));
        def valid_runtime:
          type == "object"
          and (.active | type == "boolean")
          and (if has("runtime") then
                 (.runtime | valid_flags)
               else valid_flags end);
        type == "object"
        and (if has("devshards") then
               (.devshards | type == "array" and all(.[]; valid_runtime))
             else true end)
        and (
          (.routable | type == "boolean")
          or (
            (.mode | type == "string")
            and (.capacity | type == "object")
            and (.devshards | type == "array")
          )
        )
      ' <<<"$gateway_status" >/dev/null 2>&1; then
        state=UNAVAILABLE
        reason=status_unusable
      elif ! "$(dirname "$0")/gateway-status-routable.sh" <<<"$gateway_status" >/dev/null 2>&1; then
        state=UNAVAILABLE
        reason=runtime_not_routable
      elif ! jq -e '.state == "READY" and (.current_balance|tonumber) >= (.low_watermark|tonumber)' "$reserve_file" >/dev/null 2>&1; then
        state=DEGRADED
        reason=escrow_reserve_low
      else
        state=READY
        reason=completion_succeeded
      fi
    elif [[ "$curl_rc" == 0 && "$http_code" == 200 ]]; then
      state=UNAVAILABLE
      reason=completion_identity_unavailable
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

# `state` remains compatible with existing public consumers. `readiness` is
# the stricter contract for operators and alerts: it says which layer was
# actually observed rather than treating a listening process or HTTP 200 as
# traffic acceptance.
case "$state" in
  READY)
    readiness=TRAFFIC_READY
    ;;
  RECOVERING)
    readiness=RECOVERING
    ;;
  DEGRADED)
    # A successful routed completion with a reserve guard is not traffic-ready
    # for new work, but proves the control and routing layers separately.
    [[ "$completion_observed" == true ]] && readiness=ROUTING_READY
    ;;
  UNAVAILABLE)
    case "$reason" in
      http_429) readiness=SATURATED ;;
      runtime_not_routable) readiness=CONTROL_READY ;;
      *) readiness=UNAVAILABLE ;;
    esac
    ;;
esac

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
  --arg readiness "$readiness" \
  --arg recovery_escrow "$recovery_escrow" \
  --arg recovery_started_at "$recovery_started_at" \
  --argjson http_status "$http_status" \
  --argjson curl_exit "$curl_exit" \
  --argjson latency_ms "$latency_ms" \
  --argjson completion_finished_ms "$completion_finished_ms" \
  --argjson arrival_height "$arrival_height" \
  --argjson permit_height "$permit_height" \
  --argjson dispatch_height "$dispatch_height" \
  --argjson response_height "$response_height" \
  --argjson next_check_seconds "$next_check_seconds" \
  '{state:$state,readiness:$readiness,checked_at:$checked_at,http_status:$http_status,curl_exit:$curl_exit,latency_ms:$latency_ms,completion_finished_ms:$completion_finished_ms,reason:$reason,admission:$admission,admission_id:$admission_id,safe_generation:$safe_generation,arrival_height:$arrival_height,permit_height:$permit_height,dispatch_height:$dispatch_height,response_height:$response_height}
   + if $state == "RECOVERING" and $recovery_started_at != "" then {
       recovery:{stage:$reason,escrow_id:$recovery_escrow,started_at:$recovery_started_at,next_check_seconds:$next_check_seconds}
     } else {} end' >"$tmp"
chmod 0644 "$tmp"
mv -fT -- "$tmp" "$output"

# Prometheus scrapes this local, generated textfile through the OPS status
# service. Keep a one-hot enum rather than converting an unavailable sample to
# zero or omitting it: alerts can distinguish a stale probe from each observed
# readiness layer.
for candidate in CONTROL_READY ROUTING_READY TRAFFIC_READY RECOVERING SATURATED UNAVAILABLE; do
  value=0
  [[ "$readiness" == "$candidate" ]] && value=1
  printf 'gdc_gateway_readiness_state{state="%s"} %s\n' "$candidate" "$value" >>"$prom_tmp"
done
printf 'gdc_gateway_readiness_observed_timestamp_seconds %s\n' "$(date -u +%s)" >>"$prom_tmp"
printf 'gdc_gateway_readiness_latency_milliseconds %s\n' "$latency_ms" >>"$prom_tmp"
chmod 0644 "$prom_tmp"
mv -fT -- "$prom_tmp" "$prom_output"
