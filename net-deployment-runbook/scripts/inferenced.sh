#!/bin/sh
# Execute the GDC-managed local inferenced CLI without loading Bash profiles.
set -eu

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"
gdc_require_jq || exit $?

if [ -n "${GDC_JOIN_PROFILE:-}" ]; then
  [ -r "$GDC_JOIN_PROFILE" ] || { printf 'generated JOIN profile is unreadable\n' >&2; exit 1; }
  # The launcher proved freshness before Host mutation. Later supported phases
  # consume the same immutable, run-bound profile after its short window.
  "$ROOT/scripts/join-profile.sh" validate --allow-expired "$GDC_JOIN_PROFILE" >/dev/null
  profile_id=$(jq -r .profile_id "$GDC_JOIN_PROFILE")
  printf '%s\n' "$profile_id" | grep -Eq '^[a-f0-9]{64}$' \
    || { printf 'generated JOIN profile has an invalid profile ID\n' >&2; exit 1; }
  [ -n "${GDC_HOME:-}" ] || { printf 'generated JOIN profile requires GDC_HOME\n' >&2; exit 1; }
  BIN_DIR=$GDC_HOME/bin/$profile_id
  GDC_INFERENCED_CLI_QUIET=true "$ROOT/scripts/ensure-inferenced-cli.sh" --allow-expired --join-profile "$GDC_JOIN_PROFILE"
  HOME_DIR=${GDC_OPERATOR_HOME:-$GDC_HOME/state/operator-home}
else
  BIN_DIR=${GDC_INFERENCED_BIN_DIR:-${HOME:?}/.local/bin}
  GDC_INFERENCED_CLI_QUIET=true "$ROOT/scripts/ensure-inferenced-cli.sh"
  HOME_DIR=${GDC_OPERATOR_HOME:-${GDC_HOME:-${HOME:?}/.gdc-data}/state/operator-home}
fi

BIN=$BIN_DIR/inferenced
mkdir -p "$HOME_DIR"
chmod 0700 "$HOME_DIR"
[ -x "$BIN" ] || { printf 'inferenced CLI was not installed at %s\n' "$BIN" >&2; exit 1; }
exec "$BIN" --home "$HOME_DIR" "$@"
