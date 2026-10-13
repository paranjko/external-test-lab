#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
INFERENCED_HOME="${INFERENCED_HOME:-$STATE/operator-home}"
if [[ -n "${GDC_JOIN_PROFILE:-}" ]]; then
  [[ -r "$GDC_JOIN_PROFILE" ]] || { echo 'generated JOIN profile is unreadable' >&2; exit 1; }
  # The launcher checked freshness before the first Host mutation.  This
  # invocation consumes the same immutable run-bound profile later in the
  # supported state-sync/acceptance workflow.
  "$ROOT/scripts/join-profile.sh" validate --allow-expired "$GDC_JOIN_PROFILE" >/dev/null
  # A JOIN's immutable profile, rather than the operator PATH or a release
  # lock, is the only authority for every CLI query and transaction.
  inferenced_version="$(jq -r .spec.components.core.expected_runtime.version "$GDC_JOIN_PROFILE")"
  inferenced_bin_dir="${GDC_INTERNAL_DATA_ROOT:-$GDC_HOME}/bin/$inferenced_version"
  GDC_INFERENCED_CLI_QUIET=true "$ROOT/scripts/ensure-inferenced-cli.sh" --allow-expired --join-profile "$GDC_JOIN_PROFILE"
else
  # shellcheck disable=SC1091
  source "$ROOT/scripts/profile.sh"
  load_profiles
  inferenced_bin_dir="${GDC_INFERENCED_BIN_DIR:-${GDC_INTERNAL_DATA_ROOT:-${GDC_HOME:-$HOME/.local}}/bin/$GONKA_RELEASE}"
  GDC_INFERENCED_CLI_QUIET=true "$ROOT/scripts/ensure-inferenced-cli.sh"
fi
INFERENCED_BIN="$inferenced_bin_dir/inferenced"
mkdir -p "$INFERENCED_HOME"
chmod 700 "$INFERENCED_HOME"
[[ -x "$INFERENCED_BIN" ]] || { echo "inferenced CLI was not installed at $INFERENCED_BIN" >&2; exit 1; }
# Gonka initializes its client context from $HOME/.inference before Cobra
# applies --home. Isolate that early read at INFERENCED_HOME/.inference;
# --home selects INFERENCED_HOME itself for CLI configuration and keyring.
# Set HOME only for the CLI process, never for the wrapper's setup commands.
INFERENCED_CMD=(env "HOME=$INFERENCED_HOME" "$INFERENCED_BIN" --home "$INFERENCED_HOME")
exec "${INFERENCED_CMD[@]}" "$@"
