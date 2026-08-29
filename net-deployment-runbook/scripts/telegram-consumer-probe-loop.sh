#!/usr/bin/env bash
set -Eeuo pipefail

model="${1:-}"
sla_seconds="${2:-}"
[[ -n "$model" && "$sla_seconds" =~ ^[1-9][0-9]*$ ]] || {
  printf 'ERROR Telegram consumer probe loop requires model and positive SLA seconds\n' >&2
  exit 2
}

bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
[[ -n "$bot" ]] || { printf 'ERROR Telegram consumer container is not running\n' >&2; exit 1; }
[[ "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$bot" | sed -n 's/^MODEL=//p')" == "$model" ]] || {
  printf 'ERROR Telegram consumer model does not match the requested model\n' >&2
  exit 1
}

deadline=$(( $(date +%s) + sla_seconds ))
attempt=0
last_reason=not_started
completed=false
while (( $(date +%s) < deadline )); do
  remaining=$(( deadline - $(date +%s) ))
  attempt=$((attempt + 1))
  # Each attempt creates a new conversation and a request with its own
  # absolute deadline. The outer timeout only bounds a wedged process; it
  # never replays an already dispatched request.
  probe_timeout=35
  (( remaining < probe_timeout )) && probe_timeout="$remaining"
  set +e
  probe="$(timeout "$probe_timeout" docker exec "$bot" python3 /app/bot.py --probe 2>&1)"
  probe_rc=$?
  set -e
  if (( probe_rc == 0 )); then
    if jq -e '. == {"conversation_id_present": true, "output_present": true, "status": "completed", "usage_present": true}' \
      <<<"$probe" >/dev/null; then
      completed=true
      break
    fi
    printf 'ERROR Telegram consumer inference probe returned unexpected response=%s\n' \
      "$(jq -c '{status,reason}' <<<"$probe" 2>/dev/null || printf '%s' 'unparseable')" >&2
    exit 1
  fi
  if (( probe_rc == 124 )); then
    last_reason=probe_timeout
  else
    last_reason="$(jq -r 'select(.status == "failed") | .reason // empty' <<<"$probe" 2>/dev/null || true)"
    [[ -n "$last_reason" ]] || last_reason=unparseable
  fi
  case "$last_reason" in
    gateway_request_failed|gateway_returned_HTTP_429|gateway_returned_HTTP_502|gateway_returned_HTTP_503|gateway_returned_HTTP_504|probe_timeout) ;;
    *)
      printf 'ERROR Telegram consumer inference probe failed attempt=%s reason=%s\n' "$attempt" "$last_reason" >&2
      exit 1
      ;;
  esac
  remaining=$(( deadline - $(date +%s) ))
  (( remaining > 0 )) || break
  sleep_seconds=5
  (( remaining < sleep_seconds )) && sleep_seconds="$remaining"
  printf 'WAIT Telegram consumer inference attempt=%s reason=%s remaining=%ss\n' "$attempt" "$last_reason" "$remaining"
  sleep "$sleep_seconds"
done

[[ "$completed" == true ]] || {
  printf 'ERROR Telegram consumer inference did not recover within %ss attempts=%s last_reason=%s\n' \
    "$sla_seconds" "$attempt" "$last_reason" >&2
  exit 1
}

payload="$(curl -fsS http://127.0.0.1:9464/health)"
jq -e --argjson sla "$sla_seconds" '
  .status == "ok"
  and .inference_ready == true
  and (.last_success_age_seconds | type == "number" and . <= $sla)
' <<<"$payload" >/dev/null || {
  printf 'ERROR Telegram consumer probe completed but readiness was not updated health=%s\n' "$payload" >&2
  exit 1
}
