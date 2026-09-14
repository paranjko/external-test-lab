#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Thin adapter: admission and state handling live in lib-recovery.sh.
# shellcheck source=scripts/lib-recovery.sh
source "$SCRIPT_DIR/lib-recovery.sh"

declare -F recovery_main >/dev/null \
  || { echo 'error: lib-recovery.sh does not define recovery_main' >&2; exit 70; }

phase="${1:-}"
[[ -n "$phase" ]] || { echo 'error: recovery phase is required' >&2; exit 2; }
shift

recovery_main "$phase" "$@"
