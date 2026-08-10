#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

load_project
assert_baseline_release
# Backward-compatible shorthand for the self-contained Genesis operation.
# The public CLI is `genesis <SSH_ALIAS>`; this wrapper uses the configured
# Genesis alias while preserving one-node inference availability.
GDC_GENESIS_NODE="$GENESIS_NODE" \
GDC_PUBLIC_EDGE_NODE="$GENESIS_NODE" \
GDC_GATEWAY_NODE="$GENESIS_NODE" \
GDC_GENESIS_GUARDIAN_ENABLED=true \
GDC_GENESIS_BOOTSTRAP_ACCESS=true \
  "$ROOT/scripts/phase-genesis.sh"
printf 'PASS standalone baseline: %s Genesis, authenticated inference and public gateway are ready\n' "$GENESIS_NODE"
