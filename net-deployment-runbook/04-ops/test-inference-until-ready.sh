#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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
request_timeout_seconds="${GDC_INFERENCE_REQUEST_TIMEOUT_SECONDS:-25}"
[[ "$request_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo 'GDC_INFERENCE_REQUEST_TIMEOUT_SECONDS must be a positive integer' >&2
  exit 2
}

mkdir -p "$evidence_dir"
attempts_file="$evidence_dir/inference-attempts.jsonl"
: >"$attempts_file"
deadline=$((SECONDS + timeout_seconds))
attempt=0
last_reason='not_attempted'

curl_exit_status() {
  case "$1" in
    0) printf 'ok' ;;
    5) printf 'proxy_resolution_failed' ;;
    6) printf 'dns_resolution_failed' ;;
    7) printf 'connection_failed' ;;
    28) printf 'timeout' ;;
    35) printf 'tls_handshake_failed' ;;
    47) printf 'redirect_limit_exceeded' ;;
    52) printf 'empty_response' ;;
    56) printf 'receive_failed' ;;
    *) printf 'curl_error' ;;
  esac
}

curl_error_detail() {
  tr '\n' ' ' <"$1" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

report_curl_failure() {
  local request="$1" url="$2" http_status="$3" curl_exit="$4" stderr="$5" detail
  detail="$(curl_error_detail "$stderr")"
  printf 'WAIT inference %s unavailable url=%s http_status=%s curl_exit=%s curl_status=%s%s\n' \
    "$request" "$url" "$http_status" "$curl_exit" "$(curl_exit_status "$curl_exit")" "${detail:+ detail=$detail}" >&2
}

record_attempt() {
  local status_code="$1" completion_code="$2" status_ready="$3" valid="$4" reason="$5" elapsed_ms="$6" status_exit="$7" completion_exit="$8" admission="$9" completion_error_code="${10}"
  jq -cn \
    --argjson attempt "$attempt" \
    --arg checked_at "$(date -u +%FT%TZ)" \
    --argjson status_http "$status_code" \
    --argjson completion_http "$completion_code" \
    --argjson status_ready "$status_ready" \
    --argjson completion_valid "$valid" \
    --arg reason "$reason" \
    --argjson elapsed_ms "$elapsed_ms" \
    --argjson status_curl_exit "$status_exit" \
    --arg status_curl_status "$(curl_exit_status "$status_exit")" \
    --argjson completion_curl_exit "$completion_exit" \
    --arg completion_curl_status "$(curl_exit_status "$completion_exit")" \
    --arg admission "$admission" \
    --arg completion_error_code "$completion_error_code" \
    '{attempt:$attempt,checked_at:$checked_at,status_http:$status_http,status_ready:$status_ready,status_curl_exit:$status_curl_exit,status_curl_status:$status_curl_status,completion_http:$completion_http,completion_valid:$completion_valid,completion_curl_exit:$completion_curl_exit,completion_curl_status:$completion_curl_status,admission:$admission,completion_error_code:$completion_error_code,reason:$reason,elapsed_ms:$elapsed_ms}' \
    >>"$attempts_file"
}

while (( SECONDS < deadline )); do
  attempt=$((attempt + 1))
  started_ms="$(date +%s%3N)"
  status_file="$evidence_dir/status-${attempt}.json"
  completion_file="$evidence_dir/completion-${attempt}.json"
  status_http=0
  completion_http=0
  status_rc=0
  completion_rc=0
  status_ready=false
  reason='status_unavailable'
  status_stderr="$evidence_dir/status-${attempt}.curl.stderr"
  completion_stderr="$evidence_dir/completion-${attempt}.curl.stderr"
  completion_headers="$evidence_dir/completion-${attempt}.headers"

  set +e
  status_http="$(curl -sS --connect-timeout 5 --max-time 15 -o "$status_file" -w '%{http_code}' \
    "$api_url/v1/status" -H "Authorization: Bearer $client_key" 2>"$status_stderr")"
  status_rc=$?
  set -e
  [[ "$status_rc" == 0 ]] || report_curl_failure status "$api_url/v1/status" "${status_http:-0}" "$status_rc" "$status_stderr"
  # The public status endpoint can retain active runtimes during a lifecycle
  # transition. Use the same capacity and Inference-phase predicate as the
  # continuity observer before attempting a completion.
  if [[ "$status_rc" == 0 && "$status_http" == 200 ]] \
    && ! "$ROOT/04-ops/gateway-status-routable.sh" <"$status_file" >/dev/null 2>&1; then
    last_reason='runtime_not_routable'
    elapsed_ms=$(( $(date +%s%3N) - started_ms ))
    record_attempt "${status_http:-0}" 0 false false "$last_reason" "$elapsed_ms" "$status_rc" 0 'not_sent_runtime_not_routable' 'not_sent'
    rm -f "$status_stderr" "$completion_stderr" "$completion_headers"
    printf 'WAIT inference attempt=%s reason=%s status_ready=false\n' "$attempt" "$last_reason" >&2
    (( SECONDS < deadline )) && sleep 5
    continue
  fi
  if [[ "$status_rc" == 0 && "$status_http" == 200 ]]; then
    status_ready=true
    reason='routable_runtime_observed'
  fi

  # Keep the readiness probe bounded.  Without an explicit token limit the
  # model may continue a trivial acknowledgement until the HTTP timeout,
  # which leaves an in-flight request in the gateway and makes following
  # probes report a misleading capacity failure.
  payload='{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Reply with exactly: GDC_OK"}],"max_tokens":8,"temperature":0}'
  completion_deadline_ms="$(( $(date +%s%3N) + request_timeout_seconds * 1000 ))"
  set +e
  completion_http="$(curl -sS --connect-timeout 10 --max-time "$request_timeout_seconds" -D "$completion_headers" -o "$completion_file" -w '%{http_code}' \
    "$api_url/v1/chat/completions" -H "Authorization: Bearer $client_key" \
    -H "X-Request-Deadline-Ms: $completion_deadline_ms" -H 'Content-Type: application/json' -d "$payload" 2>"$completion_stderr")"
  completion_rc=$?
  set -e
  [[ "$completion_rc" == 0 ]] || report_curl_failure completion "$api_url/v1/chat/completions" "${completion_http:-0}" "$completion_rc" "$completion_stderr"
  admission='not_observed'
  if [[ "$completion_rc" == 0 ]]; then
    admission="$(awk 'tolower($0) ~ /^x-gdc-admission:/ { value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/\r$/, "", value); print value; exit }' "$completion_headers")"
    admission="${admission:-not_observed}"
  fi
  completion_error_code='not_observed'
  if [[ "$admission" == pre_dispatch_rejected || "$admission" == dispatch_attempt_failed ]]; then
    completion_error_code="$(jq -r '.error.code? | select(type == "string" and test("^[a-z0-9_]{1,64}$"))' "$completion_file" 2>/dev/null || true)"
    completion_error_code="${completion_error_code:-not_observed}"
  fi

  if [[ "$completion_rc" == 0 && "$completion_http" == 200 ]] && jq -e '.choices[0].message.content | type == "string"' "$completion_file" >/dev/null 2>&1; then
    elapsed_ms=$(( $(date +%s%3N) - started_ms ))
    record_attempt "${status_http:-0}" "${completion_http:-0}" "$status_ready" true 'completion_succeeded' "$elapsed_ms" "$status_rc" "$completion_rc" "$admission" "$completion_error_code"
    jq . "$completion_file" >"$output_json"
    jq -n --argjson attempts "$attempt" --arg verdict PASS --argjson last_status "$status_http" \
      '{verdict:$verdict,attempts:$attempts,last_status_http:$last_status}' >"$evidence_dir/inference-verdict.json"
    rm -f "$status_file" "$completion_file" "$status_stderr" "$completion_stderr" "$completion_headers"
    printf 'PASS authenticated inference after %s attempt(s)\n' "$attempt"
    exit 0
  fi

  if [[ "$completion_rc" != 0 ]]; then
    last_reason="curl_$(curl_exit_status "$completion_rc")"
  elif [[ "$completion_http" == 429 || "$completion_http" == 502 || "$completion_http" == 503 || "$completion_http" == 504 ]]; then
    last_reason="http_${completion_http}"
  elif [[ "$completion_http" != 200 ]]; then
    last_reason="http_${completion_http}"
  else
    last_reason='invalid_completion'
  fi
  elapsed_ms=$(( $(date +%s%3N) - started_ms ))
  record_attempt "${status_http:-0}" "${completion_http:-0}" "$status_ready" false "$last_reason" "$elapsed_ms" "$status_rc" "$completion_rc" "$admission" "$completion_error_code"
  rm -f "$status_file" "$completion_file" "$status_stderr" "$completion_stderr" "$completion_headers"
  printf 'WAIT inference attempt=%s reason=%s status_ready=%s\n' "$attempt" "$last_reason" "$status_ready" >&2

  # A retry is safe only when the admission proxy proves that no upstream
  # dispatch occurred. Transport failures, missing headers, dispatched_once,
  # and dispatch_attempt_failed are terminal because another attempt could
  # create a second chain-accounted inference.
  if [[ "$admission" != pre_dispatch_rejected ]]; then
    jq -n --arg verdict BLOCKED --arg reason "$last_reason" --arg admission "$admission" --argjson attempts "$attempt" \
      '{verdict:$verdict,reason:$reason,admission:$admission,attempts:$attempts}' >"$evidence_dir/inference-verdict.json"
    exit 1
  fi
  (( SECONDS < deadline )) && sleep 5
done

jq -n --arg verdict BLOCKED --arg reason "$last_reason" --argjson attempts "$attempt" \
  '{verdict:$verdict,reason:$reason,attempts:$attempts}' >"$evidence_dir/inference-verdict.json"
echo "authenticated inference did not recover within ${timeout_seconds}s (last=$last_reason)" >&2
exit 1
