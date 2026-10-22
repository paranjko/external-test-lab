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

export GDC_PREVIEW_NUMBER=172 GDC_NETWORK_CHAIN_API_ORIGIN=https://api.gonka-dev.net
# shellcheck disable=SC1091 # ROOT is resolved above.
source "$ROOT/../ops/preview/preview-curl.sh"
[[ "$(preview_curl_target https://gonka-dev.net/gonka-devnet-community/bootstrap.json)" == '/observer/bootstrap/gonka-devnet-community/bootstrap.json' ]]
[[ "$(preview_curl_target https://api.gonka-dev.net/chain-api/productscience/inference/inference/epoch_info)" == '/gonka-api/chain-api/productscience/inference/inference/epoch_info' ]]
[[ "$(preview_curl_target https://api.gonka-dev.net/chain-api/productscience/inference/inference/current_epoch_group_data)" == '/gonka-api/chain-api/productscience/inference/inference/current_epoch_group_data' ]]
[[ "$(preview_curl_target 'https://api.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/7?model_id=Qwen%2FQwen3-4B-Instruct-2507')" == '/gonka-api/chain-api/productscience/inference/inference/epoch_group_data/7?model_id=Qwen%2FQwen3-4B-Instruct-2507' ]]
[[ "$(preview_curl_target https://api.gonka-dev.net/chain-rpc/block?height=42)" == '/gonka-api/chain-rpc/block?height=42' ]]
[[ "$(preview_curl_target https://node4.gonka-dev.net/chain-rpc/status)" == '/preview/172/node/node4/chain-rpc/status' ]]
[[ "$(preview_curl_target https://node4.gonka-dev.net/chain-rpc/block?height=42)" == '/preview/172/node/node4/chain-rpc/block?height=42' ]]
[[ "$(preview_curl_target https://node4.gonka-dev.net/devshard/metrics)" == '/preview/172/node/node4/devshard/metrics' ]]
[[ "$(preview_curl_target https://node4.gonka-dev.net/chain-api/productscience/inference/inference/epoch_info)" == '/preview/172/node/node4/chain-api/productscience/inference/inference/epoch_info' ]]
for query in 'pagination.limit=100' 'pagination.limit=100&pagination.count_total=true'; do
  [[ "$(preview_curl_target "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/participant?$query")" == "/preview/172/node/node4/chain-api/productscience/inference/inference/participant?$query" ]]
done
[[ "$(preview_curl_target https://node4.gonka-dev.net/chain-rpc/validators?height=42\&page=1\&per_page=100)" == '/preview/172/node/node4/chain-rpc/validators?height=42&page=1&per_page=100' ]]
[[ "$(preview_curl_target https://node4.gonka-dev.net/chain-api/cosmos/base/tendermint/v1beta1/node_info)" == '/observer/node/node4/chain-api/cosmos/base/tendermint/v1beta1/node_info' ]]
[[ "$(preview_curl_target https://node4.gonka-dev.net/devshard/stats/shards)" == '/observer/node/node4/devshard/stats/shards' ]]
[[ "$(preview_curl_target https://ipwho.is/204.12.223.90)" == '/observer/geo/204.12.223.90' ]]
[[ "$(preview_curl_target https://ipwho.is/192.2.0.1)" == '/observer/geo/192.2.0.1' ]]
for url in \
  'https://example.org/' \
  'https://node4.gonka-dev.net:443/chain-rpc/status' \
  'https://node4.gonka-dev.net/chain-rpc/status?extra=1;curl=evil' \
  'https://node4.gonka-dev.net/chain-rpc/block?height=42&extra=1' \
  'https://node4.gonka-dev.net/devshard/metrics?extra=1' \
  'https://node4.gonka-dev.net/chain-api/productscience/inference/inference/participant?pagination.limit=101' \
  'https://node4.gonka-dev.net/devshard/stats/shards?extra=1' \
  'https://api.gonka-dev.net/chain-api/arbitrary/path' \
  'https://api.gonka-dev.net/chain-api/productscience/inference/inference/current_epoch_group_data?extra=1' \
  'https://api.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/7?model_id=' \
  'https://api.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/7?model_id=a&model_id=b' \
  'https://api.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/7?model_id=a&extra=1' \
  'https://api.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/7?model_id=%ZZ' \
  'https://api.gonka-dev.net/chain-rpc/block?height=42&extra=1' \
  'https://evil.example/chain-api/productscience/inference/inference/epoch_info' \
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
if GDC_NETWORK_CHAIN_API_ORIGIN=https://evil.example preview_curl_target https://api.gonka-dev.net/chain-api/productscience/inference/inference/epoch_info >/dev/null; then
  echo 'preview curl shim ignored the source-bound chain API origin' >&2
  exit 1
fi
if GDC_PREVIEW_NUMBER=invalid preview_curl_target https://node4.gonka-dev.net/chain-rpc/status >/dev/null; then
  echo 'preview curl shim accepted an invalid preview number' >&2
  exit 1
fi
if main -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 --output /tmp/out https://node4.gonka-dev.net/chain-rpc/status; then
  echo 'preview curl shim accepted unexpected curl options' >&2
  exit 1
fi
for header in 'Authorization: secret' 'x-cosmos-block-height: 0' 'x-cosmos-block-height: -1' $'x-cosmos-block-height: 42\r\nAuthorization: secret'; do
  if (main -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 -H "$header" https://api.gonka-dev.net/chain-api/productscience/inference/inference/current_epoch_group_data); then
    echo 'preview curl shim accepted an out-of-contract header' >&2
    exit 1
  fi
done
if (main -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 -H 'x-cosmos-block-height: 42' https://api.gonka-dev.net/chain-api/productscience/inference/inference/params); then
  echo 'preview curl shim accepted a height header outside model queries' >&2
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
if grep -q '^GDC_NETWORK_CHAIN_API_ORIGIN=' "$tmp/build/context/network-observer.env"; then
  echo 'preview depends on a separate central chain API' >&2
  exit 1
fi
grep -Fxq 'GDC_PREVIEW_NUMBER=172' "$tmp/build/context/network-observer.env"
jq -e --arg digest "$(sha256sum "$tmp/build/context/network-observer.env" | awk '{print $1}')" '.network_observer_env_sha256 == $digest' "$tmp/build/backend-build.json" >/dev/null
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
  handle_path /gonka-api/* {
    @model_current {
      path /chain-api/productscience/inference/inference/current_epoch_group_data
      header x-cosmos-block-height 42
    }
    handle @model_current {
      respond `{"epoch_group_data":{"epoch_index":"7","effective_block_height":"40","sub_group_models":["Qwen/Qwen3-4B-Instruct-2507"]}}` 200
    }
    @model_group {
      path /chain-api/productscience/inference/inference/epoch_group_data/7
      query model_id=Qwen/Qwen3-4B-Instruct-2507
      header x-cosmos-block-height 42
    }
    handle @model_group {
      respond `{"epoch_group_data":{"epoch_index":"7","model_id":"Qwen/Qwen3-4B-Instruct-2507","validation_weights":[{"member_address":"gonka1fixture","weight":"31"},{"member_address":"gonka1zero","weight":"0"}]}}` 200
    }
    respond "{http.request.uri}" 200
  }
  respond /preview/172/node/node4/chain-rpc/status "node status" 200
  handle_path /preview/172/node/node2/* {
    @pinned_model header x-cosmos-block-height 42
    handle @pinned_model {
      respond `{"height":"42"}` 200
    }
    respond /devshard/metrics "devshard_request_terminal_total 12" 200
  }
  respond "not found" 404
}
EOF
docker network create --internal "$network" >/dev/null
docker run -d --rm --name "$egress" --network "$network" --network-alias gdc-preview-egress \
  -v "$tmp/egress.Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2.11.4-alpine \
  caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
# Exercise the real source-bound curl wrapper through the existing trusted
# /gonka-api prefix-and-strip contract, without connecting to a public origin.
api_response="$(docker run --rm --network "$network" \
  -e GDC_NETWORK_CHAIN_API_ORIGIN=https://api.gonka-dev.net -e GDC_PREVIEW_NUMBER=172 \
  --entrypoint /usr/local/bin/curl "$image" \
  -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 \
  https://api.gonka-dev.net/chain-api/productscience/inference/inference/epoch_info)"
[[ "$api_response" == '/chain-api/productscience/inference/inference/epoch_info' ]] || {
  printf 'trusted /gonka-api fixture returned unexpected path: %s\n' "$api_response" >&2
  exit 1
}
# Run the actual collector function through the shipped curl shim and Caddy
# egress, so mocks cannot hide a missing endpoint, query or height header.
model_response="$(docker run --rm --network "$network" \
  -e GDC_NETWORK_CHAIN_API_ORIGIN=https://api.gonka-dev.net -e GDC_PREVIEW_NUMBER=172 \
  --entrypoint /bin/bash "$image" -c '
    source <(sed -n "/^collect_model_assignments() {/,/^}/p" /usr/local/lib/gonka-devnet/network-observer.sh)
    collect_model_assignments https://api.gonka-dev.net/chain-api/productscience/inference/inference 42
  ')"
jq -e '.state == "observed" and .reference_height == 42 and .epoch_index == "7" and
  .groups == [{model_id:"Qwen/Qwen3-4B-Instruct-2507",state:"observed",participants:[{address:"gonka1fixture",weight:"31"}]}]' <<<"$model_response" >/dev/null || {
  printf 'unexpected preview model collection: %s\n' "$model_response" >&2
  exit 1
}
printf 'PASS effective model collector crosses preview transport with pinned height and encoded model ID\n'
node_response="$(docker run --rm --network "$network" -e GDC_PREVIEW_NUMBER=172 \
  --entrypoint /usr/local/bin/curl "$image" \
  -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 \
  -H 'x-cosmos-block-height: 42' \
  'https://node2.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/7?model_id=Qwen%2FQwen3-4B-Instruct-2507')"
jq -e '.height == "42"' <<<"$node_response" >/dev/null
traffic_response="$(docker run --rm --network "$network" -e GDC_PREVIEW_NUMBER=172 \
  --entrypoint /usr/local/bin/curl "$image" \
  -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 \
  https://node2.gonka-dev.net/devshard/metrics)"
[[ "$traffic_response" == 'devshard_request_terminal_total 12' ]]
printf 'PASS participant model and traffic requests cross preview transport without a central API\n'
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
