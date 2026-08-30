#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELECT="$ROOT/scripts/select-compatible-gateway-escrows.sh"

status='{
  "devshards": [
    {"id":"31","active":true,"runtime":{"phase":"active","requests_blocked":false,"session_version":"v5"}},
    {"id":"32","active":true,"phase":"active","requests_blocked":false,"protocol_version":"3"},
    {"id":"33","active":true,"runtime":{"phase":"active","requests_blocked":false,"session_version":"v5","protocol_version":"4"}},
    {"id":"34","active":true,"runtime":{"phase":"active","requests_blocked":false,"session_version":"broken"}},
    {"id":"35","active":false,"runtime":{"phase":"active","requests_blocked":false,"session_version":"v5"}},
    {"id":"36","active":true,"runtime":{"phase":"active","requests_blocked":true,"session_version":"v5"}},
    {"id":"37","active":true,"runtime":{"phase":"active","requests_blocked":false}}
  ]
}'

[[ "$(printf '%s\n' "$status" | "$SELECT" v5)" == 31 ]]
[[ "$(printf '%s\n' "$status" | "$SELECT" v3)" == 32 ]]
[[ -z "$(printf '%s\n' "$status" | "$SELECT" v4)" ]]

if printf '%s\n' '{}' | "$SELECT" invalid >/dev/null 2>&1; then
  echo 'invalid target protocol was accepted' >&2
  exit 1
fi

printf 'PASS compatible gateway escrow selection\n'
