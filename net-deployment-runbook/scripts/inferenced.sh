#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
HOME_DIR="${GDC_OPERATOR_HOME:-$STATE/operator-home}"
if [[ -n "${GDC_JOIN_PROFILE:-}" ]]; then
  [[ -r "$GDC_JOIN_PROFILE" ]] || { echo 'generated JOIN profile is unreadable' >&2; exit 1; }
  # The launcher checked freshness before the first Host mutation.  This
  # invocation consumes the same immutable run-bound profile later in the
  # supported state-sync/acceptance workflow.
  "$ROOT/scripts/join-profile.sh" validate --allow-expired "$GDC_JOIN_PROFILE" >/dev/null
  profile_id="$(jq -r .profile_id "$GDC_JOIN_PROFILE")"
  [[ "$profile_id" =~ ^[a-f0-9]{64}$ ]] || { echo 'generated JOIN profile has an invalid profile ID' >&2; exit 1; }
  # A JOIN's immutable profile, rather than the operator PATH or a release
  # lock, is the only authority for every CLI query and transaction.
  BIN_DIR="$GDC_HOME/bin/$profile_id"
  GDC_INFERENCED_CLI_QUIET=true "$ROOT/scripts/ensure-inferenced-cli.sh" --allow-expired --join-profile "$GDC_JOIN_PROFILE"
else
  # shellcheck disable=SC1091
  source "$ROOT/scripts/profile.sh"
  load_profiles
  BIN_DIR="${GDC_INFERENCED_BIN_DIR:-$HOME/.local/bin}"
  GDC_INFERENCED_CLI_QUIET=true "$ROOT/scripts/ensure-inferenced-cli.sh"
fi
BIN="$BIN_DIR/inferenced"
mkdir -p "$HOME_DIR"
chmod 700 "$HOME_DIR"
[[ -x "$BIN" ]] || { echo "inferenced CLI was not installed at $BIN" >&2; exit 1; }
exec "$BIN" --home "$HOME_DIR" "$@"
