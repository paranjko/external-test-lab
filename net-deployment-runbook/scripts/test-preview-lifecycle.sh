#!/usr/bin/env bash
set -Eeuo pipefail

runbook="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository="$(cd "$runbook/.." && pwd)"
controller="$repository/ops/preview/previewctl.sh"
test_root="$runbook/.data/preview-lifecycle/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
artifact_one="$test_root/artifact-one"
artifact_two="$test_root/artifact-two"
artifact_backend="$test_root/artifact-backend"
artifact_combined="$test_root/artifact-combined"
revision_one=1111111111111111111111111111111111111111
revision_two=2222222222222222222222222222222222222222
revision_backend=3333333333333333333333333333333333333333
revision_combined=4444444444444444444444444444444444444444
port=$((19000 + ($$ % 1000)))
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/gdc-preview-lifecycle-$$"

mkdir -p "$artifact_one" "$artifact_two" "$artifact_backend" "$artifact_combined"
printf '<!doctype html><title>preview one</title>one\n' >"$artifact_one/index.html"
printf '<!doctype html><title>preview two</title>two\n' >"$artifact_two/index.html"
printf '<!doctype html><title>backend preview</title>backend\n' >"$artifact_backend/index.html"
printf '<!doctype html><title>combined preview</title>combined\n' >"$artifact_combined/index.html"
mkdir -p "$test_root/backend-www/status"
printf 'backend\n' >"$test_root/backend-www/status/test"
cat >"$test_root/backend-caddyfile" <<'EOF'
:8080 {
  handle /health {
    respond "ready"
  }
  handle /status/test {
    respond "backend"
  }
  respond "not found" 404
}
EOF
mkdir -p "$test_root/payload/usr/local/lib/gonka-devnet" "$test_root/payload/etc/gonka" \
  "$test_root/payload/usr/local/bin" "$test_root/payload/opt/gdc-preview"
install -m 0644 "$repository/net-deployment-runbook/04-ops/network-observer-http.py" \
  "$test_root/payload/usr/local/lib/gonka-devnet/network-observer-http.py"
install -m 0644 "$repository/net-deployment-runbook/04-ops/network-observer.sh" \
  "$test_root/payload/usr/local/lib/gonka-devnet/network-observer.sh"
install -m 0644 "$repository/ops/preview/status-renderer-inventory.env" \
  "$test_root/payload/etc/gonka/gdc-network-observer.env"
install -m 0755 "$repository/ops/preview/preview-curl.sh" "$test_root/payload/usr/local/bin/curl"
install -m 0755 "$repository/ops/preview/network-observer-runtime.py" \
  "$test_root/payload/opt/gdc-preview/network-observer-runtime.py"
cat >"$test_root/payload/opt/gdc-preview/start-status-backend.sh" <<'EOF'
#!/bin/sh
exec /usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
EOF
chmod 0755 "$test_root/payload/opt/gdc-preview/start-status-backend.sh"
cat >"$test_root/backend.Dockerfile" <<'EOF'
FROM caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
RUN setcap -r /usr/bin/caddy
COPY backend-caddyfile /etc/caddy/Caddyfile
COPY payload/usr/local/lib/gonka-devnet/network-observer-http.py /usr/local/lib/gonka-devnet/network-observer-http.py
COPY payload/usr/local/lib/gonka-devnet/network-observer.sh /usr/local/lib/gonka-devnet/network-observer.sh
COPY payload/etc/gonka/gdc-network-observer.env /etc/gonka/gdc-network-observer.env
COPY payload/usr/local/bin/curl /usr/local/bin/curl
COPY payload/opt/gdc-preview/network-observer-runtime.py /opt/gdc-preview/network-observer-runtime.py
COPY payload/opt/gdc-preview/start-status-backend.sh /opt/gdc-preview/start-status-backend.sh
RUN chmod 0755 /usr/local/lib/gonka-devnet/network-observer.sh /usr/local/bin/curl /opt/gdc-preview/start-status-backend.sh
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["/bin/sh", "-c", "/usr/bin/curl -fsS http://127.0.0.1:8080/health | grep -Fxq ready"]
CMD ["/opt/gdc-preview/start-status-backend.sh"]
EOF
build_backend() {
  local revision="$1" tag="gdc-preview-lifecycle-$1-$$"
  docker build -q --label "gdc.preview.source-revision=$revision" --label gdc.preview.managed=true \
    -t "$tag" -f "$test_root/backend.Dockerfile" "$test_root" >"$test_root/backend-$revision.image"
  docker image inspect --format '{{.Id}}' "$tag"
}
backend_image="$(build_backend "$revision_backend")"
combined_backend_image="$(build_backend "$revision_combined")"
backend_digest="$(sha256sum "$test_root/backend-caddyfile" | awk '{print $1}')"
combined_backend_digest="$backend_digest"
payload_digest() {
  sha256sum "$test_root/payload/$1" | awk '{print $1}'
}

prepare_artifact() {
  local artifact="$1" pr="$2" revision="$3" mode="$4" frontend="$5" backend="${6:-}" image="${7:-}" config_digest adapter_digest backend_revision archive_digest=''
  printf 'window.GDC_CONFIG = {"chainId":"fixture","nodes":[]};\n' >"$artifact/config.js"
  printf 'window.fetch = window.fetch.bind(window);\n' >"$artifact/preview-status-adapter.js"
  config_digest="$(sha256sum "$artifact/config.js" | awk '{print $1}')"
  adapter_digest="$(sha256sum "$artifact/preview-status-adapter.js" | awk '{print $1}')"
  printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision"'","preview_number":'"$pr"',"renderer_config_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","config_sha256":"'"$config_digest"'","status_adapter_sha256":"'"$adapter_digest"'"}' >"$artifact/preview-runtime-config.json"
  printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision"'","source_archive_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","builder_image_id":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"$artifact/frontend-build.json"
  backend_revision=null
  if [[ "$mode" != static ]]; then
    backend_revision="$revision"
    docker image save "$image" -o "$artifact/backend-image.tar"
    archive_digest="$(sha256sum "$artifact/backend-image.tar" | awk '{print $1}')"
    printf '%s\n' "$archive_digest" >"$artifact/backend-image.tar.sha256"
  fi
  local backend_build_digest=''
  if [[ "$mode" != static ]]; then
    backend_build_digest="$(sha256sum "$artifact/backend-build.json" | awk '{print $1}')"
  fi
  jq -n --arg revision "$revision" --arg mode "$mode" --arg frontend "$frontend" --arg config "$config_digest" --arg backend "$backend" --arg image "$image" --arg backend_revision "$backend_revision" --arg archive "$archive_digest" --arg backend_build "$backend_build_digest" \
    '{schema_version:1,head_revision:$revision,mode:$mode,frontend_revision:$revision,backend_revision:(if $backend_revision == "null" then null else $backend_revision end),frontend_digest:$frontend,runtime_config_sha256:$config,backend_digest:(if $backend == "" then null else $backend end),backend_image_id:(if $image == "" then null else $image end),backend_archive_sha256:(if $archive == "" then null else $archive end),backend_build_manifest_sha256:(if $backend_build == "" then null else $backend_build end)}' \
    >"$artifact/preview-composition.json"
}

prepare_artifact "$artifact_one" 172 "$revision_one" static aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
prepare_artifact "$artifact_two" 172 "$revision_two" static bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
write_backend_manifest() {
  local artifact="$1" revision="$2" preview="$3" image="$4"
  jq -n --arg revision "$revision" --argjson preview "$preview" --arg caddy "$backend_digest" \
    --arg observer "$(payload_digest usr/local/lib/gonka-devnet/network-observer-http.py)" \
    --arg collector "$(payload_digest usr/local/lib/gonka-devnet/network-observer.sh)" \
    --arg env "$(payload_digest etc/gonka/gdc-network-observer.env)" \
    --arg curl "$(payload_digest usr/local/bin/curl)" \
    --arg runtime "$(payload_digest opt/gdc-preview/network-observer-runtime.py)" \
    --arg launcher "$(payload_digest opt/gdc-preview/start-status-backend.sh)" \
    --arg image "$image" \
    '{schema_version:1,source_revision:$revision,preview_number:$preview,source_digest:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",rendered_caddy_sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",backend_caddy_sha256:$caddy,network_observer_http_sha256:$observer,network_observer_collector_sha256:$collector,network_observer_env_sha256:$env,preview_curl_sha256:$curl,network_observer_runtime_sha256:$runtime,start_status_backend_sha256:$launcher,image_id:$image,status_renderer_image_id:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}' \
    >"$artifact/backend-build.json"
}
write_backend_manifest "$artifact_backend" "$revision_backend" 173 "$backend_image"
write_backend_manifest "$artifact_combined" "$revision_combined" 174 "$combined_backend_image"
prepare_artifact "$artifact_backend" 173 "$revision_backend" backend cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc "$backend_digest" "$backend_image"
prepare_artifact "$artifact_combined" 174 "$revision_combined" combined eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee "$combined_backend_digest" "$combined_backend_image"

run_controller() {
  PREVIEW_TEST_MODE=1 PREVIEW_USER="$(id -un)" \
    PREVIEW_ROOT="$test_root/runtime" PREVIEW_RUNTIME_DIR="$runtime_dir" PREVIEW_CADDY_PORT="$port" \
    PREVIEW_CONTAINER_UID="$(id -u)" PREVIEW_CONTAINER_GID="$(id -g)" \
    PREVIEW_DOCKER_HOST="unix:///var/run/docker.sock" \
    "$controller" "$@"
}

cleanup() {
  PREVIEW_ROOT="$test_root/runtime" PREVIEW_RUNTIME_DIR="$runtime_dir" PREVIEW_CADDY_PORT="$port" \
    PREVIEW_CONTAINER_UID="$(id -u)" PREVIEW_CONTAINER_GID="$(id -g)" \
    PREVIEW_PROMETHEUS_ORIGIN=http://127.0.0.1:9099 \
    docker compose --project-directory "$test_root/runtime/control" \
    -f "$test_root/runtime/control/compose.yaml" down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "gdc-preview-pr-172-${revision_one:0:12}" \
    "gdc-preview-pr-172-${revision_two:0:12}" \
    "gdc-preview-pr-173-${revision_backend:0:12}" \
    "gdc-preview-pr-174-${revision_combined:0:12}" >/dev/null 2>&1 || true
  docker network rm gdc-preview-pr-172 gdc-preview-pr-173 gdc-preview-pr-174 >/dev/null 2>&1 || true
  docker image rm "gdc-preview-lifecycle-$revision_backend-$$" "gdc-preview-lifecycle-$revision_combined-$$" >/dev/null 2>&1 || true
  rmdir -- "$runtime_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_controller install
run_controller configure-observer http://127.0.0.1:9099
run_controller start
curl --fail --silent --show-error "http://127.0.0.1:$port/health" | grep -Fxq ready

# A second publish for the same PR must fail before it can replace the active
# generation while the first lifecycle action owns its lock.
lock_file="$test_root/runtime/control/locks/pr-172.lock"
flock "$lock_file" sleep 2 &
locker_pid=$!
sleep 0.1
if run_controller deploy 172 "$revision_one" "$artifact_one"; then
  echo 'concurrent preview deployment unexpectedly acquired the PR lock' >&2
  exit 1
fi
wait "$locker_pid"

run_controller deploy 172 "$revision_one" "$artifact_one"
status_one="$(curl --silent --show-error -D "$test_root/headers-one" -o "$test_root/body-one" -w '%{http_code}' "http://127.0.0.1:$port/172/")"
if [[ "$status_one" != 200 ]]; then
  cat "$test_root/headers-one" >&2
  cat "$test_root/body-one" >&2
  echo "preview one returned HTTP $status_one" >&2
  exit 1
fi
grep -Fq one "$test_root/body-one"
grep -Eqi '^Content-Security-Policy: worker-src '\''none'\''' "$test_root/headers-one"
run_controller status 172 | jq -e --arg revision "$revision_one" '.revision == $revision and .mode == "static"' >/dev/null
static_status="$(curl --silent --show-error -o "$test_root/static-status.json" -w '%{http_code}' "http://127.0.0.1:$port/172/status/gpus")"
[[ "$static_status" == 503 ]] || { echo "static preview status returned HTTP $static_status" >&2; exit 1; }
jq -e '.error == "preview_status_unavailable"' "$test_root/static-status.json" >/dev/null

run_controller deploy 172 "$revision_two" "$artifact_two"
curl --fail --silent --show-error "http://127.0.0.1:$port/172/" | grep -Fq two
run_controller status 172 | jq -e --arg revision "$revision_two" '.revision == $revision and .mode == "static"' >/dev/null

run_controller deploy 173 "$revision_backend" "$artifact_backend" "$backend_image"
curl --fail --silent --show-error "http://127.0.0.1:$port/173/status/test" | grep -Fxq backend
run_controller status 173 | jq -e --arg revision "$revision_backend" '.revision == $revision and .mode == "backend"' >/dev/null

run_controller deploy 174 "$revision_combined" "$artifact_combined" "$combined_backend_image"
curl --fail --silent --show-error "http://127.0.0.1:$port/174/" | grep -Fq combined
curl --fail --silent --show-error "http://127.0.0.1:$port/174/status/test" | grep -Fxq backend
run_controller status 174 | jq -e --arg revision "$revision_combined" '.revision == $revision and .mode == "combined"' >/dev/null
# Exercise a shared-service replacement while two independent previews exist.
docker rm -f gdc-preview-node-guard >/dev/null
if ! run_controller start; then
  for container in gdc-preview-caddy gdc-preview-egress gdc-preview-node-guard \
    "gdc-preview-pr-173-${revision_backend:0:12}" "gdc-preview-pr-174-${revision_combined:0:12}"; do
    docker inspect "$container" --format '{{.Id}} {{.Name}} state={{.State.Status}} running={{.State.Running}} restart={{.RestartCount}} sandbox={{.NetworkSettings.SandboxID}} networks={{json .NetworkSettings.Networks}}' >&2 || true
    docker logs "$container" >&2 || true
  done
  exit 1
fi
for network in gdc-preview-pr-173 gdc-preview-pr-174; do
  docker inspect gdc-preview-node-guard | jq -e --arg network "$network" '.[0].NetworkSettings.Networks | has($network)' >/dev/null
done
curl --fail --silent --show-error "http://127.0.0.1:$port/173/status/test" | grep -Fxq backend
curl --fail --silent --show-error "http://127.0.0.1:$port/174/status/test" | grep -Fxq backend
for receipt in preview-composition.json backend-build.json preview-runtime-config.json; do
  status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/174/$receipt")"
  [[ "$status" == 404 ]] || { echo "preview receipt unexpectedly served: $receipt status=$status" >&2; exit 1; }
done

shared_before="$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' gdc-preview-caddy gdc-preview-egress gdc-preview-node-guard)"
combined_before="$(docker inspect --format '{{.Id}} {{.State.StartedAt}}' "gdc-preview-pr-174-${revision_combined:0:12}")"
run_controller remove 172
run_controller remove 172 # Repeated removal is safe
run_controller remove 999 # A closed PR that never had a preview is safe
status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/172/")"
[[ "$status" == 404 ]] || { echo "removed preview returned HTTP $status" >&2; exit 1; }
[[ ! -e "$test_root/runtime/releases/172" && ! -e "$test_root/runtime/staging/172" ]] \
  || { echo 'removed preview retained release or staging state' >&2; exit 1; }
run_controller deploy 172 "$revision_two" "$artifact_two"
curl --fail --silent --show-error "http://127.0.0.1:$port/172/" | grep -Fq two
run_controller remove 172
# Reproduce interruption after deleting the registry: retry must still remove
# the labelled backend, release and network without relying on that entry.
rm "$test_root/runtime/control/registry/173.json"
run_controller remove 173
run_controller remove 173
if docker inspect "gdc-preview-pr-173-${revision_backend:0:12}" >/dev/null 2>&1; then
  echo 'interrupted cleanup retained its backend' >&2; exit 1
fi
curl --fail --silent --show-error "http://127.0.0.1:$port/174/" | grep -Fq combined
curl --fail --silent --show-error "http://127.0.0.1:$port/174/status/test" | grep -Fxq backend
[[ "$combined_before" == "$(docker inspect --format '{{.Id}} {{.State.StartedAt}}' "gdc-preview-pr-174-${revision_combined:0:12}")" ]]
[[ "$shared_before" == "$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' gdc-preview-caddy gdc-preview-egress gdc-preview-node-guard)" ]]
run_controller remove 174
for network in gdc-preview-pr-172 gdc-preview-pr-173 gdc-preview-pr-174; do
  if docker network inspect "$network" >/dev/null 2>&1; then
    echo "preview network was retained after cleanup: $network" >&2
    exit 1
  fi
done

printf 'PASS preview lifecycle root=%s\n' "$test_root"
