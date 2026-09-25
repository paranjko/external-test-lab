#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$ROOT/.data/preview-status-renderer-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

inventory="$tmp/inventory.env"
install -m 0600 "$ROOT/../ops/preview/status-renderer-inventory.env" "$inventory"

"$ROOT/04-ops/render-ops.sh" --inventory "$inventory" --output-dir "$tmp/output"
[[ -s "$tmp/output/Caddyfile" && -s "$tmp/output/config.js" ]]
grep -Fq 'handle /status/gpus {' "$tmp/output/Caddyfile"
grep -Fq 'handle /status/software {' "$tmp/output/Caddyfile"
grep -Fq 'gdc_nvidia_memory_total_bytes' "$tmp/output/Caddyfile"
grep -Fq 'gdc_component_info' "$tmp/output/Caddyfile"
if grep -Eq 'GRAFANA_ADMIN_PASSWORD|GRAFANA_PUBLIC_DASHBOARD_TOKEN' "$tmp/output/config.js"; then
  echo 'preview renderer fixture leaked OPS-only configuration' >&2
  exit 1
fi

"$ROOT/../ops/preview/render-status-backend.sh" "$tmp/output/Caddyfile" "$tmp/output/config.js" 172 "$tmp/backend.Caddyfile"
grep -Fq 'gdc-preview-egress:8080' "$tmp/backend.Caddyfile"
grep -Fq 'gdc_nvidia_memory_total_bytes' "$tmp/backend.Caddyfile"
grep -Fq 'gdc_component_info' "$tmp/backend.Caddyfile"
grep -Fq '/preview/172/node/node4' "$tmp/backend.Caddyfile"
grep -Fq 'preview_gateway_status_unavailable' "$tmp/backend.Caddyfile"
grep -Fq 'path_regexp node_node4 ^/status/node4(/.*)$' "$tmp/backend.Caddyfile"
grep -Fq 'rewrite * /preview/172/node/node4{re.node_node4.1}' "$tmp/backend.Caddyfile"
docker run --rm -v "$tmp/backend.Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2.11.4-alpine caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

sed 's/gdc_component_info/unsafe_metric/' "$tmp/output/Caddyfile" >"$tmp/unsafe.Caddyfile"
if "$ROOT/../ops/preview/render-status-backend.sh" "$tmp/unsafe.Caddyfile" "$tmp/output/config.js" 172 "$tmp/unsafe-output.Caddyfile"; then
  echo 'status backend compiler accepted an unapproved query' >&2
  exit 1
fi

revision="$(git -C "$ROOT/.." rev-parse HEAD)"
image="gdc-preview-status-renderer-test:${revision:0:12}"
network="gdc-preview-status-renderer-$${RANDOM}"
egress="gdc-preview-status-egress-$$"
backend="gdc-preview-status-backend-$$"
cleanup() {
  docker rm -f "$backend" "$egress" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm -f "$image" >/dev/null 2>&1 || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT
"$ROOT/../ops/preview/build-status-backend-image.sh" "$ROOT/.." "$inventory" "$revision" 172 "$tmp/build" "$image"
jq -e --arg revision "$revision" '
  .schema_version == 1 and .source_revision == $revision and .preview_number == 172 and
  (.source_digest | test("^[0-9a-f]{64}$")) and
  (.inventory_sha256 | test("^[0-9a-f]{64}$")) and
  (has("inventory_receipt_sha256") | not) and
  (.rendered_caddy_sha256 | test("^[0-9a-f]{64}$")) and
  (.backend_caddy_sha256 | test("^[0-9a-f]{64}$")) and
  (.image_id | test("^sha256:[0-9a-f]{64}$")) and
  (.status_renderer_image_id | test("^sha256:[0-9a-f]{64}$"))
' "$tmp/build/backend-build.json" >/dev/null

# The production Caddy image assigns CAP_NET_BIND_SERVICE to its binary.  A
# preview backend needs no privileged port, and no-new-privileges must remain
# effective, so prove the generated image starts under that policy.
docker run --rm --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 128 --memory 512m --cpus 1 \
  --entrypoint caddy "$image" version >/dev/null

# The compiled route must strip the browser-local status prefix before it
# reaches egress. Otherwise a valid node request becomes an accidental 404.
cat >"$tmp/egress.Caddyfile" <<'EOF'
{
  admin off
  auto_https off
}
:8080 {
  respond /preview/172/node/node4/chain-rpc/status "node status" 200
  respond "not found" 404
}
EOF
docker network create "$network" >/dev/null
docker run -d --rm --name "$egress" --network "$network" --network-alias gdc-preview-egress \
  -v "$tmp/egress.Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.11.4-alpine \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
docker run -d --rm --name "$backend" --network "$network" \
  -v "$tmp/backend.Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.11.4-alpine \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
for _ in $(seq 1 20); do
  response="$(docker exec "$backend" wget -qO- http://127.0.0.1:8080/status/node4/chain-rpc/status || true)"
  [[ "$response" == 'node status' ]] && break
  sleep 1
done
[[ "${response:-}" == 'node status' ]] || { echo 'compiled node route did not strip the status prefix' >&2; exit 1; }

printf 'PASS preview status renderer accepts a secret-free inventory fixture\n'
