#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

require_root
validate_target "$RUNNER_ROOT"
load_manifest
require_runner_user
systemctl is-active --quiet "$UNIT_NAME" && die 'drain and stop the service before updating'
test -f "$RUNNER_ROOT/.runner" || die 'runner is not registered'
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
archive="$temporary/$RUNNER_ARCHIVE"
download_verified "$RUNNER_URL" "$RUNNER_SHA256" "$archive"
rollback="$RUNNER_ROOT/.rollback/$RUNNER_VERSION-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -o root -g root -m 0700 "$rollback"
for path in bin externals run.sh run-helper.sh; do
  test -e "$RUNNER_ROOT/$path" && mv "$RUNNER_ROOT/$path" "$rollback/"
done
tar -xzf "$archive" -C "$RUNNER_ROOT"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_ROOT/bin" "$RUNNER_ROOT/externals"
assert_docker_denied
printf 'runner payload updated; run the approved trusted canary before enabling routing\n'
