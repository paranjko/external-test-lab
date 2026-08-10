#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 1 ]] || { echo "Usage: $0 deployment.env" >&2; exit 2; }
# shellcheck disable=SC1090
source "$1"
[[ "${GDC_STOP_POC_AT_WINDDOWN:-true}" == true ]] || exit 0
# This worker runs on the node whose local inference runtime it controls.  Do
# not poll the public API here: one worker per joined node turns a one-second
# external poll into enough traffic to trip the proxy API rate limit and can
# prevent a subsequent participant registration.  The local API is published
# only on loopback by the deployment and follows the same synchronized chain.
CONTROL_API_URL="${GDC_POC_WINDDOWN_API_URL:-http://127.0.0.1:9000}"
[[ "$CONTROL_API_URL" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || {
  echo 'GDC_POC_WINDDOWN_API_URL must be a loopback HTTP URL' >&2
  exit 2
}

last_stage=''
while :; do
  epoch="$(curl -fsS --connect-timeout 3 --max-time 5 "${CONTROL_API_URL}/v1/epochs/latest" 2>/dev/null || true)"
  phase="$(jq -r '.phase // empty' <<<"$epoch" 2>/dev/null)"
  stage="$(jq -r '.epoch_stages.poc_start // empty' <<<"$epoch" 2>/dev/null)"
  wind_down="$(jq -r '.epoch_stages.poc_generation_wind_down // empty' <<<"$epoch" 2>/dev/null)"
  height="$(jq -r '.block_height // empty' <<<"$epoch" 2>/dev/null)"

  if [[ "$phase" == PoCGenerateWindDown && "$stage" =~ ^[1-9][0-9]*$ \
    && "$wind_down" =~ ^[1-9][0-9]*$ && "$height" =~ ^[1-9][0-9]*$ \
    && "$stage" != "$last_stage" ]] && (( height >= wind_down )); then
    response="$(curl -fsS --connect-timeout 3 --max-time 10 -X POST \
      http://127.0.0.1:8080/api/v1/inference/pow/stop \
      -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
    if jq -e '.status == "OK"' <<<"$response" >/dev/null 2>&1; then
      last_stage="$stage"
      printf 'READY stopped local PoC generation at wind-down stage=%s height=%s\n' "$stage" "$height"
    else
      printf 'WAIT  local PoC stop stage=%s height=%s\n' "$stage" "$height" >&2
    fi
  fi
  sleep 1
done
