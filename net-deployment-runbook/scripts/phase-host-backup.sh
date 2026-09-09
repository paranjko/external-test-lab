#!/bin/sh
set -eu
ROOT="$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)"
[ "$#" -eq 1 ] || { echo "usage: $0 SSH_ALIAS" >&2; exit 2; }
"$ROOT/scripts/validator-backup.sh" create "$1"
