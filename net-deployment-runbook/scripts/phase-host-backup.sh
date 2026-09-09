#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -eq 1 ]] || { echo "usage: $0 SSH_ALIAS" >&2; exit 2; }
"$ROOT/scripts/validator-backup.sh" create "$1"
