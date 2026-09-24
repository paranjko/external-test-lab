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
cat >"$test_root/backend.Dockerfile" <<'EOF'
FROM busybox:1.36.1
COPY backend-www /srv
HEALTHCHECK --interval=1s --timeout=1s --retries=10 CMD wget -q -O /dev/null http://127.0.0.1:8080/status/test || exit 1
CMD ["httpd", "-f", "-p", "8080", "-h", "/srv"]
EOF
build_backend() {
  local revision="$1" tag="gdc-preview-lifecycle-$1-$$"
  docker build -q --label "gdc.preview.source-revision=$revision" --label gdc.preview.managed=true \
    -t "$tag" -f "$test_root/backend.Dockerfile" "$test_root" >"$test_root/backend-$revision.image"
  docker image inspect --format '{{.Id}}' "$tag"
}
backend_image="$(build_backend "$revision_backend")"
combined_backend_image="$(build_backend "$revision_combined")"
backend_digest=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
combined_backend_digest=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

prepare_artifact() {
  local artifact="$1" pr="$2" revision="$3" mode="$4" frontend="$5" backend="${6:-}" image="${7:-}" config_digest adapter_digest backend_revision
  printf 'window.GDC_CONFIG = {"chainId":"fixture","nodes":[]};\n' >"$artifact/config.js"
  printf 'window.fetch = window.fetch.bind(window);\n' >"$artifact/preview-status-adapter.js"
  config_digest="$(sha256sum "$artifact/config.js" | awk '{print $1}')"
  adapter_digest="$(sha256sum "$artifact/preview-status-adapter.js" | awk '{print $1}')"
  printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision"'","preview_number":'"$pr"',"renderer_config_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","config_sha256":"'"$config_digest"'","status_adapter_sha256":"'"$adapter_digest"'"}' >"$artifact/preview-runtime-config.json"
  printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision"'","source_archive_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","builder_image_id":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"$artifact/frontend-build.json"
  backend_revision=null
  [[ "$mode" == static ]] || backend_revision="$revision"
  jq -n --arg revision "$revision" --arg mode "$mode" --arg frontend "$frontend" --arg config "$config_digest" --arg backend "$backend" --arg image "$image" --arg backend_revision "$backend_revision" \
    '{schema_version:1,head_revision:$revision,mode:$mode,frontend_revision:$revision,backend_revision:(if $backend_revision == "null" then null else $backend_revision end),frontend_digest:$frontend,runtime_config_sha256:$config,backend_digest:(if $backend == "" then null else $backend end),backend_image_id:(if $image == "" then null else $image end)}' \
    >"$artifact/preview-composition.json"
}

prepare_artifact "$artifact_one" 172 "$revision_one" static aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
prepare_artifact "$artifact_two" 172 "$revision_two" static bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
prepare_artifact "$artifact_backend" 173 "$revision_backend" backend cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc "$backend_digest" "$backend_image"
prepare_artifact "$artifact_combined" 174 "$revision_combined" combined eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee "$combined_backend_digest" "$combined_backend_image"
printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision_backend"'","preview_number":173,"source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rendered_caddy_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","backend_caddy_sha256":"'"$backend_digest"'","image_id":"'"$backend_image"'"}' >"$artifact_backend/backend-build.json"
printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision_combined"'","preview_number":174,"source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rendered_caddy_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","backend_caddy_sha256":"'"$combined_backend_digest"'","image_id":"'"$combined_backend_image"'"}' >"$artifact_combined/backend-build.json"

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
for receipt in preview-composition.json backend-build.json preview-runtime-config.json; do
  status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/174/$receipt")"
  [[ "$status" == 404 ]] || { echo "preview receipt unexpectedly served: $receipt status=$status" >&2; exit 1; }
done

run_controller remove 172
if curl --fail --silent --show-error "http://127.0.0.1:$port/172/" >/dev/null 2>&1; then
  echo 'removed preview route still responds successfully' >&2
  exit 1
fi
[[ ! -e "$test_root/runtime/releases/172" && ! -e "$test_root/runtime/staging/172" ]] \
  || { echo 'removed preview retained release or staging state' >&2; exit 1; }
run_controller deploy 172 "$revision_two" "$artifact_two"
curl --fail --silent --show-error "http://127.0.0.1:$port/172/" | grep -Fq two
run_controller remove 172
run_controller remove 173
run_controller remove 174
for network in gdc-preview-pr-172 gdc-preview-pr-173 gdc-preview-pr-174; do
  if docker network inspect "$network" >/dev/null 2>&1; then
    echo "preview network was retained after cleanup: $network" >&2
    exit 1
  fi
done

printf 'PASS preview lifecycle root=%s\n' "$test_root"
