#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/profile.sh"
load_profiles

caddyfile="$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq '@participant_poc path /v1/poc/*' "$caddyfile"
grep -Fq 'handle @participant_poc {' "$caddyfile"
grep -Fq '@participant_devshard path /devshard/*' "$caddyfile"
grep -Fq 'handle @participant_devshard {' "$caddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:8000 {' "$caddyfile"
grep -Fq '@participant_chain path /chain-rpc/* /chain-api/*' "$caddyfile"
grep -Fq '@participant_api_status path /health /status /v1/versions /v2/participants /v2/participants/*' "$caddyfile"
grep -Fq 'handle @participant_api_status {' "$caddyfile"
grep -Fq 'header_up Host {$PUBLIC_HOST}' "$caddyfile"
grep -Fq 'handle /v1.bootstrap.schema.json' "$caddyfile"
grep -Fq 'path_regexp network_bootstrap' "$caddyfile"
! grep -Fq 'handle_path /bootstrap/*' "$caddyfile"
! grep -Fq '/join-bootstrap/' "$caddyfile"
grep -Fq 'handle_path /faucet/* {' "$caddyfile"

public_caddyfile="$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq '@participant_devshard path /devshard/*' "$public_caddyfile"
grep -Fq 'handle @participant_devshard {' "$public_caddyfile"
grep -Fq '@participant_chain path /chain-rpc/* /chain-api/*' "$public_caddyfile"
grep -Fq '@participant_api_status path /health /status /v1/versions /v2/participants /v2/participants/*' "$public_caddyfile"
grep -Fq 'handle @participant_api_status {' "$public_caddyfile"
grep -Fq '@gateway_dapi path /health /status /v2/participants /v2/participants/* /chain-rpc /chain-rpc/* /chain-api /chain-api/*' "$public_caddyfile"
chain_route_line="$(grep -nF '@chain_readonly path /chain-rpc/* /chain-api/*' "$public_caddyfile" | cut -d: -f1)"
gateway_route_line="$(grep -nF '@gateway_dapi path /health /status /v2/participants /v2/participants/* /chain-rpc /chain-rpc/* /chain-api /chain-api/*' "$public_caddyfile" | cut -d: -f1)"
[[ "$chain_route_line" =~ ^[0-9]+$ && "$gateway_route_line" =~ ^[0-9]+$ && "$chain_route_line" -lt "$gateway_route_line" ]] || {
  echo 'public chain routes must precede the gateway route' >&2
  exit 1
}
grep -Fq 'reverse_proxy {$GATEWAY_DAPI_UPSTREAM} {' "$public_caddyfile"
grep -Fq 'Host-qualified chain routes' "$public_caddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:8000 {' "$public_caddyfile"
grep -Fq '@prometheus_from_public_edge {' "$caddyfile"

if ! output="$(docker run --rm \
  -e ACME_EMAIL=ops@example.test \
  -e PUBLIC_HOST=node3.gonka-dev.net \
  -e PUBLIC_EDGE_HOST=node0.gonka-dev.net \
  -v "$caddyfile:/etc/caddy/Caddyfile:ro" \
  "$CADDY_IMAGE" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
  printf '%s\n' "$output" >&2
  exit 1
fi

printf 'PASS participant PoC Caddy route contract\n'
