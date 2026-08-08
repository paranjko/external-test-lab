#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$ROOT/scripts/make-secrets.sh" "$tmp/secrets" gdc-node0 >/dev/null
mapfile -t secret_files < <(find "$tmp/secrets" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
expected=(
  bridge.jwt
  gateway.admin-key
  gateway.client-keys
  gdc-node0.keyring
  gdc-node0.postgres
  grafana.admin
  operator.keyring
)
[[ "${secret_files[*]}" == "${expected[*]}" ]]
! find "$tmp/secrets" -maxdepth 1 -type f -name 'gdc-node[1-4].*' | grep -q .

grep -Fq '"$ROOT/scripts/phase-identities.sh"' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'Create Genesis operator secrets, node0 identities, and gateway account' "$ROOT/scripts/phase-genesis.sh"
identity_line="$(grep -nF '"$ROOT/scripts/phase-identities.sh"' "$ROOT/scripts/phase-genesis.sh" | cut -d: -f1)"
time_line="$(grep -nF 'GENESIS_TIME="$(date' "$ROOT/scripts/phase-genesis.sh" | cut -d: -f1)"
(( time_line > identity_line ))
! grep -Fq './gdc.sh --release testnet-0.2.14 identities' "$ROOT/gdc.sh"
! grep -Fq './gdc.sh --release testnet-0.2.14 identities' "$ROOT/README.md"
grep -Fq 'hosts=(gdc-node0)' "$ROOT/scripts/phase-qualify-ml.sh"
grep -Fq 'GDC_QUALIFY_HOSTS="$qualification_target"' "$ROOT/gdc.sh"
grep -Fq 'qualify-ml ${host%-ml}' "$ROOT/scripts/lib.sh"

printf 'PASS Genesis and independent-validator identity contract\n'
