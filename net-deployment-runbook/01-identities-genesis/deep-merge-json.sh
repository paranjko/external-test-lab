#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 3 ]] || { echo "Usage: $0 base.json overlay.json output.json" >&2; exit 2; }
jq -s '.[0] * .[1]' "$1" "$2" >"$3"
