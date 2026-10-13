#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$ROOT/.data/preview-status-renderer-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

inventory="$tmp/inventory.env"
install -m 0600 "$ROOT/../ops/preview/status-renderer-inventory.env" "$inventory"
mkdir -m 0700 "$tmp/bin"
cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SSH_MOCK_LOG"
exit 90
SH
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_MOCK_LOG"
exit 90
SH
cat >"$tmp/bin/getent" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GETENT_MOCK_LOG"
exit 2
SH
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/curl" "$tmp/bin/getent"
export SSH_MOCK_LOG="$tmp/ssh.log" CURL_MOCK_LOG="$tmp/curl.log" GETENT_MOCK_LOG="$tmp/getent.log"
env -i HOME="$tmp" PATH="$tmp/bin:$PATH" SSH_MOCK_LOG="$SSH_MOCK_LOG" CURL_MOCK_LOG="$CURL_MOCK_LOG" GETENT_MOCK_LOG="$GETENT_MOCK_LOG" \
  bash "$ROOT/04-ops/render-ops.sh" --inventory "$inventory" --output-dir "$tmp/output"
[[ ! -s "$SSH_MOCK_LOG" && ! -s "$CURL_MOCK_LOG" ]] || {
  echo 'preview renderer attempted an SSH or external HTTP request outside its fixture contract' >&2
  exit 1
}

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
grep -Fq 'handle @network_observer {' "$tmp/backend.Caddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:18094' "$tmp/backend.Caddyfile"
grep -Fq 'handle @network_observer_ws {' "$tmp/backend.Caddyfile"
grep -Fq 'preview_gateway_status_unavailable' "$tmp/backend.Caddyfile"
grep -Fq 'path_regexp node_node4 ^/status/node4(/.*)$' "$tmp/backend.Caddyfile"
grep -Fq 'rewrite * /preview/172/node/node4{re.node_node4.1}' "$tmp/backend.Caddyfile"
grep -Fq 'path /status/network/ws' "$tmp/backend.Caddyfile"
docker run --rm -v "$tmp/backend.Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2.11.4-alpine caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

sed 's/gdc_component_info/unsafe_metric/' "$tmp/output/Caddyfile" >"$tmp/unsafe.Caddyfile"
if "$ROOT/../ops/preview/render-status-backend.sh" "$tmp/unsafe.Caddyfile" "$tmp/output/config.js" 172 "$tmp/unsafe-output.Caddyfile"; then
  echo 'status backend compiler accepted an unapproved query' >&2
  exit 1
fi

source "$ROOT/../ops/preview/preview-curl.sh"
[[ "$(preview_curl_target https://gonka-dev.net/chain-1/bootstrap.json)" == '/observer/bootstrap/chain-1/bootstrap.json' ]]
[[ "$(preview_curl_target https://node4.gonka-dev.net/chain-api/cosmos/base/tendermint/v1beta1/node_info)" == '/observer/node/node4/chain-api/cosmos/base/tendermint/v1beta1/node_info' ]]
[[ "$(preview_curl_target https://node4.gonka-dev.net/chain-rpc/validators?height=42\&page=1\&per_page=100)" == '/observer/node/node4/chain-rpc/validators?height=42&page=1&per_page=100' ]]
[[ "$(preview_curl_target https://ipwho.is/204.12.223.90)" == '/observer/geo/204.12.223.90' ]]
[[ "$(preview_curl_target https://ipwho.is/192.2.0.1)" == '/observer/geo/192.2.0.1' ]]
for url in \
  'https://example.org/' \
  'https://node4.gonka-dev.net:443/chain-rpc/status' \
  'https://node4.gonka-dev.net/chain-rpc/status?extra=1;curl=evil' \
  'http://127.0.0.1/chain-rpc/status' \
  'https://ipwho.is/127.0.0.1' \
  'https://ipwho.is/100.64.0.1' \
  'https://ipwho.is/192.0.2.1' \
  'https://ipwho.is/256.2.3.4' \
  'https://gonka-dev.net/chain-1/bootstrap.json?x=1'; do
  if preview_curl_target "$url" >/dev/null; then
    echo "preview curl shim accepted an out-of-contract URL: $url" >&2
    exit 1
  fi
done
if main -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 --output /tmp/out https://node4.gonka-dev.net/chain-rpc/status; then
  echo 'preview curl shim accepted unexpected curl options' >&2
  exit 1
fi

repository="$(cd "$ROOT/.." && pwd)"
index="$tmp/source.index"
GIT_INDEX_FILE="$index" git -C "$repository" read-tree HEAD
GIT_INDEX_FILE="$index" git -C "$repository" add -u
while IFS= read -r -d '' file; do
  case "$file" in
    net-deployment-runbook/04-ops/*|net-deployment-runbook/scripts/*|ops/preview/*)
      [[ "$file" == */.data/* ]] && continue
      GIT_INDEX_FILE="$index" git -C "$repository" add -- "$file"
      ;;
  esac
done < <(git -C "$repository" ls-files --others --exclude-standard -z -- net-deployment-runbook/04-ops net-deployment-runbook/scripts ops/preview)
revision="$(GIT_INDEX_FILE="$index" git -C "$repository" write-tree)"
image="gdc-preview-status-renderer-test:${revision:0:12}"
network="gdc-preview-status-renderer-$$-$RANDOM"
egress="gdc-preview-status-egress-$$"
proxy="gdc-preview-status-proxy-$$"
backend="gdc-preview-status-backend-$$"
port=$((20000 + ($$ % 20000)))
cleanup() {
  docker rm -f "$backend" "$egress" "$proxy" >/dev/null 2>&1 || true
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
  (.network_observer_http_sha256 | test("^[0-9a-f]{64}$")) and
  (.network_observer_collector_sha256 | test("^[0-9a-f]{64}$")) and
  (.network_observer_env_sha256 | test("^[0-9a-f]{64}$")) and
  (.preview_curl_sha256 | test("^[0-9a-f]{64}$")) and
  (.network_observer_runtime_sha256 | test("^[0-9a-f]{64}$")) and
  (.start_status_backend_sha256 | test("^[0-9a-f]{64}$")) and
  (.image_id | test("^sha256:[0-9a-f]{64}$")) and
  (.status_renderer_image_id | test("^sha256:[0-9a-f]{64}$"))
' "$tmp/build/backend-build.json" >/dev/null

# The production Caddy image assigns CAP_NET_BIND_SERVICE to its binary.  A
# preview backend needs no privileged port, and no-new-privileges must remain
# effective, so prove the generated image starts under that policy.
docker run --rm --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 128 --memory 512m --cpus 1 \
  --entrypoint /usr/bin/caddy "$image" version >/dev/null

# The compiled route must strip the browser-local status prefix before it
# reaches egress. Otherwise a valid node request becomes an accidental 404.
cat >"$tmp/egress.Caddyfile" <<'EOF'
{
  admin off
  auto_https off
}
:8080 {
	respond /network "network status" 200
  respond /preview/172/node/node4/chain-rpc/status "node status" 200
  respond "not found" 404
}
EOF
docker network create --internal "$network" >/dev/null
docker run -d --rm --name "$egress" --network "$network" --network-alias gdc-preview-egress \
  -v "$tmp/egress.Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.11.4-alpine \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
cat >"$tmp/preview-proxy.Caddyfile" <<EOF
{
  admin off
  auto_https off
}
:8080 {
  handle_path /172/* {
    reverse_proxy $backend:8080
  }
  respond "not found" 404
}
EOF
docker run -d --rm --name "$proxy" --network bridge -p "127.0.0.1:$port:8080" \
  -v "$tmp/preview-proxy.Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.11.4-alpine \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
docker network connect "$network" "$proxy"
cat >"$tmp/fixture-collector.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  --refresh-requested) exit 0 ;;
  --serve)
    body='{"schema_version":1,"chain_id":"preview-test-chain","observed_at":"2026-01-01T00:00:00Z","nodes":[],"chain":{"state":"unavailable"}}'
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: %s\r\n\r\n%s' "${#body}" "$body"
    ;;
  *) exit 91 ;;
esac
EOF
chmod 0755 "$tmp/fixture-collector.sh"
docker run -d --rm --name "$backend" --network "$network" \
  -v "$tmp/fixture-collector.sh:/tmp/fixture-collector.sh:ro" \
  --env GDC_NETWORK_OBSERVER_COLLECTOR=/tmp/fixture-collector.sh \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 128 --memory 512m --cpus 1 "$image" >/dev/null
for _ in $(seq 1 20); do
  response="$(curl --silent --show-error --max-time 2 "http://127.0.0.1:$port/172/status/node4/chain-rpc/status" || true)"
  [[ "$response" == 'node status' ]] && break
  sleep 1
done
[[ "${response:-}" == 'node status' ]] || {
  docker inspect "$backend" --format 'backend state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} ports={{json .NetworkSettings.Ports}}' >&2 || true
  docker logs "$backend" >&2 || true
  echo 'compiled node route did not strip the status prefix' >&2
  exit 1
}
network_response="$(curl --silent --show-error --max-time 5 "http://127.0.0.1:$port/172/status/network")"
jq -e '.chain_id == "preview-test-chain" and .nodes == [] and .chain.state == "unavailable"' <<<"$network_response" >/dev/null || {
  printf 'unexpected network observer response: %s\n' "$network_response" >&2
  docker logs "$backend" >&2 || true
  exit 1
}
node --input-type=module -e '
  const socket = new WebSocket(process.argv[1]);
  const timeout = setTimeout(() => { socket.close(); process.exit(2); }, 5000);
  socket.addEventListener("message", (event) => {
    clearTimeout(timeout);
    const payload = JSON.parse(event.data);
    if (payload.type !== "network_snapshot" || payload.snapshot.chain_id !== "preview-test-chain") process.exit(3);
    socket.close();
  }, { once: true });
  socket.addEventListener("error", () => process.exit(4), { once: true });
' "ws://127.0.0.1:$port/172/status/network/ws"
for _ in $(seq 1 30); do
  backend_health="$(docker inspect "$backend" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)"
  [[ "$backend_health" == healthy ]] && break
  [[ "$backend_health" == starting ]] || break
  sleep 1
done
docker inspect "$backend" | jq -e '.[0].State.Health.Status == "healthy" and (.[0].NetworkSettings.Networks | keys | length) == 1' >/dev/null || {
  docker inspect "$backend" --format '{{json .State}}' >&2 || true
  docker logs "$backend" >&2 || true
  echo 'preview observer backend did not become healthy on its isolated network' >&2
  exit 1
}
docker network inspect "$network" | jq -e '.[0].Internal == true' >/dev/null

printf 'PASS preview status renderer accepts a secret-free inventory fixture\n'
