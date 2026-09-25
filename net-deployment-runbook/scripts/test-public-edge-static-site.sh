#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp_root="${TMPDIR:-$ROOT/../.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/gdc-public-edge-site.XXXXXX")"
name="gdc-public-edge-site-$$"
upstream_name="gdc-public-edge-upstream-$$"
admission_name="gdc-public-edge-admission-$$"
network="gdc-public-edge-test-$$"
trap 'docker rm -f "$name" "$upstream_name" "$admission_name" >/dev/null 2>&1 || true; docker network rm "$network" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

command -v docker >/dev/null || { echo 'docker is required for the public-edge integration test' >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo 'docker daemon is required for the public-edge integration test' >&2; exit 2; }

mkdir -p "$tmp/site" "$tmp/bootstrap/gonka-devnet-community" "$tmp/upstream" "$tmp/admission"
sed -e '/^[[:space:]]*email {\$ACME_EMAIL}[[:space:]]*$/d' \
  -e '/^www\.{$SITE_HOST} {/,/^}/d' \
  -e '/^preview\.{$SITE_HOST} {/,/^}/d' \
  "$ROOT/04-ops/edge-node/PublicCaddyfile" >"$tmp/Caddyfile"
printf '%s\n' '<!doctype html><title>edge-resilient</title><main>EXTERNAL TEST LAB</main>' >"$tmp/site/index.html"
printf '%s\n' '{"chain_id":"gonka-devnet-community","fixture":"byte-equivalent"}' >"$tmp/bootstrap/gonka-devnet-community/bootstrap.json"
printf '%s\n' 'CHAIN_ID=gonka-devnet-community' >"$tmp/bootstrap/gonka-devnet-community/bootstrap.env"
schema_id='$id'
printf '{"%s":"https://gonka-dev.net/v1.bootstrap.schema.json"}\n' "$schema_id" >"$tmp/bootstrap/v1.bootstrap.schema.json"

cat >"$tmp/upstream/Caddyfile" <<'CADDY'
:8081 {
  handle /status/missing {
    respond "missing" 404
  }
  handle /status/gateway/v1/admission-status {
    respond "wrong upstream" 200
  }
  handle /status/* {
    respond "{http.request.uri}" 200
  }
}
CADDY

cat >"$tmp/admission/Caddyfile" <<'CADDY'
http://127.0.0.1:18083 {
  respond "local admission" 200
}
CADDY

docker network create "$network" >/dev/null
docker run -d --name "$upstream_name" --network "$network" --network-alias gateway \
  -v "$tmp/upstream/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2.11.4-alpine caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

docker run --rm \
  -e PUBLIC_HOST=:18082 \
  -e SITE_HOST=:18081 \
  -e API_HOST=:18083 \
  -e GRAFANA_HOST=:18084 \
  -e GATEWAY_PUBLIC_HOST=gateway \
  -e TELEGRAM_BOT_PUBLIC_HOST=gateway \
  -e MONITORING_CIDR=127.0.0.1/32 \
  -e PUBLIC_EDGE_CIDR=127.0.0.1/32 \
  -v "$tmp/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2.11.4-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

grep -Fq 'path_regexp preview_telegram_consumer ^/preview/[1-9][0-9]*/status/telegram-consumer$' "$tmp/Caddyfile"
grep -Fq 'rewrite * /ops-telegram-consumer-health' "$tmp/Caddyfile"
grep -Fq 'reverse_proxy https://{$TELEGRAM_BOT_PUBLIC_HOST}' "$tmp/Caddyfile"
grep -Fq 'preview.{$SITE_HOST} {' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:18090' "$ROOT/04-ops/edge-node/PublicCaddyfile"

docker run -d --name "$name" --network "$network" -p 127.0.0.1::18081 \
  -e PUBLIC_HOST=:18082 \
  -e SITE_HOST=:18081 \
  -e API_HOST=:18083 \
  -e GRAFANA_HOST=:18084 \
  -e GATEWAY_PUBLIC_HOST=gateway \
  -e TELEGRAM_BOT_PUBLIC_HOST=gateway \
  -e MONITORING_CIDR=127.0.0.1/32 \
  -e PUBLIC_EDGE_CIDR=127.0.0.1/32 \
  -v "$tmp/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$tmp/bootstrap:/edge/bootstrap/current:ro" \
  -v "$tmp/site:/srv/dai/edge/site:ro" \
  caddy:2.11.4-alpine caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

docker run -d --name "$admission_name" --network "container:$name" \
  -v "$tmp/admission/Caddyfile:/etc/caddy/Caddyfile:ro" \
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
curl -fsS "http://127.0.0.1:$port/status/participants" | grep -Fxq '/status/participants'
curl -fsS "http://127.0.0.1:$port/preview/172/status/participants" | grep -Fxq '/status/participants'
curl -fsS "http://127.0.0.1:$port/preview/172/status/gdc-node3/health" | grep -Fxq '/status/gdc-node3/health'
missing="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "http://127.0.0.1:$port/preview/172/status/missing" 2>/dev/null || true)"
[[ "$missing" == 404 ]] || { echo "expected preview upstream 404 to propagate, got $missing" >&2; exit 1; }
admission="$(curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:$port/preview/172/status/gateway/v1/admission-status")"
[[ "$admission" == 'local admission' ]] || { docker logs "$name" >&2; echo "preview admission did not use the local handler: $admission" >&2; exit 1; }
invalid_preview="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "http://127.0.0.1:$port/preview/0/status/participants" 2>/dev/null || true)"
[[ "$invalid_preview" == 404 ]] || { echo "invalid preview namespace unexpectedly routed: $invalid_preview" >&2; exit 1; }

curl -fsS -D "$tmp/bootstrap-json.headers" -o "$tmp/bootstrap-json.body" \
  "http://127.0.0.1:$port/gonka-devnet-community/bootstrap.json"
curl -fsS -D "$tmp/bootstrap-alias.headers" -o "$tmp/bootstrap-alias.body" \
  "http://127.0.0.1:$port/gonka-devnet-community/bootstrap"
cmp "$tmp/bootstrap-json.body" "$tmp/bootstrap-alias.body"
json_content_type="$(awk 'BEGIN { IGNORECASE=1 } /^Content-Type:/ { sub(/\r$/, "", $2); print $2 }' "$tmp/bootstrap-json.headers")"
alias_content_type="$(awk 'BEGIN { IGNORECASE=1 } /^Content-Type:/ { sub(/\r$/, "", $2); print $2 }' "$tmp/bootstrap-alias.headers")"
[[ "$json_content_type" == application/json ]] || { echo "expected bootstrap.json application/json, got $json_content_type" >&2; exit 1; }
[[ "$alias_content_type" == "$json_content_type" ]] || { echo "bootstrap alias content type differs: $alias_content_type != $json_content_type" >&2; exit 1; }
curl -fsS "http://127.0.0.1:$port/gonka-devnet-community/bootstrap.env" | cmp - "$tmp/bootstrap/gonka-devnet-community/bootstrap.env"
curl -fsS "http://127.0.0.1:$port/v1.bootstrap.schema.json" | cmp - "$tmp/bootstrap/v1.bootstrap.schema.json"

printf 'PASS public edge validates the shared preview status overlay, local admission exception and bootstrap alias\n'
