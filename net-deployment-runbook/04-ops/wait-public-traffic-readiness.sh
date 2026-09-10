#!/usr/bin/env bash
set -Eeuo pipefail

site_url="${1:?site URL is required}"
output_file="${2:?output file is required}"
verification_started_ms="${3:?verification start timestamp is required}"
max_age_seconds="${4:?maximum age is required}"
timeout_seconds="${5:?timeout is required}"
poll_seconds="${6:?poll interval is required}"

[[ "$verification_started_ms" =~ ^[0-9]+$ ]] || { echo 'verification start timestamp must be milliseconds since epoch' >&2; exit 2; }
[[ "$max_age_seconds" =~ ^[1-9][0-9]*$ ]] || { echo 'gateway public readiness maximum age must be a positive integer' >&2; exit 2; }
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { echo 'gateway public readiness timeout must be a positive integer' >&2; exit 2; }
[[ "$poll_seconds" =~ ^([1-9][0-9]*([.][0-9]+)?|0[.]([0-9]*[1-9][0-9]*))$ ]] || { echo 'gateway public readiness poll interval must be positive' >&2; exit 2; }

curl_status() {
  case "$1" in
    0) printf 'ok' ;;
    6) printf 'dns_resolution_failed' ;;
    7) printf 'connection_failed' ;;
    28) printf 'timeout' ;;
    35) printf 'tls_failed' ;;
    52) printf 'empty_response' ;;
    56) printf 'receive_failed' ;;
    *) printf 'curl_error' ;;
  esac
}

curl_error="$(mktemp)"
trap 'rm -f "$curl_error"' EXIT
last_curl_exit=0
last_curl_detail=''
deadline_ms=$(( $(date +%s%3N) + timeout_seconds * 1000 ))
while :; do
  remaining_ms=$((deadline_ms - $(date +%s%3N)))
  (( remaining_ms > 0 )) || break
  request_timeout_seconds="$(awk -v milliseconds="$remaining_ms" 'BEGIN { printf "%.3f", milliseconds / 1000 }')"
  canary_url="${site_url%/}/status/gateway-health?gdc_canary=$(date +%s%3N)-$$-${RANDOM}"
  set +e
  curl -fsS --connect-timeout "$request_timeout_seconds" --max-time "$request_timeout_seconds" "$canary_url" >"$output_file" 2>"$curl_error"
  canary_rc=$?
  set -e
  last_curl_exit="$canary_rc"
  last_curl_detail="$(tr '\n' ' ' <"$curl_error" | sed 's/[[:space:]]\+$//')"
  if [[ "$canary_rc" == 0 ]] && jq -e --argjson max_age "$max_age_seconds" --argjson started_ms "$verification_started_ms" '
    def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    .state == "READY"
    and .readiness == "TRAFFIC_READY"
    and .admission == "dispatched_once"
    and (.admission_id | test("^[a-f0-9]{32}$"))
    and (.safe_generation | test("^sha256:[a-f0-9]{64}$"))
    and (.arrival_height | type == "number" and . > 0)
    and (.permit_height | type == "number" and . > 0)
    and (.dispatch_height | type == "number" and . > 0)
    and (.response_height | type == "number" and . > 0)
    and .arrival_height <= .permit_height
    and .permit_height <= .dispatch_height
    and .dispatch_height <= .response_height
    and (.completion_finished_ms | type == "number" and . >= $started_ms)
    # checked_at is a second-resolution public timestamp. Accept the second
    # containing the millisecond-resolution verification start.
    and ((.checked_at | epoch) >= (($started_ms / 1000) | floor))
    and ((now - (.checked_at | epoch)) >= 0 and (now - (.checked_at | epoch)) <= $max_age)
  ' "$output_file" >/dev/null; then
    exit 0
  fi
  remaining_ms=$((deadline_ms - $(date +%s%3N)))
  (( remaining_ms > 0 )) || break
  sleep_seconds="$(awk -v poll="$poll_seconds" -v milliseconds="$remaining_ms" 'BEGIN { remaining = milliseconds / 1000; print (poll < remaining ? poll : remaining) }')"
  sleep "$sleep_seconds"
done

echo "public readiness canary did not prove a fresh post-recovery traffic receipt url=${site_url%/}/status/gateway-health curl_exit=$last_curl_exit curl_status=$(curl_status "$last_curl_exit")${last_curl_detail:+ detail=$last_curl_detail} evidence=$output_file" >&2
exit 1
