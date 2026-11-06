#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

require_root
validate_target "$RUNNER_ROOT"
require_runner_user
[[ "${1:-}" == --yes ]] || die 'pass --yes after disabling routing and stopping the service'
systemctl is-active --quiet "$UNIT_NAME" && die 'stop the service before rollback'
rollback_root="$RUNNER_ROOT/.rollback"
latest="$(find "$rollback_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$latest" ]] || die 'no rollback payload exists'
for path in bin externals run.sh run-helper.sh; do
  rm -rf -- "${RUNNER_ROOT:?}/$path"
  test -e "$latest/$path" && mv "$latest/$path" "$RUNNER_ROOT/$path"
done
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_ROOT/bin" "$RUNNER_ROOT/externals"
assert_docker_denied
printf 'runner payload rollback complete; leave routing disabled until a trusted canary passes\n'
