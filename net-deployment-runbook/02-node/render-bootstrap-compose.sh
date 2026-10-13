#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 2 && -r "$1" && -r "$2" ]] || exit 2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Compose v2 parses colons in uninterpolated required-variable expressions as
# volume separators. Remove only that colon while parsing, then restore it in
# the JSON model. Do not interpolate secrets or generation paths into Compose.
sed -E 's/\$\{([A-Z_][A-Z0-9_]*):\?/\${\1?/g' "$1" |
  docker compose --env-file "$2" --profile '*' -f - config \
    --no-interpolate --no-normalize --no-path-resolution --format json |
  jq 'walk(if type == "string" then gsub("\\$\\{(?<name>[A-Z_][A-Z0-9_]*)\\?"; "${\(.name):?") else . end)' |
  jq -f "$ROOT/bootstrap-compose.jq"
