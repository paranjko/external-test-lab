#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

validate_target "$RUNNER_ROOT"
require_runner_user
assert_docker_denied
test -f "$RUNNER_ROOT/.runner" || die 'runner is not registered'
systemctl is-active --quiet "$UNIT_NAME" || die 'runner service is not active'
printf 'runner service is active and Docker access is denied\n'
