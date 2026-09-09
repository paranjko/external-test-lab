#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

GDC_HOME="$tmp/observer"
GDC_RUN_ID='lineage-a'
GDC_INVOCATION_COMMAND='/opt/gdc/gdc.sh host join --skip-qualification --public-host node1.example.test gdc-node1'
GDC_INVOCATION_CWD='/home/operator'
export ROOT GDC_HOME GDC_RUN_ID GDC_INVOCATION_COMMAND GDC_INVOCATION_CWD
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

ensure_run_manifest public-network-verify
manifest="$(run_manifest_path)"
grep -qx 'run_id=lineage-a' "$manifest"
grep -qx "operator_data_home=$GDC_HOME" "$manifest"
grep -qx 'release_profile=v2026.07.23' "$manifest"
grep -Eq '^release_profile_sha256=[0-9a-f]{64}$' "$manifest"
(
  # shellcheck disable=SC1090
  source "$manifest"
  # shellcheck disable=SC2154
  [[ "$invocation_command" == "$GDC_INVOCATION_COMMAND" ]]
  # shellcheck disable=SC2154
  [[ "$invocation_cwd" == "$GDC_INVOCATION_CWD" ]]
)

genesis_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$tmp/bundle"
write_phase_lineage "$tmp/bundle" gonka-devnet-community "$genesis_a"
[[ "$?" -eq 0 ]]
grep -qx "genesis_sha256=$genesis_a" "$manifest"
grep -qx 'chain_id=gonka-devnet-community' "$manifest"
grep -qx 'run_id=lineage-a' "$tmp/bundle/lineage.env"
grep -qx "genesis_sha256=$genesis_a" "$tmp/bundle/lineage.env"

if (write_phase_lineage "$tmp/bundle" gonka-devnet-community bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) >/dev/null 2>&1; then
  echo 'stale Genesis evidence was accepted by a bound run' >&2
  exit 1
fi
if (write_phase_lineage "$tmp/bundle" another-chain "$genesis_a") >/dev/null 2>&1; then
  echo 'mismatched chain evidence was accepted by a bound run' >&2
  exit 1
fi

# A fresh run has its own immutable manifest and cannot inherit the previous
# bound Genesis or its evidence bundle merely because the operator home stays.
GDC_RUN_ID='lineage-b'
export GDC_RUN_ID
ensure_run_manifest public-network-verify
new_manifest="$(run_manifest_path)"
[[ "$new_manifest" != "$manifest" ]]
[[ ! -s "$tmp/observer/runs/lineage-b/public-network-verify/receipt.json" ]]
! grep -q '^genesis_sha256=' "$new_manifest"

printf 'PASS immutable run and Genesis lineage contract\n'
