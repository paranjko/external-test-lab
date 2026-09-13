#!/usr/bin/env bash
set -Eeuo pipefail
ENV_FILE="${1:-.env}"
# The chain binds this key permanently: pass the TMKMS key, not the node's own.
CONSENSUS_KEY="${2:-}"
HERE="$(cd "$(dirname "$ENV_FILE")" && pwd)"; ENV_FILE="$HERE/$(basename "$ENV_FILE")"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ "$IS_GENESIS" == false ]] || { echo 'Do not register the genesis participant again' >&2; exit 1; }
cd "$HERE"
consensus_args=()
if [[ -n "$CONSENSUS_KEY" ]]; then
  [[ "$CONSENSUS_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || { echo 'consensus key must be a base64-encoded Ed25519 public key' >&2; exit 2; }
  consensus_args=(--consensus-key "$CONSENSUS_KEY")
fi
docker compose --env-file "$ENV_FILE" -f compose.yaml exec -T api \
  inferenced register-new-participant "$PUBLIC_URL" "$ACCOUNT_PUBKEY" \
  "${consensus_args[@]}" \
  --node-address "$SEED_API_URL"
