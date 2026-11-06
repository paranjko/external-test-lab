#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

validate_target "$RUNNER_ROOT"
load_manifest
shellcheck_bin="$RUNNER_ROOT/shellcheck"
[[ -x "$shellcheck_bin" ]] || die 'pinned native ShellCheck is not installed'
"$shellcheck_bin" --version | grep -Fq "version: $SHELLCHECK_VERSION" || die 'native ShellCheck version mismatch'
runbook=${1:?pass the checked-out net-deployment-runbook directory}
[[ -d "$runbook" ]] || die 'runbook directory is missing'
mapfile -t scripts < <(find "$runbook" -type f -name '*.sh' -not -path "$runbook/vendor/*" -print | LC_ALL=C sort)
((${#scripts[@]} > 0)) || die 'no shell scripts found'
"$shellcheck_bin" --external-sources --severity=warning "${scripts[@]}"
