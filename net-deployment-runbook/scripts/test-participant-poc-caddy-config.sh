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
grep -Fq 'header_up Host {$PUBLIC_HOST}' "$caddyfile"
grep -Fq '@join_bootstrap path /join-bootstrap/*' "$caddyfile"
grep -Fq 'handle_path /faucet/* {' "$caddyfile"

public_caddyfile="$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq '@participant_devshard path /devshard/*' "$public_caddyfile"
grep -Fq 'handle @participant_devshard {' "$public_caddyfile"
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
