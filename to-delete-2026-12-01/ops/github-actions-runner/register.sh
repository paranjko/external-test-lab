#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

require_root
validate_target "$RUNNER_ROOT"
require_runner_user
[[ -x "$RUNNER_ROOT/config.sh" ]] || die 'runner payload is not installed'
[[ -n "${GITHUB_ACTIONS_RUNNER_TOKEN:-}" ]] || die 'set a fresh registration token in GITHUB_ACTIONS_RUNNER_TOKEN'
[[ "$GITHUB_ACTIONS_RUNNER_TOKEN" != *$'\n'* ]] || die 'registration token is malformed'
assert_docker_denied
set +x
runuser -u "$RUNNER_USER" -- "$RUNNER_ROOT/config.sh" --unattended \
  --url "$RUNNER_REPOSITORY" --token "$GITHUB_ACTIONS_RUNNER_TOKEN" \
  --name "$RUNNER_NAME" --labels "$RUNNER_LABEL" --work "_work" --replace
unset GITHUB_ACTIONS_RUNNER_TOKEN
printf 'registered repository-scoped runner; start requires a separate service action\n'
