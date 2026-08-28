#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/profile.sh"
load_profiles

if ! output="$(docker run --rm \
  -e GATEWAY_PUBLIC_HOST=node0.gonka-dev.net \
  -v "$ROOT/04-ops/Caddyfile:/etc/caddy/Caddyfile:ro" \
  "$CADDY_IMAGE" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)"; then
  printf '%s\n' "$output" >&2
  exit 1
fi
grep -Fq "'FAUCET_LISTEN_PORT=18083'" "$ROOT/scripts/phase-ops.sh"
grep -Fq 'GDC_GATEWAY_RESERVE_SIGNER_URL=${GDC_GATEWAY_RESERVE_SIGNER_URL:-http://127.0.0.1:18083}' "$ROOT/04-ops/create-gateway.sh"
! test -e "$ROOT/04-ops/edge-node/bootstrap-nginx.conf"
grep -Fq 'handle /v1.bootstrap.schema.json' "$ROOT/04-ops/edge-node/PublicCaddyfile"
! grep -Fq "'FAUCET_LISTEN_PORT=18082'" "$ROOT/scripts/phase-ops.sh"
printf 'PASS public faucet and v1 bootstrap Caddy route contract\n'
