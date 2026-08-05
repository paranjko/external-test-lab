#!/usr/bin/env bash
set -Eeuo pipefail
ENV_FILE="${1:-.env}"
HERE="$(cd "$(dirname "$ENV_FILE")" && pwd)"; ENV_FILE="$HERE/$(basename "$ENV_FILE")"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ "$IS_GENESIS" == false ]] || { echo 'Do not register the genesis participant again' >&2; exit 1; }
cd "$HERE"
docker compose --env-file "$ENV_FILE" -f compose.yaml exec -T api \
  inferenced register-new-participant "$PUBLIC_URL" "$ACCOUNT_PUBKEY" \
  --node-address "$SEED_API_URL"
