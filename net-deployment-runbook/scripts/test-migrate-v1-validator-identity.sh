#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/gdc-identity-layout.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
node=gdc-node2
legacy="$tmp/$node"
install -d -m 0700 "$legacy/inference/config" "$legacy/tmkms/secrets" "$legacy/tmkms/state"
printf '%s\n' '{"priv_key":{"type":"tendermint/PrivKeyEd25519","value":"fixture"}}' >"$legacy/inference/config/node_key.json"
printf '%s\n' softsign >"$legacy/tmkms/secrets/priv_validator_key.softsign"
printf '%s\n' kms >"$legacy/tmkms/secrets/kms-identity.key"
printf '%s\n' state >"$legacy/tmkms/state/priv_validator_state.json"
printf '%s\n' tmkms >"$legacy/tmkms/tmkms.toml"
GDC_IDENTITY_LAYOUT_TEST_MODE=true GDC_IDENTITY_LAYOUT_TEST_ROOT="$tmp" "$ROOT/02-node/migrate-v1-validator-identity.sh" "$node" >"$tmp/out"
grep -Fq 'READY migrated validator identity to stable layout v2' "$tmp/out"
cmp -s "$legacy/inference/config/node_key.json" "$tmp/identity/$node/p2p/node_key.json"
cmp -s "$legacy/tmkms/secrets/priv_validator_key.softsign" "$tmp/signer/$node/tmkms/secrets/priv_validator_key.softsign"
GDC_IDENTITY_LAYOUT_TEST_MODE=true GDC_IDENTITY_LAYOUT_TEST_ROOT="$tmp" "$ROOT/02-node/migrate-v1-validator-identity.sh" "$node" >"$tmp/repeat.out"
grep -Fq 'already matches v1 restore' "$tmp/repeat.out"
printf 'PASS v1 restore migration preserves stable P2P and signer roots\n'
