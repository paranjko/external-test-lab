#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -Fq 'profiles: [signer]' "$ROOT/02-node/compose.yaml"
grep -Fq 'required: false' "$ROOT/02-node/compose.yaml"
grep -Fq '[[ "${1:-}" == --enable-signer ]]' "$ROOT/02-node/start-node.sh"
grep -Fq 'record_join_state "$NODE" SYNCING "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" PREPARED' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" CAUGHT_UP "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" LINEAGE_VERIFIED "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" SIGNER_ENABLED "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
prepared_line="$(grep -n 'record_join_state "$NODE" PREPARED' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
syncing_line="$(grep -n 'record_join_state "$NODE" SYNCING' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
lineage_line="$(grep -n 'LINEAGE_VERIFIED' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
enable_line="$(grep -n './start-node.sh --enable-signer' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
(( prepared_line < syncing_line && syncing_line < lineage_line )) || { echo 'JOIN state machine is not monotonic before signer enablement' >&2; exit 1; }
(( lineage_line < enable_line )) || { echo 'signer can start before lineage verification' >&2; exit 1; }
printf 'PASS JOIN keeps TMKMS fenced until lineage verification\n'
