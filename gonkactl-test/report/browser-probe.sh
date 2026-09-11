#!/usr/bin/env bash
set -euo pipefail

data_root=${1:?persistent data root is required}
probe_root="$data_root/report/browser-probe"
profile="$probe_root/profiles/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$profile"
node "$(dirname "$0")/browser-check.mjs" --probe --evidence-dir "$probe_root" --profile "$profile"
