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
GDC_JOIN_BOOTSTRAP_MODE=state_sync
GDC_JOIN_TRUST_HEIGHT=100
GDC_JOIN_TRUST_HASH='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
GDC_JOIN_SNAPSHOT_PEERS='0123456789abcdef0123456789abcdef01234567@tcp://rpc-a.example.test:5000,89abcdef0123456789abcdef0123456789abcdef@tcp://rpc-b.example.test:5000'
GDC_JOIN_LINEAGE_RECEIPT_SHA256='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
export ROOT GDC_HOME STATE GDC_RUN_ID GDC_RELEASE_PROFILE GDC_NETWORK_FINGERPRINT
export GDC_NETWORK_CHAIN_ID GDC_NETWORK_GENESIS_SHA256
export GDC_JOIN_BOOTSTRAP_MODE GDC_JOIN_TRUST_HEIGHT GDC_JOIN_TRUST_HASH GDC_JOIN_SNAPSHOT_PEERS GDC_JOIN_LINEAGE_RECEIPT_SHA256
# shellcheck source=/dev/null
source "$ROOT/scripts/lib.sh"

ensure_run_manifest join-gdc-node2
manifest="$GDC_HOME/runs/$GDC_RUN_ID/manifest.env"
grep -qx "network_fingerprint=$GDC_NETWORK_FINGERPRINT" "$manifest"
grep -qx "network_chain_id=$GDC_NETWORK_CHAIN_ID" "$manifest"
grep -qx "network_genesis_sha256=$GDC_NETWORK_GENESIS_SHA256" "$manifest"
grep -qx "join_snapshot_peers=$GDC_JOIN_SNAPSHOT_PEERS" "$manifest"

# Only the exact previously observed network can resume an interrupted JOIN.
ensure_run_manifest join-gdc-node2
GDC_NETWORK_FINGERPRINT='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
if (ensure_run_manifest join-gdc-node2) >"$tmp/mismatch.out" 2>"$tmp/mismatch.err"; then
  echo 'retained run accepted a changed network fingerprint' >&2
  exit 1
fi
grep -Fq 'run_resume_mismatch:' "$tmp/mismatch.err"

GDC_NETWORK_FINGERPRINT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
GDC_JOIN_SNAPSHOT_PEERS='0123456789abcdef0123456789abcdef01234567@tcp://rpc-a.example.test:5000,ffffffffffffffffffffffffffffffffffffffff@tcp://rpc-c.example.test:5000'
if (ensure_run_manifest join-gdc-node2) >"$tmp/snapshot.out" 2>"$tmp/snapshot.err"; then
  echo 'retained run accepted a changed state-sync snapshot' >&2
  exit 1
fi
grep -Fq 'lineage preflight join_snapshot_peers' "$tmp/snapshot.err"

printf 'PASS Host JOIN resume requires the exact observed network fingerprint\n'
