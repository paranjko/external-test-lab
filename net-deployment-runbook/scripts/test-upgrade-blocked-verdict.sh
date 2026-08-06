#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

OUT="${TMPDIR:-/tmp}/gdc-upgrade-blocked-verdict-$$.md"
write_upgrade_blocked_verdict "$OUT" node-rollout gdc-node2 'gdc-node0 gdc-node1' 17

grep -qx '# DevNet upgrade: BLOCKED' "$OUT"
grep -qx -- '- Failed stage: node-rollout' "$OUT"
grep -qx -- '- Failed node: gdc-node2' "$OUT"
grep -qx -- '- Completed target nodes: gdc-node0 gdc-node1' "$OUT"
grep -qx -- '- Exit status: 17' "$OUT"
grep -q 'Do not reset Genesis' "$OUT"
grep -q 'exact target profile' "$OUT"
grep -q '^./gdc.sh --release testnet-0.2.15 upgrade$' "$OUT"
! grep -q '^BEGIN phase=' "$OUT"

printf 'PASS upgrade BLOCKED verdict contract\n'
