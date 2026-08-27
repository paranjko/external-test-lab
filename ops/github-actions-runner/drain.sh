#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

require_root
validate_target "$RUNNER_ROOT"
systemctl stop "$UNIT_NAME"
printf 'runner service stopped; disable GDC_NODE4_RUNNER_ENABLED before draining in GitHub\n'
