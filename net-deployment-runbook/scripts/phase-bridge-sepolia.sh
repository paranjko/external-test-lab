#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility wrapper for evidence and operator notes created before bridge
# lifecycle was split into contract, governance registration and per-Host
# observer commands. HA is deliberately not a bridge prerequisite.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"
load_project
exec "$ROOT/scripts/phase-bridge-observer.sh" apply "${GDC_BRIDGE_HOST:-$GENESIS_NODE}"
