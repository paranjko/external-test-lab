#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

GDC_HOME="$tmp/operator/gdc-node2"
STATE="$GDC_HOME/state"
GDC_RUN_ID='interrupted-join'
GDC_RELEASE_PROFILE='v2026.07.23'
GDC_NETWORK_FINGERPRINT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
GDC_NETWORK_CHAIN_ID='gonka-fixture'
GDC_NETWORK_GENESIS_SHA256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
export ROOT GDC_HOME STATE GDC_RUN_ID GDC_RELEASE_PROFILE GDC_NETWORK_FINGERPRINT
export GDC_NETWORK_CHAIN_ID GDC_NETWORK_GENESIS_SHA256
# shellcheck source=/dev/null
source "$ROOT/scripts/lib.sh"

ensure_run_manifest join-gdc-node2
manifest="$GDC_HOME/runs/$GDC_RUN_ID/manifest.env"
grep -qx "network_fingerprint=$GDC_NETWORK_FINGERPRINT" "$manifest"
grep -qx "network_chain_id=$GDC_NETWORK_CHAIN_ID" "$manifest"
grep -qx "network_genesis_sha256=$GDC_NETWORK_GENESIS_SHA256" "$manifest"

# Only the exact previously observed network can resume an interrupted JOIN.
ensure_run_manifest join-gdc-node2
GDC_NETWORK_FINGERPRINT='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
if (ensure_run_manifest join-gdc-node2) >"$tmp/mismatch.out" 2>"$tmp/mismatch.err"; then
  echo 'retained run accepted a changed network fingerprint' >&2
  exit 1
fi
grep -Fq 'run_resume_mismatch:' "$tmp/mismatch.err"

printf 'PASS Host JOIN resume requires the exact observed network fingerprint\n'
