#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --inventory FILE --node-name gdc-nodeN --account-public FILE [--seeds-file FILE|--bootstrap] --secrets-dir DIR [--poc-callback-url URL --ml-callback-bind IP] --output FILE" >&2; }
INVENTORY=''; NODE=''; ACCOUNT=''; SEEDS_FILE=''; SECRETS=''; OUTPUT=''; BOOTSTRAP=false; POC_CALLBACK_URL='http://api:9100'; ML_CALLBACK_BIND='127.0.0.1'
while (($#)); do case "$1" in
  --inventory) INVENTORY="$2"; shift 2 ;;
  --node-name) NODE="$2"; shift 2 ;;
  --account-public) ACCOUNT="$2"; shift 2 ;;
  --seeds-file) SEEDS_FILE="$2"; shift 2 ;;
  --bootstrap) BOOTSTRAP=true; shift ;;
  --secrets-dir) SECRETS="$2"; shift 2 ;;
  --poc-callback-url) POC_CALLBACK_URL="$2"; shift 2 ;;
  --ml-callback-bind) ML_CALLBACK_BIND="$2"; shift 2 ;;
  --output) OUTPUT="$2"; shift 2 ;;
  *) usage; exit 2 ;;
esac; done
[[ "$NODE" =~ ^gdc-node[0-4]$ ]] || { usage; exit 2; }
[[ "$POC_CALLBACK_URL" =~ ^http://([0-9]{1,3}\.){3}[0-9]{1,3}:9100$|^http://api:9100$ ]] || { echo 'PoC callback URL must be http://api:9100 or an IPv4 address on port 9100' >&2; exit 2; }
[[ "$ML_CALLBACK_BIND" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo 'ML callback bind must be an IPv4 address' >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
source "$ROOT/scripts/profile.sh"
load_profiles
INDEX="${NODE#gdc-node}"; PREFIX="NODE${INDEX}_"
PUBLIC_HOST="${PREFIX}PUBLIC_HOST"; P2P_PORT="${PREFIX}P2P_PORT"; GPU_PROFILE="${PREFIX}GPU_PROFILE"
ADDRESS="$(jq -r .address "$ACCOUNT")"
PUBKEY="$(jq -r .account_pubkey_b64 "$ACCOUNT")"
[[ "$ADDRESS" =~ ^gonka1[0-9a-z]{20,90}$ ]] || { echo "Invalid account: $ACCOUNT" >&2; exit 1; }
if [[ "$BOOTSTRAP" == true ]]; then SEEDS='identity-bootstrap-only'; else SEEDS="$(<"$SEEDS_FILE")"; fi
KEYRING_PASSWORD="$(<"$SECRETS/$NODE.keyring")"
POSTGRES_PASSWORD="$(<"$SECRETS/$NODE.postgres")"
IS_GENESIS=false; [[ "$INDEX" == 0 ]] && IS_GENESIS=true
ATTENTION_BACKEND="$(attention_backend_for_profile "${!GPU_PROFILE}")"
write_env "$OUTPUT" \
  "COMPOSE_PROJECT_NAME=$NODE" "COMPOSE_PROFILES=$EDGE_API_COMPOSE_PROFILE" "NODE_NAME=$NODE" "CHAIN_ID=$CHAIN_ID" "BASE_DENOM=$BASE_DENOM" \
  "GDC_RELEASE_PROFILE=$GDC_RELEASE_PROFILE" "GDC_PROFILE_HASH=$(profile_hash)" "GONKA_COMMIT=$GONKA_COMMIT" \
  "PUBLIC_HOST=${!PUBLIC_HOST}" "PUBLIC_URL=https://${!PUBLIC_HOST}" "P2P_PORT=${!P2P_PORT}" \
  "P2P_EXTERNAL_ADDRESS=tcp://${!PUBLIC_HOST}:${!P2P_PORT}" "LOCAL_PROXY_PORT=8000" \
  "DATA_DIR=${DATA_ROOT%/}/$NODE" "HF_HOME=$HF_CACHE_ROOT" "GENESIS_FILE=$GENESIS_INSTALL_PATH" \
  "PROXY_BIND_ADDRESS=$([[ "$IS_GENESIS" == true ]] && echo 0.0.0.0 || echo 127.0.0.1)" \
  "NODE_CONFIG_FILE=./node-config.json" "ACCOUNT_ADDRESS=$ADDRESS" "ACCOUNT_PUBKEY=$PUBKEY" \
  "KEY_NAME=$NODE-warm" "KEYRING_PASSWORD=$KEYRING_PASSWORD" "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
  "DAPI_API__POC_CALLBACK_URL=$POC_CALLBACK_URL" "ML_CALLBACK_BIND=$ML_CALLBACK_BIND" \
  "IS_GENESIS=$IS_GENESIS" "INIT_ONLY=false" "GENESIS_SEEDS=$SEEDS" "SYNC_WITH_SNAPSHOTS=false" \
  "SEED_API_URL=https://$NODE0_PUBLIC_HOST" "SEED_NODE_RPC_URL=https://$NODE0_PUBLIC_HOST/chain-rpc/" \
  "SEED_NODE_P2P_URL=tcp://$NODE0_PUBLIC_HOST:$NODE0_P2P_PORT" \
  "RPC_SERVER_URL_1=https://$NODE0_PUBLIC_HOST/chain-rpc/" "RPC_SERVER_URL_2=https://$NODE1_PUBLIC_HOST/chain-rpc/" \
  "TMKMS_IMAGE=$TMKMS_IMAGE" "INFERENCED_IMAGE=$INFERENCED_IMAGE" "POSTGRES_IMAGE=$POSTGRES_IMAGE" \
  "DAPI_IMAGE=$DAPI_IMAGE" "EDGE_API_IMAGE=$EDGE_API_IMAGE" "EDGE_API_SERVICE_NAME=$EDGE_API_SERVICE_NAME" "VERSIOND_IMAGE=$VERSIOND_IMAGE" "PROXY_IMAGE=$PROXY_IMAGE" \
  "EXPLORER_IMAGE=$EXPLORER_IMAGE" "DASHBOARD_PORT=$DASHBOARD_PORT" \
  "MLNODE_IMAGE=$MLNODE_GENERIC_IMAGE" "MLNODE_PROXY_IMAGE=$MLNODE_PROXY_IMAGE" \
  "GPU_PROFILE=${!GPU_PROFILE}" "VLLM_ATTENTION_BACKEND=$ATTENTION_BACKEND" "POC_BATCH_SIZE_DEFAULT=32"
echo "$OUTPUT"
