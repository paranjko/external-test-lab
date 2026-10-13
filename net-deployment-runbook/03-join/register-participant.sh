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
endpoints="${GDC_JOIN_REGISTRATION_ENDPOINTS:-${SEED_API_URL:-}}"
[[ -n "$endpoints" ]] || { echo 'JOIN has no participant registration endpoint' >&2; exit 1; }
IFS=',' read -r -a endpoint_list <<<"$endpoints"
for endpoint in "${endpoint_list[@]}"; do
  endpoint="${endpoint%/}"
  [[ "$endpoint" =~ ^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?$ ]] || {
    echo "invalid participant registration endpoint: $endpoint" >&2
    exit 1
  }
  printf 'WAIT  participant registration endpoint=%s\n' "$endpoint"
  if docker compose --env-file "$ENV_FILE" -f compose.yaml exec -T api \
    inferenced register-new-participant "$PUBLIC_URL" "$ACCOUNT_PUBKEY" \
      --consensus-key "$CONSENSUS_PUBKEY" \
      --node-address "$endpoint"; then
    printf 'READY participant registration endpoint=%s\n' "$endpoint"
    exit 0
  fi
done
echo 'participant registration was rejected by every bootstrap endpoint' >&2
exit 1
