#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

load_project
assert_baseline_release
record_phase_profile baseline

# A baseline is intentionally a Genesis-participant-only operation. Other hosts are joined
# later by their own operator-facing `join` phases, so this command must not
# depend on their reachability or identities.
GDC_QUALIFY_HOSTS="$GENESIS_NODE" "$ROOT/scripts/phase-qualify-ml.sh"
"$ROOT/scripts/phase-genesis.sh"
"$ROOT/scripts/phase-bootstrap-access.sh"

printf 'PASS standalone baseline: %s genesis and authenticated inference are ready\n' "$GENESIS_NODE"
