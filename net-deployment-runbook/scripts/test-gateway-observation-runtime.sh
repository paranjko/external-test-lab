#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
containers=()
cleanup() {
  for container in "${containers[@]}"; do docker rm -f "$container" >/dev/null 2>&1 || true; done
  rm -rf -- "$tmp"
}
trap cleanup EXIT
image="${CADDY_TEST_IMAGE:-caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d}"
for layout in directory file; do
  directory="$tmp/$layout"
  mkdir -p "$directory"
  cat >"$directory/Caddyfile" <<'CADDY'
{
  admin 127.0.0.1:2019
  auto_https off
}
http://{$PUBLIC_HOST} {
  route {
    handle /serving {
      respond "retained" 200
    }
    handle {
      respond 404
    }
  }
}
CADDY
  host="fixture-$layout"
  name="gdc-observe-$layout-$$"
  containers+=("$name")
  mount="$directory:/config:ro"
  [[ "$layout" != file ]] || mount="$directory/Caddyfile:/config/Caddyfile:ro"
  docker run -d --name "$name" --label com.docker.compose.service=caddy \
    -e "PUBLIC_HOST=$host" -p 127.0.0.1::80 -v "$mount" "$image" \
    caddy run --config /config/Caddyfile --adapter caddyfile >/dev/null
  port="$(docker port "$name" 80/tcp | cut -d: -f2)"
  for _ in {1..30}; do
    if curl -fsS -H "Host: $host" "http://127.0.0.1:$port/serving" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  curl -fsS -H "Host: $host" "http://127.0.0.1:$port/serving" >/dev/null
  bash "$ROOT/04-ops/render-gateway-observation.sh" \
    '[{"id":"A_V6","node":"a","port":18146}]' a 192.0.2.4/32 >"$directory/fragment"
  before_id="$(docker inspect -f '{{.Id}}' "$name")"
  bash "$ROOT/04-ops/install-gateway-observation.sh" "$host" "$directory/fragment"
  for _ in {1..10}; do
    serving="$(curl -fsS -H "Host: $host" "http://127.0.0.1:$port/serving" 2>/dev/null || true)"
    [[ "$serving" != retained ]] || break
    sleep 1
  done
  [[ "$serving" == retained ]]
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "http://127.0.0.1:$port/ops-gateways/A_V6/metrics")" == 403 ]]
  sha="$(sha256sum "$directory/Caddyfile")"
  bash "$ROOT/04-ops/install-gateway-observation.sh" "$host" "$directory/fragment"
  [[ "$sha" == "$(sha256sum "$directory/Caddyfile")" ]]
  [[ "$before_id" == "$(docker inspect -f '{{.Id}}' "$name")" ]]
  docker restart "$name" >/dev/null
  port="$(docker port "$name" 80/tcp | cut -d: -f2)"
  for _ in {1..30}; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "http://127.0.0.1:$port/ops-gateways/A_V6/status" || true)"
    [[ "$code" != 403 ]] || break
    sleep 1
  done
  [[ "$code" == 403 ]]
  printf 'PASS Caddy %s mount, serving preservation, restricted route, idempotency and restart persistence\n' "$layout"
done
