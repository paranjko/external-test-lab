#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s API_URL CLIENT_KEY EVIDENCE_DIR OUTPUT_JSON [TIMEOUT_SECONDS]\n' "$0" >&2
}

[[ $# -ge 4 && $# -le 5 ]] || { usage; exit 2; }
api_url="${1%/}"
client_key="$2"
evidence_dir="$3"
output_json="$4"
timeout_seconds="${5:-300}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { echo 'timeout must be a positive integer' >&2; exit 2; }

mkdir -p "$evidence_dir"
attempts_file="$evidence_dir/inference-attempts.jsonl"
: >"$attempts_file"
deadline=$((SECONDS + timeout_seconds))
attempt=0
last_reason='not_attempted'

record_attempt() {
  local status_code="$1" completion_code="$2" status_ready="$3" valid="$4" reason="$5" elapsed_ms="$6"
  jq -cn \
    --argjson attempt "$attempt" \
    --arg checked_at "$(date -u +%FT%TZ)" \
    --argjson status_http "$status_code" \
    --argjson completion_http "$completion_code" \
    --argjson status_ready "$status_ready" \
    --argjson completion_valid "$valid" \
    --arg reason "$reason" \
    --argjson elapsed_ms "$elapsed_ms" \
    '{attempt:$attempt,checked_at:$checked_at,status_http:$status_http,status_ready:$status_ready,completion_http:$completion_http,completion_valid:$completion_valid,reason:$reason,elapsed_ms:$elapsed_ms}' \
    >>"$attempts_file"
}

while (( SECONDS < deadline )); do
  attempt=$((attempt + 1))
  started_ms="$(date +%s%3N)"
  status_file="$evidence_dir/status-${attempt}.json"
  completion_file="$evidence_dir/completion-${attempt}.json"
  status_http=0
  completion_http=0
  status_ready=false
  reason='status_unavailable'

  set +e
  status_http="$(curl -sS --connect-timeout 5 --max-time 15 -o "$status_file" -w '%{http_code}' \
    "$api_url/v1/status" -H "Authorization: Bearer $client_key")"
  status_rc=$?
  set -e
  if [[ "$status_rc" == 0 && "$status_http" == 200 ]] && jq -e '
    (.routable == true)
    or ([.devshards[]? | select((.active // false) == true and (.requests_blocked // false) == false and ((.phase // "") == "active" or (.phase // "") == "Inference"))] | length > 0)
  ' "$status_file" >/dev/null 2>&1; then
    status_ready=true
    reason='routable_runtime_observed'
  fi

  payload='{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Reply with exactly: GDC_OK"}],"temperature":0}'
  set +e
  completion_http="$(curl -sS --connect-timeout 10 --max-time 90 -o "$completion_file" -w '%{http_code}' \
    "$api_url/v1/chat/completions" -H "Authorization: Bearer $client_key" \
    -H 'Content-Type: application/json' -d "$payload")"
  completion_rc=$?
  set -e

  if [[ "$completion_rc" == 0 && "$completion_http" == 200 ]] && jq -e '.choices[0].message.content | type == "string"' "$completion_file" >/dev/null 2>&1; then
    elapsed_ms=$(( $(date +%s%3N) - started_ms ))
    record_attempt "${status_http:-0}" "${completion_http:-0}" "$status_ready" true 'completion_succeeded' "$elapsed_ms"
    jq . "$completion_file" >"$output_json"
    jq -n --argjson attempts "$attempt" --arg verdict PASS --argjson last_status "$status_http" \
      '{verdict:$verdict,attempts:$attempts,last_status_http:$last_status}' >"$evidence_dir/inference-verdict.json"
    rm -f "$status_file" "$completion_file"
    printf 'PASS authenticated inference after %s attempt(s)\n' "$attempt"
    exit 0
  fi

  if [[ "$completion_rc" != 0 ]]; then
    last_reason='request_failed'
  elif [[ "$completion_http" == 429 || "$completion_http" == 502 || "$completion_http" == 503 || "$completion_http" == 504 ]]; then
    last_reason="http_${completion_http}"
  elif [[ "$completion_http" != 200 ]]; then
    last_reason="http_${completion_http}"
  else
    last_reason='invalid_completion'
  fi
  elapsed_ms=$(( $(date +%s%3N) - started_ms ))
  record_attempt "${status_http:-0}" "${completion_http:-0}" "$status_ready" false "$last_reason" "$elapsed_ms"
  rm -f "$status_file" "$completion_file"
  printf 'WAIT inference attempt=%s reason=%s status_ready=%s\n' "$attempt" "$last_reason" "$status_ready" >&2

  case "$last_reason" in
    http_401|http_403|http_400|http_404|invalid_completion)
      jq -n --arg verdict BLOCKED --arg reason "$last_reason" --argjson attempts "$attempt" \
        '{verdict:$verdict,reason:$reason,attempts:$attempts}' >"$evidence_dir/inference-verdict.json"
      exit 1
      ;;
  esac
  (( SECONDS < deadline )) && sleep 5
done

jq -n --arg verdict BLOCKED --arg reason "$last_reason" --argjson attempts "$attempt" \
  '{verdict:$verdict,reason:$reason,attempts:$attempts}' >"$evidence_dir/inference-verdict.json"
echo "authenticated inference did not recover within ${timeout_seconds}s (last=$last_reason)" >&2
exit 1
