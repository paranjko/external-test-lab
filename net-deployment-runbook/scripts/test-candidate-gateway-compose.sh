#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/profile.sh"
temporary="$(mktemp -d /tmp/gdc-test-candidate-gateway-compose.XXXXXX)"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

cp "$ROOT/04-ops/compose.yaml" "$temporary/compose.yaml"
touch "$temporary/gateway.env" "$temporary/faucet.env" \
  "$temporary/gateway-reserve-signer.env"

config="$({
  DEVSHARD_GATEWAY_DATA_VOLUME=gateway-data-v5 \
  DEVSHARD_GATEWAY_DATA_VOLUME_V5_NAME=gdc-ops_gateway-data-v5-test \
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
jq -e '.volumes["gateway-data-v5"].name == "gdc-ops_gateway-data-v5-test"' <<<"$config" >/dev/null
jq -e '.services["devshard-gateway"].healthcheck.test[1] | contains("$${DEVSHARD_PORT}")' \
  <<<"$config" >/dev/null

export LOCAL_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate
export LAB_CANDIDATE=true
export DEVSHARD_PROTOCOL_VERSION=v5
candidate_v3_image="$(local_gateway_image_for_protocol v3)"
candidate_v3_config="$({
  DEVSHARD_GATEWAY_DATA_VOLUME=gateway-data-v3 \
  LOCAL_GATEWAY_IMAGE="$candidate_v3_image" \
  INFERENCED_IMAGE=ghcr.io/paranjko/gdc-inferenced:candidate \
  SITE_HOST=site.example.invalid \
  API_HOST=api.example.invalid \
  GRAFANA_HOST=grafana.example.invalid \
  GATEWAY_PUBLIC_HOST=gateway.example.invalid \
  PUBLIC_EDGE_CIDR=192.0.2.0/24 \
    docker compose --project-directory "$temporary" \
      -f "$temporary/compose.yaml" config --format json
})"
jq -e --arg expected "$candidate_v3_image" \
  '.services["devshard-gateway"].image == $expected' <<<"$candidate_v3_config" >/dev/null

printf 'PASS candidate gateway Compose image and state-volume contracts\n'
