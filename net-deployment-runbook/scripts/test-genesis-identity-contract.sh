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
  gateway.join-client-key
  gateway.telegram-client-key
  gdc-node0.keyring
  gdc-node0.postgres
  grafana.admin
  operator.keyring
  telegram.conversation-api-token
)
[[ "${secret_files[*]}" == "${expected[*]}" ]]
! find "$tmp/secrets" -maxdepth 1 -type f -name 'gdc-node[1-4].*' | grep -q .

grep -Fq '"$ROOT/scripts/phase-identities.sh"' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'Create Genesis operator secrets, Genesis participant identities, and gateway account' "$ROOT/scripts/phase-genesis.sh"
identity_line="$(grep -nF '"$ROOT/scripts/phase-identities.sh"' "$ROOT/scripts/phase-genesis.sh" | cut -d: -f1)"
time_line="$(grep -nF 'GENESIS_TIME="$(date' "$ROOT/scripts/phase-genesis.sh" | cut -d: -f1)"
(( time_line > identity_line ))
! grep -Fq './gdc.sh --release v2026.07.23 identities' "$ROOT/gdc.sh"
! grep -Fq './gdc.sh --release v2026.07.23 identities' "$ROOT/README.md"
grep -Fq 'hosts=("$GENESIS_NODE")' "$ROOT/scripts/phase-qualify-ml.sh"
grep -Fq 'GDC_QUALIFY_HOSTS="$qualification_target"' "$ROOT/gdc.sh"
grep -Fq 'qualify-ml ${host%-ml}' "$ROOT/scripts/lib.sh"
grep -Fq "genesis requires an SSH alias'" "$ROOT/gdc.sh"
grep -Fq -- '--no-bootstrap-access' "$ROOT/gdc.sh"
grep -Fq -- '--skip-qualification)' "$ROOT/gdc.sh"
! grep -Fq -- '--sckip-qualification' "$ROOT/gdc.sh"
grep -Fq 'GDC_GENESIS_SKIP_QUALIFICATION="$skip_qualification"' "$ROOT/gdc.sh"
grep -Fq 'GDC_PREPARE_HOSTS="$GENESIS_NODE"' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'GDC_QUALIFY_HOSTS="$GENESIS_NODE"' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'qualification_status=skipped_by_operator' "$ROOT/scripts/phase-genesis.sh"
grep -Fq "printf 'ml_qualification=%s" "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'ML qualification explicitly disabled by the Genesis operator' "$ROOT/scripts/phase-genesis.sh"
grep -Fq -- '--skip-qualification' "$ROOT/ROLE-GENESIS.md"
! grep -Fq -- '--sckip-qualification' "$ROOT/ROLE-GENESIS.md"
grep -Fq 'phase-bootstrap-access.sh' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'Require bounded Genesis validator effectiveness before lifecycle success' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'phase-join-acceptance.sh' "$ROOT/scripts/phase-genesis.sh"
! grep -Fq 'GDC_JOIN_GATEWAY_CLIENT_KEY_FILE' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'gateway/join-client-key' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'gateway/join-client-key' "$ROOT/scripts/fetch-join-bootstrap.sh"
grep -Fq 'cold-address backup disagrees with the keyring' "$ROOT/01-identities-genesis/create-cold-accounts.sh"
grep -Fq '"$BACKUP_DIR/$name.address"' "$ROOT/01-identities-genesis/create-cold-accounts.sh"
grep -Fq 'cold-address references' "$ROOT/scripts/phase-identities.sh"
grep -Fq 'INCOMPLETE Genesis was created without bootstrap access' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'phase-ops.sh" faucet' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'gdc-faucet-cold.json' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'persist_runtime_topology' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'runtime-topology.env' "$ROOT/scripts/lib.sh"
! sed -n '/^persist_runtime_topology()/,/^}/p' "$ROOT/scripts/lib.sh" | grep -Eq 'GDC_(PUBLIC_EDGE_NODE|GATEWAY_NODE|TELEGRAM_BOT_HOST)='
grep -Fq 'ensure-inferenced-cli.sh' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'INFERENCED_OPERATOR_VERSION' "$ROOT/profiles/releases/v2026.07.23.lock"
grep -Fq 'INFERENCED_OPERATOR_VERSION' "$ROOT/profiles/releases/v2026.08.06.lock"

printf 'PASS Genesis and independent-validator identity contract\n'
