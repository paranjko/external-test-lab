#!/usr/bin/env bash
set -Eeuo pipefail
# This script intentionally does not register the runner. Registration requires
# separate owner authorization and a fresh token supplied only at execution time.
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
validate_target "$RUNNER_ROOT"
load_manifest
[[ "$(uname -m)" == x86_64 ]] || die 'this manifest supports only x86_64 Linux'
if [[ -e "$RUNNER_ROOT" ]]; then
  [[ -d "$RUNNER_ROOT" && ! -L "$RUNNER_ROOT" ]] || die 'existing runner target is unsafe'
  [[ -x "$RUNNER_ROOT/config.sh" ]] || die 'existing runner target is incomplete'
  require_runner_user
  assert_docker_denied
  printf 'runner payload is already installed; no changes made\n'
  exit 0
fi

if ! getent passwd "$RUNNER_USER" >/dev/null; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$RUNNER_USER"
fi
require_runner_user
if [[ ! -d "$RUNNER_PARENT" ]]; then
  install -d -o root -g root -m 0755 "$RUNNER_PARENT"
fi
install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0700 "$RUNNER_ROOT"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
archive="$temporary/$RUNNER_ARCHIVE"
download_verified "$RUNNER_URL" "$RUNNER_SHA256" "$archive"
tar -xzf "$archive" -C "$RUNNER_ROOT"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_ROOT"
shellcheck_archive="$temporary/$SHELLCHECK_ARCHIVE"
download_verified "$SHELLCHECK_URL" "$SHELLCHECK_SHA256" "$shellcheck_archive"
tar -xJf "$shellcheck_archive" -C "$temporary"
install -o root -g root -m 0755 \
  "$temporary/shellcheck-v$SHELLCHECK_VERSION/shellcheck" "$RUNNER_ROOT/shellcheck"
install -d -o root -g root -m 0755 "$SYSTEMD_UNIT_DIR"
install -m 0644 "$SCRIPT_DIR/github-actions-runner-external-test-lab.service" \
  "$SYSTEMD_UNIT_DIR/$UNIT_NAME"
systemctl daemon-reload
assert_docker_denied
printf 'installed runner payload; registration and service start remain separate actions\n'
