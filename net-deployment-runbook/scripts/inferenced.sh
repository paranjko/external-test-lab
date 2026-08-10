#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/profile.sh"
load_profiles
HOME_DIR="${GDC_OPERATOR_HOME:-$STATE/operator-home}"
BIN_DIR="${GDC_INFERENCED_BIN_DIR:-$HOME/.local/bin}"
BIN="$BIN_DIR/inferenced"
mkdir -p "$HOME_DIR"
chmod 700 "$HOME_DIR"
GDC_INFERENCED_CLI_QUIET=true "$ROOT/scripts/ensure-inferenced-cli.sh"
[[ -x "$BIN" ]] || { echo "inferenced CLI was not installed at $BIN" >&2; exit 1; }
exec "$BIN" --home "$HOME_DIR" "$@"
