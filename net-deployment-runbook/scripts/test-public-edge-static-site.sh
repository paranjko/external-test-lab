#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
name="gdc-public-edge-site-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

command -v docker >/dev/null || { echo 'docker is required for the public-edge integration test' >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo 'docker daemon is required for the public-edge integration test' >&2; exit 2; }

mkdir -p "$tmp/site"
sed -e '/^[[:space:]]*email {\$ACME_EMAIL}[[:space:]]*$/d' \
  -e '/^www\.{$SITE_HOST} {/,/^}/d' \
  "$ROOT/04-ops/edge-node/PublicCaddyfile" >"$tmp/Caddyfile"
printf '%s\n' '<!doctype html><title>edge-resilient</title><main>EXTERNAL TEST LAB</main>' >"$tmp/site/index.html"

docker run -d --name "$name" -p 127.0.0.1::18081 \
  -e PUBLIC_HOST=:18082 \
  -e SITE_HOST=:18081 \
  -e API_HOST=:18083 \
  -e GRAFANA_HOST=:18084 \
  -e GATEWAY_PUBLIC_HOST=127.0.0.1 \
  -e TELEGRAM_BOT_PUBLIC_HOST=127.0.0.1 \
  -e MONITORING_CIDR=127.0.0.1/32 \
  -e PUBLIC_EDGE_CIDR=127.0.0.1/32 \
  -v "$tmp/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$tmp/site:/srv/dai/edge/site:ro" \
  caddy:2.11.4-alpine caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

port="$(docker port "$name" 18081/tcp | awk -F: 'NR == 1 {print $NF}')"
[[ "$port" =~ ^[1-9][0-9]*$ ]] || { docker logs "$name" >&2; exit 1; }
deadline=$((SECONDS + 20))
while (( SECONDS < deadline )); do
  if curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:$port/" >"$tmp/homepage" 2>/dev/null \
    && grep -q 'EXTERNAL TEST LAB' "$tmp/homepage"; then
    break
  fi
  sleep 1
done
curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:$port/" | grep -q 'EXTERNAL TEST LAB' || {
  docker logs "$name" >&2
  exit 1
}
status="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "http://127.0.0.1:$port/status/participants" 2>/dev/null || true)"
[[ "$status" == 502 ]] || { echo "expected unavailable dynamic status to return 502, got $status" >&2; exit 1; }

printf 'PASS public edge serves static site while gateway status upstream is unavailable\n'
