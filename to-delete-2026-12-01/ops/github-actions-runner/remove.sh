#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

require_root
validate_target "$RUNNER_ROOT"
[[ "${1:-}" == --yes ]] || die 'pass --yes after GitHub routing is disabled and the runner is drained'
if [[ ! -e "$RUNNER_ROOT" ]]; then
  printf 'runner payload is already absent; no changes made\n'
  exit 0
fi
systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
if [[ -x "$RUNNER_ROOT/config.sh" && -f "$RUNNER_ROOT/.runner" ]]; then
  runuser -u "$RUNNER_USER" -- "$RUNNER_ROOT/config.sh" remove --token "${GITHUB_ACTIONS_RUNNER_REMOVE_TOKEN:?set a fresh removal token}" || die 'GitHub runner removal failed'
fi
rm -f -- "$SYSTEMD_UNIT_DIR/$UNIT_NAME"
rm -rf -- "${RUNNER_ROOT:?}"
systemctl daemon-reload
printf 'runner payload removed; the dedicated account is retained for explicit operator review\n'
