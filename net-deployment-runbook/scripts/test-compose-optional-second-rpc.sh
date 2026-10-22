#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

write_env() {
  local rpc2="$1" path="$2"
  local state_sync=false
  [[ -z "$rpc2" ]] || state_sync=true
  cat >"$path" <<EOF
CHAIN_ID=fixture-chain
DATA_DIR=/srv/dai/data
IDENTITY_DIR=/srv/dai/identity
SIGNER_DIR=/srv/dai/signer
GENESIS_FILE=/srv/dai/shared/genesis.json
NODE_CONFIG_FILE=./node-config.json
ACCOUNT_PUBKEY=fixture-account-key
KEY_NAME=fixture-node
KEYRING_PASSWORD=fixture-keyring-password
POSTGRES_PASSWORD=fixture-postgres-password
PUBLIC_HOST=fixture.example.invalid
PUBLIC_URL=https://fixture.example.invalid
P2P_EXTERNAL_ADDRESS=tcp://fixture.example.invalid:26656
GENESIS_SEEDS=fixture@fixture.example.invalid:26656
SEED_API_URL=https://seed.example.invalid
SEED_NODE_RPC_URL=https://seed.example.invalid/chain-rpc/
SEED_NODE_P2P_URL=tcp://seed.example.invalid:26656
RPC_SERVER_URL_1=https://seed.example.invalid/chain-rpc/
RPC_SERVER_URL_2=$rpc2
SYNC_WITH_SNAPSHOTS=$state_sync
GDC_JOIN_STATESYNC_ENABLE=$state_sync
PROXY_POLICY_IMAGE=example.invalid/proxy-policy:fixture
VERSIOND_ROUTER_IMAGE=example.invalid/versiond-router:fixture
EXPLORER_IMAGE=example.invalid/explorer:fixture
EOF
}

render_and_assert() {
  local layout="$1" compose="$2" rpc2="$3" expected="${4-}"
  local env_file="$tmp/$layout.env" output="$tmp/$layout.json" state_sync=false
  [[ -z "$rpc2" ]] || state_sync=true
  write_env "$rpc2" "$env_file"
  docker compose --env-file "$env_file" -f "$compose" config --format json >"$output"
  jq -e --arg expected "$expected" '
    .services.node.environment.RPC_SERVER_URL_1 == "https://seed.example.invalid/chain-rpc/" and
    .services.node.environment.RPC_SERVER_URL_2 == $expected
  ' "$output" >/dev/null || {
    echo "Compose RPC environment mismatch in $layout layout" >&2
    jq '.services.node.environment | {RPC_SERVER_URL_1,RPC_SERVER_URL_2}' "$output" >&2
    return 1
  }
  jq -e --arg state_sync "$state_sync" '
    .services.node.environment.CONFIG_statesync__enable == $state_sync and
    .services.node.environment.SYNC_WITH_SNAPSHOTS == $state_sync
  ' "$output" >/dev/null || {
    echo "Compose state-sync flags mismatch in $layout layout" >&2
    jq '.services.node.environment | {CONFIG_statesync__enable,SYNC_WITH_SNAPSHOTS}' "$output" >&2
    return 1
  }
}

base_compose="$ROOT/02-node/compose.yaml"
bootstrap_compose="$tmp/bootstrap-compose.json"
empty_env="$tmp/empty.env"
: >"$empty_env"
bash "$ROOT/02-node/render-bootstrap-compose.sh" "$base_compose" "$empty_env" >"$bootstrap_compose"

# Fresh full-sync Bootstrap renders a sole RPC; both the ordinary Compose
# topology and the adapted Bootstrap topology must preserve an empty second
# RPC as an explicit empty container environment value.
render_and_assert legacy-full-sync "$base_compose" '' ''
render_and_assert fresh-full-sync "$bootstrap_compose" '' ''

# Existing state-sync JOIN continues to render two distinct RPC origins.
second='https://witness.example.invalid/chain-rpc/'
write_env "$second" "$tmp/legacy-state-sync.env"
docker compose --env-file "$tmp/legacy-state-sync.env" -f "$base_compose" config --format json >"$tmp/legacy-state-sync.json"
jq -e --arg second "$second" '
  .services.node.environment.RPC_SERVER_URL_1 == "https://seed.example.invalid/chain-rpc/" and
  .services.node.environment.RPC_SERVER_URL_2 == $second and
  .services.node.environment.RPC_SERVER_URL_1 != .services.node.environment.RPC_SERVER_URL_2 and
  .services.node.environment.CONFIG_statesync__enable == "true" and
  .services.node.environment.SYNC_WITH_SNAPSHOTS == "true"
' "$tmp/legacy-state-sync.json" >/dev/null
write_env "$second" "$tmp/fresh-state-sync.env"
docker compose --env-file "$tmp/fresh-state-sync.env" -f "$bootstrap_compose" config --format json >"$tmp/fresh-state-sync.json"
jq -e --arg second "$second" '
  .services.node.environment.RPC_SERVER_URL_1 == "https://seed.example.invalid/chain-rpc/" and
  .services.node.environment.RPC_SERVER_URL_2 == $second and
  .services.node.environment.RPC_SERVER_URL_1 != .services.node.environment.RPC_SERVER_URL_2 and
  .services.node.environment.CONFIG_statesync__enable == "true" and
  .services.node.environment.SYNC_WITH_SNAPSHOTS == "true"
' "$tmp/fresh-state-sync.json" >/dev/null

printf 'PASS Compose accepts a single full-sync RPC and retains distinct state-sync RPCs in base and Bootstrap layouts\n'
