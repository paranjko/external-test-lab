#!/usr/bin/env bash
set -Eeuo pipefail

number="${preview_number:-}"
origin="${PREVIEW_ORIGIN:-https://preview.gonka-dev.net}"
[[ "$number" =~ ^[1-9][0-9]*$ && "$origin" =~ ^https://[A-Za-z0-9.-]+$ ]] || {
  echo 'ERROR preview number or HTTPS origin is invalid' >&2
  exit 2
}
# A redirect, successful SPA fallback, TLS error or unavailable edge is not
# evidence of removal. Both frontend and backend routes must return 404.
for path in / /site-build.js /status/gpus; do
  status="$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --proto '=https' -o /dev/null -w '%{http_code}' "$origin/$number$path")" || {
    echo "ERROR cannot verify removed preview pr=$number path=$path" >&2
    exit 1
  }
  [[ "$status" == 404 ]] || {
    echo "ERROR removed preview pr=$number path=$path returned HTTP $status, expected 404" >&2
    exit 1
  }
done
printf 'PASS removed public preview pr=%s returns HTTP 404\n' "$number"
