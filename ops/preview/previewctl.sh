#!/usr/bin/env bash
set -Eeuo pipefail

# This is the only program allowed to mutate the preview runtime. It runs as
# the preview account. PR containers receive neither its Docker socket nor the
# Caddy Admin socket.

PREVIEW_ROOT="${PREVIEW_ROOT:-/srv/preview}"
PREVIEW_USER="${PREVIEW_USER:-preview}"
PREVIEW_CADDY_PORT="${PREVIEW_CADDY_PORT:-18090}"
CONTROL="$PREVIEW_ROOT/control"
REGISTRY="$CONTROL/registry"
RELEASES="$PREVIEW_ROOT/releases"
RUNTIME="${PREVIEW_RUNTIME_DIR:-$CONTROL/runtime}"
COMPOSE_FILE="$CONTROL/compose.yaml"
BASE_CADDYFILE="$CONTROL/Caddyfile"
ACTIVE_CADDYFILE="$CONTROL/Caddyfile.active"
EGRESS_CADDYFILE="$CONTROL/egress.Caddyfile"
NODE_GUARD_IMAGE="${PREVIEW_NODE_GUARD_IMAGE:-gdc-preview-node-observation-guard:local}"
RUNTIME_ENV="$CONTROL/runtime.env"
LOCKS="$CONTROL/locks"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

if [[ -n "${PREVIEW_RUNTIME_DIR:-}" && "${PREVIEW_TEST_MODE:-}" != 1 ]]; then
  die 'PREVIEW_RUNTIME_DIR is permitted only for the local lifecycle test'
fi

require_preview_user() {
  [[ "$(id -un)" == "$PREVIEW_USER" ]] || die "run as $PREVIEW_USER"
  if [[ -n "${PREVIEW_DOCKER_HOST:-}" ]]; then
    [[ "${PREVIEW_TEST_MODE:-}" == 1 ]] \
      || die 'PREVIEW_DOCKER_HOST is permitted only for the local lifecycle test'
    export DOCKER_HOST="$PREVIEW_DOCKER_HOST"
    return 0
  fi
  [[ -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/docker.sock" ]] \
    || die 'rootless Docker socket is unavailable; run user-preview.sh verify'
  export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"
}

require_layout() {
  for path in "$PREVIEW_ROOT" "$CONTROL" "$REGISTRY" "$RELEASES" "$RUNTIME" "$LOCKS"; do
    [[ -d "$path" && ! -L "$path" ]] || die "unsafe or missing preview path: $path"
  done
  command -v docker >/dev/null || die 'Docker CLI is unavailable'
  command -v curl >/dev/null || die 'curl is unavailable'
  command -v jq >/dev/null || die 'jq is unavailable'
}

valid_pr() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

valid_revision() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

registry_file() {
  printf '%s/%s.json\n' "$REGISTRY" "$1"
}

network_name() {
  printf 'gdc-preview-pr-%s\n' "$1"
}

backend_name() {
  printf 'gdc-preview-pr-%s-%s\n' "$1" "${2:0:12}"
}

install_assets() {
  install -d -m 0750 "$PREVIEW_ROOT" "$RELEASES" "$CONTROL"
  install -d -m 0700 "$REGISTRY" "$RUNTIME" "$LOCKS" "$CONTROL/staging" "$CONTROL/caddy-data" "$CONTROL/caddy-config"
  install -m 0644 "$SELF_DIR/compose.yaml" "$COMPOSE_FILE"
  install -m 0644 "$SELF_DIR/Caddyfile" "$BASE_CADDYFILE"
  [[ -f "$ACTIVE_CADDYFILE" && ! -L "$ACTIVE_CADDYFILE" ]] \
    || install -m 0644 "$BASE_CADDYFILE" "$ACTIVE_CADDYFILE"
  install -m 0644 "$SELF_DIR/egress.Caddyfile" "$EGRESS_CADDYFILE"
  docker build --pull=false -q -t "$NODE_GUARD_IMAGE" -f "$SELF_DIR/Dockerfile.node-observation-guard" "$SELF_DIR" >/dev/null
}

compose() {
  local prometheus_origin
  [[ -f "$RUNTIME_ENV" && ! -L "$RUNTIME_ENV" ]] || die 'preview runtime configuration is unavailable'
  prometheus_origin="$(sed -n 's/^PREVIEW_PROMETHEUS_ORIGIN=//p' "$RUNTIME_ENV")"
  [[ "$prometheus_origin" =~ ^http://[A-Za-z0-9.-]+:9099$ ]] || die 'preview Prometheus origin is invalid'
  PREVIEW_ROOT="$PREVIEW_ROOT" PREVIEW_RUNTIME_DIR="$RUNTIME" PREVIEW_CADDY_PORT="$PREVIEW_CADDY_PORT" \
    PREVIEW_CONTAINER_UID="${PREVIEW_CONTAINER_UID:-0}" PREVIEW_CONTAINER_GID="${PREVIEW_CONTAINER_GID:-0}" \
    PREVIEW_PROMETHEUS_ORIGIN="$prometheus_origin" \
    docker compose --project-directory "$CONTROL" -f "$COMPOSE_FILE" "$@"
}

configure_observer() {
  local origin="$1"
  [[ "$origin" =~ ^http://[A-Za-z0-9.-]+:9099$ ]] || die 'Prometheus origin must be http://HOST:9099'
  install -d -m 0700 "$CONTROL"
  printf 'PREVIEW_PROMETHEUS_ORIGIN=%s\n' "$origin" >"$RUNTIME_ENV.new"
  chmod 0600 "$RUNTIME_ENV.new"
  mv -f "$RUNTIME_ENV.new" "$RUNTIME_ENV"
}

start() {
  install_assets
  compose up -d caddy egress node-observation-guard
  for _ in $(seq 1 30); do
    [[ "$(docker inspect --format '{{.State.Running}}' gdc-preview-caddy 2>/dev/null || true)" == true &&
      "$(docker inspect --format '{{.State.Running}}' gdc-preview-node-guard 2>/dev/null || true)" == true ]] && break
    sleep 1
  done
  [[ "$(docker inspect --format '{{.State.Running}}' gdc-preview-caddy 2>/dev/null || true)" == true ]] \
    || die 'preview Caddy container did not become ready'
  [[ "$(docker inspect --format '{{.State.Running}}' gdc-preview-node-guard 2>/dev/null || true)" == true ]] \
    || die 'preview node observation guard did not become ready'
  reconcile
}

render_caddyfile() {
  local output="$1" file pr revision backend generation release
  {
    printf '%s\n' '{'
    printf '%s\n' '  admin unix//run/gdc-preview/admin.sock'
    printf '%s\n' '  auto_https off'
    printf '%s\n' '}'
    printf '%s\n' ':8080 {'
    printf '%s\n' '  respond /health "ready" 200'
    printf '%s\n' '  header Content-Security-Policy "worker-src '\''none'\''"'
    for file in "$REGISTRY"/*.json; do
      [[ -e "$file" ]] || continue
      pr="$(jq -r '.pr // empty' "$file")"
      revision="$(jq -r '.revision // empty' "$file")"
      backend="$(jq -r '.backend // empty' "$file")"
      generation="$(jq -r '.generation // empty' "$file")"
      valid_pr "$pr" && valid_revision "$revision" || die "invalid preview registry entry: $file"
      valid_revision "$generation" || die "invalid preview generation in registry entry: $file"
      release="$RELEASES/$pr/current"
      [[ -L "$release" && "$(readlink "$release")" =~ ^\.generations/[0-9a-f]{40}$ ]] \
        || die "active release is invalid for preview $pr"
      printf '  @preview_%s path /%s /%s/*\n' "$pr" "$pr" "$pr"
      printf '  handle @preview_%s {\n' "$pr"
      printf '    redir /%s /%s/ 308\n' "$pr" "$pr"
      printf '    @preview_%s_receipt path /%s/preview-composition.json /%s/preview-legacy-composition.json /%s/backend-build.json /%s/preview-runtime-config.json /%s/preview-changed-files.txt /%s/frontend-build.json /%s/backend-image.tar /%s/backend-image.tar.sha256\n' "$pr" "$pr" "$pr" "$pr" "$pr" "$pr" "$pr" "$pr" "$pr"
      printf '    handle @preview_%s_receipt {\n      respond "not found" 404\n    }\n' "$pr"
      if [[ -n "$backend" ]]; then
        printf '    @preview_%s_backend path /%s/status /%s/status/*\n' "$pr" "$pr" "$pr"
        printf '    handle @preview_%s_backend {\n' "$pr"
        printf '      uri strip_prefix /%s\n' "$pr"
        printf '      reverse_proxy %s:8080\n' "$backend"
        printf '    }\n'
      else
        # Static previews do not have a source-bound status backend. Return an
        # explicit machine-readable failure instead of falling through to the
        # SPA index and being mistaken for a successful status response.
        printf '    @preview_%s_static_status path /%s/status /%s/status/*\n' "$pr" "$pr" "$pr"
        printf '    handle @preview_%s_static_status {\n' "$pr"
        printf '      header Content-Type application/json\n'
        printf '      respond "{\\"error\\":\\"preview_status_unavailable\\"}" 503\n'
        printf '    }\n'
      fi
      printf '    handle_path /%s/* {\n' "$pr"
      printf '      root * /srv/preview/releases/%s/.generations/%s\n' "$pr" "$generation"
      printf '      try_files {path} /index.html\n'
      printf '      file_server\n'
      printf '    }\n'
      printf '  }\n'
    done
    printf '%s\n' '  respond "not found" 404'
    printf '%s\n' '}'
  } >"$output"
}

reload_caddy_unlocked() {
  local candidate="$CONTROL/staging/Caddyfile.$$.tmp" previous="$CONTROL/staging/Caddyfile.$$.previous"
  render_caddyfile "$candidate"
  if ! docker run --rm -v "$candidate:/etc/caddy/Caddyfile:ro" \
    "${PREVIEW_CADDY_IMAGE:-caddy:2.11.4-alpine}" \
    caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
    die 'generated preview Caddy configuration is invalid'
  fi
  cp -p "$ACTIVE_CADDYFILE" "$previous"
  mv -f "$candidate" "$ACTIVE_CADDYFILE"
  if ! docker exec gdc-preview-caddy caddy reload --config /etc/gdc-preview-control/Caddyfile.active --adapter caddyfile >/dev/null; then
    mv -f "$previous" "$ACTIVE_CADDYFILE"
    docker exec gdc-preview-caddy caddy reload --config /etc/gdc-preview-control/Caddyfile.active --adapter caddyfile >/dev/null 2>&1 || true
    compose logs --no-color caddy >&2 || true
    die 'preview Caddy refused the generated configuration'
  fi
  rm -f "$previous"
}

reload_caddy() {
  command -v flock >/dev/null || die 'flock is required to serialize preview route updates'
  install -d -m 0700 "$LOCKS"
  exec 8>"$LOCKS/routes.lock"
  flock -x 8
  reload_caddy_unlocked
}

with_preview_lock() {
  local pr="$1"
  shift
  command -v flock >/dev/null || die 'flock is required to serialize preview lifecycle actions'
  valid_pr "$pr" || die 'preview number must be a positive integer'
  install -d -m 0700 "$LOCKS"
  exec 9>"$LOCKS/pr-$pr.lock"
  flock -n -x 9 || die "preview lifecycle action is already running: $pr"
  "$@"
}

reconcile() {
  [[ "$(docker inspect --format '{{.State.Running}}' gdc-preview-caddy 2>/dev/null || true)" == true ]] \
    || die 'preview Caddy container is unavailable'
  reload_caddy
  curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$PREVIEW_CADDY_PORT/health" | grep -Fxq ready \
    || die 'preview Caddy health check failed'
}

assert_release() {
  local pr="$1" revision="$2" source="$3" manifest config adapter runtime_config frontend_build config_digest adapter_digest frontend_revision
  valid_pr "$pr" || die 'preview number must be a positive integer'
  valid_revision "$revision" || die 'preview revision must be a full SHA-1'
  [[ -d "$source" && ! -L "$source" ]] || die 'preview artifact directory is unsafe or absent'
  manifest="$source/preview-composition.json"
  config="$source/config.js"
  adapter="$source/preview-status-adapter.js"
  runtime_config="$source/preview-runtime-config.json"
  frontend_build="$source/frontend-build.json"
  [[ -f "$manifest" && ! -L "$manifest" ]] || die 'preview composition manifest is unsafe or absent'
  [[ -f "$config" && ! -L "$config" && -f "$adapter" && ! -L "$adapter" && -s "$runtime_config" && ! -L "$runtime_config" && -s "$frontend_build" && ! -L "$frontend_build" ]] \
    || die 'preview runtime config, adapter or receipt are unsafe or absent'
  config_digest="$(sha256sum "$config" | awk '{print $1}')"
  adapter_digest="$(sha256sum "$adapter" | awk '{print $1}')"
  jq -e --arg revision "$revision" --arg config "$config_digest" '
    .schema_version == 1 and .head_revision == $revision and
    (.mode == "static" or .mode == "backend" or .mode == "combined") and
    (.frontend_revision | type == "string" and test("^[0-9a-f]{40}$")) and
    ((.backend_revision == null) or (.backend_revision | type == "string" and test("^[0-9a-f]{40}$"))) and
    (.frontend_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.runtime_config_sha256 | . == $config and test("^[0-9a-f]{64}$")) and
    (.backend_digest == null or (.backend_digest | type == "string" and test("^[0-9a-f]{64}$"))) and
    (if (.mode == "static") then .backend_digest == null and .backend_revision == null else .backend_digest != null and .backend_revision == $revision end)
  ' "$manifest" >/dev/null || die 'preview composition manifest is invalid'
  frontend_revision="$(jq -r .frontend_revision "$manifest")"
  jq -e --arg revision "$revision" --argjson pr "$pr" --arg config "$config_digest" --arg adapter "$adapter_digest" '
    .schema_version == 1 and .source_revision == $revision and .preview_number == $pr and
    (.config_sha256 | . == $config and test("^[0-9a-f]{64}$")) and
    (.renderer_config_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.status_adapter_sha256 | . == $adapter and test("^[0-9a-f]{64}$"))
  ' "$runtime_config" >/dev/null || die 'preview runtime config receipt is invalid'
  jq -e --arg frontend "$frontend_revision" '
    .schema_version == 1 and .source_revision == $frontend and
    (.source_archive_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.builder_image_id | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$frontend_build" >/dev/null || die 'preview frontend build receipt is invalid'
}

assert_backend_image() {
  local source="$1" revision="$2" image="$3" manifest composition observed_id observed_revision observed_managed backend_digest
  manifest="$source/backend-build.json"
  composition="$source/preview-composition.json"
  [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'preview backend image must be an immutable local image ID'
  [[ -f "$manifest" && ! -L "$manifest" ]] || die 'backend preview requires a source-bound backend build manifest'
  jq -e --arg revision "$revision" --arg image "$image" '
    .schema_version == 1 and .source_revision == $revision and .image_id == $image and
    (.source_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.rendered_caddy_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.backend_caddy_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$manifest" >/dev/null || die 'backend build manifest does not bind the requested source and image'
  backend_digest="$(jq -r .backend_caddy_sha256 "$manifest")"
  jq -e --arg backend "$backend_digest" --arg image "$image" '
    .backend_digest == $backend and .backend_image_id == $image
  ' "$composition" >/dev/null || die 'preview composition does not bind the requested backend build'
  observed_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
  observed_revision="$(docker image inspect --format '{{ index .Config.Labels "gdc.preview.source-revision" }}' "$image" 2>/dev/null || true)"
  observed_managed="$(docker image inspect --format '{{ index .Config.Labels "gdc.preview.managed" }}' "$image" 2>/dev/null || true)"
  [[ "$observed_id" == "$image" && "$observed_revision" == "$revision" && "$observed_managed" == true ]] \
    || die 'local backend image does not have the expected trusted build identity'
}

start_backend() {
  local pr="$1" revision="$2" source="$3" image="$4" network backend health
  assert_backend_image "$source" "$revision" "$image"
  [[ "$image" =~ ^sha256:[0-9a-f]{64}$ || "${PREVIEW_TEST_MODE:-}" == 1 && "$image" =~ @sha256:[0-9a-f]{64}$ ]] \
    || die 'preview backend image must be an immutable image ID'
  network="$(network_name "$pr")"
  backend="$(backend_name "$pr" "$revision")"
  docker network inspect "$network" >/dev/null 2>&1 || docker network create --internal "$network" >/dev/null
  docker network connect "$network" gdc-preview-caddy 2>/dev/null || true
  docker network connect "$network" gdc-preview-egress 2>/dev/null || true
  docker network connect "$network" gdc-preview-node-guard 2>/dev/null || true
  docker run -d --name "$backend" --network "$network" --network-alias "$backend" \
    --label gdc.preview.managed=true --label "gdc.preview.pr=$pr" --label "gdc.preview.revision=$revision" \
    --env PREVIEW_OBSERVATION_BASE=http://gdc-preview-egress:8080/gonka-api \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m --cap-drop ALL \
    --security-opt no-new-privileges --pids-limit 128 --memory 512m --cpus 1 \
    --log-driver local --log-opt max-size=10m --log-opt max-file=2 \
    "$image" >/dev/null
  for _ in $(seq 1 30); do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$backend" 2>/dev/null || true)"
    [[ "$health" == healthy ]] && return 0
    [[ "$health" == unhealthy ]] && break
    sleep 1
  done
  docker logs "$backend" >&2 || true
  docker rm -f "$backend" >/dev/null 2>&1 || true
  die "preview backend did not become healthy: $backend"
}

deploy() {
  local pr="$1" revision="$2" source="$3" image="${4:-}" stage generation active previous_target old_registry old_backend backend="" manifest mode
  assert_release "$pr" "$revision" "$source"
  start
  manifest="$source/preview-composition.json"
  mode="$(jq -r '.mode' "$manifest")"
  stage="$RELEASES/$pr/.staging-$revision"
  generation="$RELEASES/$pr/.generations/$revision"
  active="$RELEASES/$pr/current"
  install -d -m 0750 "$RELEASES/$pr/.generations"
  [[ ! -e "$generation" ]] || die 'preview generation already exists'
  [[ ! -e "$stage" ]] || die 'preview staging directory already exists'
  if [[ "$mode" == backend || "$mode" == combined ]]; then
    [[ -n "$image" ]] || die 'backend or combined preview requires a source-bound backend image'
    start_backend "$pr" "$revision" "$source" "$image"
    backend="$(backend_name "$pr" "$revision")"
  elif [[ -n "$image" ]]; then
    die 'static preview must not receive a backend image'
  fi
  cp -a "$source" "$stage"
  mv -T "$stage" "$generation"
  previous_target=""
  [[ ! -L "$active" ]] || previous_target="$(readlink "$active")"
  old_registry="$(registry_file "$pr")"
  old_backend=""
  [[ ! -f "$old_registry" ]] || old_backend="$(jq -r '.backend // empty' "$old_registry")"
  if [[ -f "$old_registry" ]]; then
    cp -p "$old_registry" "$old_registry.previous"
  else
    rm -f "$old_registry.previous"
  fi
  jq -n --argjson pr "$pr" --arg revision "$revision" --arg backend "$backend" --arg mode "$mode" \
    --arg generation "$revision" --arg installed_at "$(date -u +%FT%TZ)" \
    '{schema_version:1,pr:$pr,revision:$revision,backend:(if $backend == "" then null else $backend end),mode:$mode,generation:$generation,installed_at:$installed_at}' \
    >"$old_registry.new"
  ln -s ".generations/$revision" "$active.new"
  mv -Tf "$active.new" "$active"
  mv -Tf "$old_registry.new" "$old_registry"
  if ! reload_caddy; then
    if [[ -n "$previous_target" ]]; then
      ln -s "$previous_target" "$active.rollback"
      mv -Tf "$active.rollback" "$active"
    else
      rm -f "$active"
    fi
    if [[ -f "$old_registry.previous" ]]; then
      mv -Tf "$old_registry.previous" "$old_registry"
    else
      rm -f "$old_registry"
    fi
    [[ -z "$backend" ]] || docker rm -f "$backend" >/dev/null 2>&1 || true
    reload_caddy || true
    die 'preview route reload failed; the prior generation was restored when present'
  fi
  rm -f "$old_registry.previous"
  [[ -z "$old_backend" ]] || docker rm -f "$old_backend" >/dev/null 2>&1 || true
  printf 'READY preview=%s revision=%s mode=%s\n' "$pr" "$revision" "$mode"
}

remove_preview() {
  local pr="$1" registry backend network
  valid_pr "$pr" || die 'preview number must be a positive integer'
  registry="$(registry_file "$pr")"
  backend=""
  [[ ! -f "$registry" ]] || backend="$(jq -r '.backend // empty' "$registry")"
  rm -f "$registry"
  start
  reload_caddy
  [[ -z "$backend" ]] || docker rm -f "$backend" >/dev/null 2>&1 || true
  network="$(network_name "$pr")"
  docker network disconnect "$network" gdc-preview-caddy >/dev/null 2>&1 || true
  docker network disconnect "$network" gdc-preview-egress >/dev/null 2>&1 || true
  docker network disconnect "$network" gdc-preview-node-guard >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf -- "${RELEASES:?}/$pr" "${PREVIEW_ROOT:?}/staging/$pr"
  printf 'READY preview=%s removed\n' "$pr"
}

status() {
  local pr="$1" registry
  valid_pr "$pr" || die 'preview number must be a positive integer'
  registry="$(registry_file "$pr")"
  [[ -f "$registry" ]] || die 'preview is not registered'
  jq -c . "$registry"
}

require_preview_user
case "${1:-}" in
install) command -v docker >/dev/null || die 'Docker CLI is unavailable'; install_assets ;;
configure-observer) [[ $# -eq 2 ]] || die 'usage: previewctl.sh configure-observer http://HOST:9099'; configure_observer "$2" ;;
  start) require_layout; start ;;
  reconcile) require_layout; reconcile ;;
  deploy) require_layout; [[ $# -ge 4 && $# -le 5 ]] || die 'usage: previewctl.sh deploy PR REVISION ARTIFACT_DIR [BACKEND_IMAGE]'; with_preview_lock "$2" deploy "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  remove) require_layout; [[ $# -eq 2 ]] || die 'usage: previewctl.sh remove PR'; with_preview_lock "$2" remove_preview "$2" ;;
  status) require_layout; [[ $# -eq 2 ]] || die 'usage: previewctl.sh status PR'; status "$2" ;;
  *) die 'usage: previewctl.sh install|start|reconcile|deploy|remove|status' ;;
esac
