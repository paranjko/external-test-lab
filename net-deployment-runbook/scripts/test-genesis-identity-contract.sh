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
  gateway.reserve-signer-token
  gateway.telegram-client-key
  gdc-node0.keyring
  gdc-node0.postgres
  grafana.admin
  operator.keyring
  telegram.conversation-api-token
)
[[ "${secret_files[*]}" == "${expected[*]}" ]]
! find "$tmp/secrets" -maxdepth 1 -type f -name 'gdc-node[1-4].*' | grep -q .

existing_admin_key="$(<"$tmp/secrets/gateway.admin-key")"
rm "$tmp/secrets/gateway.reserve-signer-token"
"$ROOT/scripts/make-secrets.sh" "$tmp/secrets" gdc-node0 >/dev/null
[[ -s "$tmp/secrets/gateway.reserve-signer-token" ]]
[[ "$(stat -c '%a' "$tmp/secrets/gateway.reserve-signer-token")" == 600 ]]
[[ "$(<"$tmp/secrets/gateway.admin-key")" == "$existing_admin_key" ]]
grep -Fq 'READY gateway reserve signer credential %s' "$ROOT/scripts/phase-ops.sh"
grep -Fq '"$ROOT/scripts/make-secrets.sh" "$SECRETS" "$GENESIS_NODE"' "$ROOT/scripts/phase-ops.sh"

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
! test -e "$ROOT/scripts/detect-gpu-profile.sh"
! grep -Fq 'VLLM_ATTENTION_BACKEND' "$ROOT/02-node/ml-only/compose.yaml"
! grep -Fq 'VLLM_ATTENTION_BACKEND' "$ROOT/02-node/compose.ml-local.yaml"
grep -Fq 'qualification_status=skipped_by_operator' "$ROOT/scripts/phase-genesis.sh"
grep -Fq "printf 'ml_qualification=%s" "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'ML qualification explicitly disabled by the Genesis operator' "$ROOT/scripts/phase-genesis.sh"
grep -Fq -- '--skip-qualification' "$ROOT/ROLE-GENESIS.md"
! grep -Fq -- '--sckip-qualification' "$ROOT/ROLE-GENESIS.md"
grep -Fq 'phase-bootstrap-access.sh' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'Refresh the Telegram inference consumer for the new gateway' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'phase-gateway-access-key.sh" ensure telegram' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'phase-telegram-consumer.sh" apply' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'Require bounded Genesis validator effectiveness before lifecycle success' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'phase-join-acceptance.sh' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'phase-ops.sh" monitoring' "$ROOT/scripts/phase-genesis.sh"
! grep -Fq 'GDC_JOIN_GATEWAY_CLIENT_KEY_FILE' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'gateway/join-client-key' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'gateway/join-client-key' "$ROOT/scripts/fetch-join-bootstrap.sh"
grep -Fq 'cold-address backup disagrees with the keyring' "$ROOT/01-identities-genesis/create-cold-accounts.sh"
grep -Fq 'keys add "$name" --recover --keyring-backend file' "$ROOT/01-identities-genesis/create-cold-accounts.sh"
grep -Fq 'Ensure $NODE cold account is available for transaction signing' "$ROOT/scripts/phase-join.sh"
grep -Fq "failed to calculate the canonical Genesis SHA-256" "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'Genesis ceremony record is missing $profile_field' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'FAILED Genesis command at line' "$ROOT/scripts/phase-genesis.sh"
grep -Fq '"$BACKUP_DIR/$name.address"' "$ROOT/01-identities-genesis/create-cold-accounts.sh"
grep -Fq 'cold-address references' "$ROOT/scripts/phase-identities.sh"
grep -Fq 'INCOMPLETE Genesis was created without bootstrap access' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'phase-ops.sh" faucet' "$ROOT/scripts/phase-genesis.sh"
bootstrap_line="$(grep -n 'Publish the complete JOIN bootstrap before independent operators can join' "$ROOT/scripts/phase-genesis.sh" | cut -d: -f1)"
synchronize_line="$(grep -n 'Synchronize the published JOIN bootstrap on the public edge' "$ROOT/scripts/phase-genesis.sh" | cut -d: -f1)"
access_line="$(grep -n 'Bootstrap authenticated inference for the single-validator network' "$ROOT/scripts/phase-genesis.sh" | cut -d: -f1)"
[[ "$bootstrap_line" =~ ^[1-9][0-9]*$ && "$synchronize_line" =~ ^[1-9][0-9]*$ && "$access_line" =~ ^[1-9][0-9]*$ && "$bootstrap_line" -lt "$synchronize_line" && "$synchronize_line" -lt "$access_line" ]]
grep -Fq 'gdc-faucet-cold.json' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'persist_runtime_topology' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'genesis_activation_is_current()' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'resuming Genesis bootstrap from the verified ACTIVE participant' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'existing Genesis activation does not match the local ceremony or is not ACTIVE' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'capture_canonical_genesis "https://${GENESIS_PUBLIC_HOST}/chain-rpc/genesis"' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'runtime-topology.env' "$ROOT/scripts/lib.sh"
(
  export GDC_HOME="$tmp/runtime-home"
  source "$ROOT/scripts/lib.sh"
  STATE="$tmp/runtime-state"
  export GENESIS_NODE=gdc-node0
  export PUBLIC_EDGE_NODE=gdc-node0
  export GATEWAY_NODE=gdc-node0
  export TELEGRAM_BOT_HOST=gdc-node0
  export GDC_GENESIS_GUARDIAN_ENABLED=false
  persist_runtime_topology
  grep -qx 'GDC_GENESIS_NODE=gdc-node0' "$STATE/runtime-topology.env"
  grep -qx 'GDC_PUBLIC_EDGE_NODE=gdc-node0' "$STATE/runtime-topology.env"
  grep -qx 'GDC_GATEWAY_NODE=gdc-node0' "$STATE/runtime-topology.env"
  grep -qx 'GDC_TELEGRAM_BOT_HOST=gdc-node0' "$STATE/runtime-topology.env"
)
grep -Fq 'ensure-inferenced-cli.sh' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'GONKA_RELEASE=0.2.14' "$ROOT/profiles/releases/v2026.07.23.lock"
grep -Fq 'GONKA_RELEASE=0.2.15' "$ROOT/profiles/releases/v2026.08.06.lock"

printf 'PASS Genesis and independent-validator identity contract\n'
