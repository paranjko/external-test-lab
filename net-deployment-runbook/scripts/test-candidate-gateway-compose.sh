#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d /tmp/gdc-test-candidate-gateway-compose.XXXXXX)"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

cp "$ROOT/04-ops/compose.yaml" "$temporary/compose.yaml"
touch "$temporary/gateway.env" "$temporary/faucet.env" \
  "$temporary/gateway-reserve-signer.env"

config="$({
  DEVSHARD_GATEWAY_DATA_VOLUME=gateway-data-v5 \
  LOCAL_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate-v5 \
  INFERENCED_IMAGE=ghcr.io/paranjko/gdc-inferenced:candidate \
  SITE_HOST=site.example.invalid \
  API_HOST=api.example.invalid \
  GRAFANA_HOST=grafana.example.invalid \
  GATEWAY_PUBLIC_HOST=gateway.example.invalid \
  PUBLIC_EDGE_CIDR=192.0.2.0/24 \
    docker compose --project-directory "$temporary" \
      -f "$temporary/compose.yaml" config --format json
})"

jq -e '
  .services["devshard-gateway"].volumes
  | any(.type == "volume" and .source == "gateway-data-v5" and .target == "/root/.devshardctl")
' <<<"$config" >/dev/null
jq -e '.volumes | has("gateway-data-v5")' <<<"$config" >/dev/null

printf 'PASS candidate v5 gateway Compose state volume\n'
