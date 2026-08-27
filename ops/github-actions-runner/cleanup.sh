#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

require_root
validate_target "$RUNNER_ROOT"
[[ "${1:-}" == --yes ]] || die 'pass --yes to remove only the runner workspace'
workspace="$RUNNER_ROOT/_work"
if [[ ! -e "$workspace" ]]; then
  printf 'runner workspace is already clean\n'
  exit 0
fi
[[ -d "$workspace" && ! -L "$workspace" ]] || die 'runner workspace is unsafe'
find "$workspace" -mindepth 1 -maxdepth 1 -xdev -exec rm -rf -- {} +
printf 'runner workspace cleaned\n'
