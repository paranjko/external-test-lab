#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 https://api.example KEY" >&2; exit 2; }

api_url="${1%/}/v1/chat/completions"
client_key="$2"
deadline_seconds="${GDC_INFERENCE_DEADLINE_SECONDS:-90}"
http_timeout_seconds="${GDC_INFERENCE_HTTP_TIMEOUT_SECONDS:-90}"
[[ "$deadline_seconds" =~ ^[1-9][0-9]*$ ]] && (( deadline_seconds <= 900 )) || {
  echo 'GDC_INFERENCE_DEADLINE_SECONDS must be an integer from 1 through 900' >&2
  exit 2
}
[[ "$http_timeout_seconds" =~ ^[1-9][0-9]*$ ]] && (( http_timeout_seconds <= 900 )) || {
  echo 'GDC_INFERENCE_HTTP_TIMEOUT_SECONDS must be an integer from 1 through 900' >&2
  exit 2
}
(( http_timeout_seconds >= deadline_seconds )) || {
  echo 'GDC_INFERENCE_HTTP_TIMEOUT_SECONDS must not be shorter than GDC_INFERENCE_DEADLINE_SECONDS' >&2
  exit 2
}

curl_exit_status() {
  case "$1" in
    0) printf 'ok' ;;
    5) printf 'proxy_resolution_failed' ;;
    6) printf 'dns_resolution_failed' ;;
    7) printf 'connection_failed' ;;
    22) printf 'http_error' ;;
    28) printf 'timeout' ;;
    35) printf 'tls_handshake_failed' ;;
    47) printf 'redirect_limit_exceeded' ;;
    52) printf 'empty_response' ;;
    56) printf 'receive_failed' ;;
    *) printf 'curl_error' ;;
  esac
}

body_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "$body_file" "$stderr_file"' EXIT
deadline_ms="$(( $(date +%s%3N) + deadline_seconds * 1000 ))"
http_status=000
curl_rc=0
set +e
http_status="$(curl --connect-timeout 10 --max-time "$http_timeout_seconds" -sS \
  -o "$body_file" -w '%{http_code}' "$api_url" \
  -H "Authorization: Bearer $client_key" \
  -H "X-Request-Deadline-Ms: $deadline_ms" \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"Reply with exactly: GDC_OK"}],"max_tokens":8,"temperature":0}' \
  2>"$stderr_file")"
curl_rc=$?
set -e

if (( curl_rc != 0 )); then
  detail="$(tr '\n' ' ' <"$stderr_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  printf 'ERROR authenticated inference transport failed url=%s http_status=%s curl_exit=%s curl_status=%s%s\n' \
    "$api_url" "${http_status:-000}" "$curl_rc" "$(curl_exit_status "$curl_rc")" "${detail:+ detail=$detail}" >&2
  exit "$curl_rc"
fi
if [[ "$http_status" != 200 ]]; then
  error_code="$(jq -r '.error.code? | select(type == "string" and test("^[a-z0-9_]{1,64}$"))' "$body_file" 2>/dev/null || true)"
  printf 'ERROR authenticated inference returned a non-success response url=%s http_status=%s error_code=%s\n' \
    "$api_url" "$http_status" "${error_code:-unavailable}" >&2
  exit 1
fi
if ! jq -e '.choices[0].message.content | type == "string"' "$body_file" >/dev/null 2>&1; then
  printf 'ERROR authenticated inference returned an invalid completion payload url=%s http_status=%s\n' \
    "$api_url" "$http_status" >&2
  exit 1
fi
jq . "$body_file"
