#!/usr/bin/env bash
set -Eeuo pipefail
ENV_FILE="${1:-.env}"
HERE="$(cd "$(dirname "$ENV_FILE")" && pwd)"; ENV_FILE="$HERE/$(basename "$ENV_FILE")"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ "$IS_GENESIS" == false ]] || { echo 'Do not register the genesis participant again' >&2; exit 1; }
[[ "$(base64 -d <<<"${CONSENSUS_PUBKEY:-}" 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] \
  || { echo 'CONSENSUS_PUBKEY is missing or invalid; refuse registration with an inferred validator key' >&2; exit 1; }
cd "$HERE"
docker compose --env-file "$ENV_FILE" -f compose.yaml exec -T api \
  inferenced register-new-participant "$PUBLIC_URL" "$ACCOUNT_PUBKEY" \
  --consensus-key "$CONSENSUS_PUBKEY" \
  --node-address "$SEED_API_URL"
