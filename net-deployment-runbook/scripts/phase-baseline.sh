#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

load_project
assert_baseline_release
record_phase_profile baseline

# A baseline is intentionally a node0-only operation.  Other hosts are joined
# later by their own operator-facing `join` phases, so this command must not
# depend on their reachability or identities.
GDC_QUALIFY_HOSTS=gdc-node0 "$ROOT/scripts/phase-qualify-ml.sh"
"$ROOT/scripts/phase-genesis.sh"
"$ROOT/scripts/phase-bootstrap-access.sh"

printf 'PASS standalone baseline: gdc-node0 genesis and authenticated inference are ready\n'
