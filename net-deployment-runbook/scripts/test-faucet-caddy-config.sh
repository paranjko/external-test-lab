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
printf 'PASS public faucet Caddy route contract\n'
