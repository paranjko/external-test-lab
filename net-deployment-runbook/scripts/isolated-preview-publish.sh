#!/usr/bin/env bash
set -Eeuo pipefail

# Trusted publisher for the rootless preview runtime.  It deliberately does
# not source an env file: local preview configuration is data, not shell code.

action="${1:-}"
release_dir="${2:-}"
preview_number="${3:-}"
revision="${4:-}"
backend_image="${5:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository_root="$(cd "$root/.." && pwd)"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }

[[ "$action" =~ ^(publish|remove|status)$ ]] || die 'usage: isolated-preview-publish.sh publish|remove|status RELEASE_DIR PR REVISION [BACKEND_IMAGE]'
[[ "$preview_number" =~ ^[1-9][0-9]*$ ]] || die 'preview number must be positive'
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'preview revision must be a full SHA-1'

preview_env_file="${GDC_SITE_PREVIEW_ENV_FILE:-}"
if [[ -z "$preview_env_file" ]]; then
  gdc_home="${GDC_HOME:-$HOME/.gdc-data}"
  if [[ -r "$gdc_home/.env-site-preview" ]]; then
    preview_env_file="$gdc_home/.env-site-preview"
  else
    preview_env_file="$root/.env-site-preview"
  fi
fi
[[ -f "$preview_env_file" && ! -L "$preview_env_file" ]] || die 'preview environment file is unavailable or unsafe'
permissions="$(stat -c '%a' "$preview_env_file")"
(( (8#$permissions & 077) == 0 )) || die 'preview environment file must not be readable by group or others'

deploy_host=''
deploy_user=''
deploy_key=''
known_hosts=''
prometheus_origin=''
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die 'preview environment contains an invalid line'
  key="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"
  case "$key" in
    DEPLOY_HOST) deploy_host="$value" ;;
    DEPLOY_USER) deploy_user="$value" ;;
    DEPLOY_PRIVATE_KEY_FILE) deploy_key="$value" ;;
    DEPLOY_KNOWN_HOSTS_FILE) known_hosts="$value" ;;
    PREVIEW_PROMETHEUS_ORIGIN) prometheus_origin="$value" ;;
    *) die "preview environment contains unsupported key: $key" ;;
  esac
done <"$preview_env_file"

deploy_host="${deploy_host:-${PREVIEW_DEPLOY_HOST:-gdc-node4}}"
[[ "$deploy_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die 'DEPLOY_HOST is invalid'
[[ "$deploy_user" == preview ]] || die 'DEPLOY_USER must be preview for isolated publication'
[[ -r "$deploy_key" && ! -L "$deploy_key" ]] || die 'DEPLOY_PRIVATE_KEY_FILE is unavailable or unsafe'
[[ -r "$known_hosts" && ! -L "$known_hosts" ]] || die 'DEPLOY_KNOWN_HOSTS_FILE is unavailable or unsafe'
[[ "$prometheus_origin" =~ ^http://[A-Za-z0-9.-]+:9099$ ]] || die 'PREVIEW_PROMETHEUS_ORIGIN must be http://HOST:9099'

ssh_options=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$deploy_key" -o "UserKnownHostsFile=$known_hosts" -o StrictHostKeyChecking=yes)
remote="$deploy_user@$deploy_host"
ssh_transport="$(printf '%q ' ssh "${ssh_options[@]}")"
remote_root=/srv/preview
remote_source="$remote_root/publisher/$revision"
remote_artifact="$remote_root/staging/$preview_number/$revision"
remote_controller="$remote_source/previewctl.sh"

sync_trusted_controller() {
  ssh "${ssh_options[@]}" "$remote" "set -Eeuo pipefail; umask 077; install -d -m 0750 '$remote_source'"
  rsync -a --delete -e "$ssh_transport" "$repository_root/ops/preview/" "$remote:$remote_source/"
}

load_backend_image() {
  local manifest="$1" requested_image="$2" image_id source_revision source_managed
  [[ "$requested_image" =~ ^[a-z0-9][a-z0-9._/-]*:[a-z0-9][a-z0-9._-]*$ || "$requested_image" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die 'backend image reference is invalid'
  [[ -f "$manifest" && ! -L "$manifest" ]] || die 'source-bound backend build manifest is unavailable or unsafe'
  image_id="$(docker image inspect --format '{{.Id}}' "$requested_image" 2>/dev/null || true)"
  source_revision="$(docker image inspect --format '{{ index .Config.Labels "gdc.preview.source-revision" }}' "$requested_image" 2>/dev/null || true)"
  source_managed="$(docker image inspect --format '{{ index .Config.Labels "gdc.preview.managed" }}' "$requested_image" 2>/dev/null || true)"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ && "$source_revision" == "$revision" && "$source_managed" == true ]] \
    || die 'local backend image is not a trusted build for this preview revision'
  jq -e --arg revision "$revision" --arg image "$image_id" '
    .schema_version == 1 and .source_revision == $revision and .image_id == $image and
    (.source_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.rendered_caddy_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.backend_caddy_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$manifest" >/dev/null || die 'backend build manifest does not bind the local image'
  docker image save "$image_id" | ssh "${ssh_options[@]}" "$remote" \
    "set -Eeuo pipefail; export XDG_RUNTIME_DIR=/run/user/\$(id -u); docker image load >/dev/null; test \"\$(docker image inspect --format '{{.Id}}' '$image_id')\" = '$image_id'"
  printf '%s\n' "$image_id"
}

case "$action" in
  publish)
    [[ -d "$release_dir" && ! -L "$release_dir" ]] || die 'preview release directory is unavailable or unsafe'
    manifest="$release_dir/preview-composition.json"
    [[ -s "$manifest" && ! -L "$manifest" ]] || die 'isolated preview composition manifest is unavailable or unsafe'
    jq -e --arg revision "$revision" '
      .schema_version == 1 and .head_revision == $revision and
      (.mode == "static" or .mode == "backend" or .mode == "combined") and
      (.frontend_digest | type == "string" and test("^[0-9a-f]{64}$")) and
      (.backend_digest == null or (.backend_digest | type == "string" and test("^[0-9a-f]{64}$")))
    ' "$manifest" >/dev/null || die 'isolated preview composition manifest is invalid'
    mode="$(jq -r .mode "$manifest")"
    # Reserve before transferring a backend image. A repeated publication then
    # fails without importing an otherwise unreferenced image into preview.
    ssh "${ssh_options[@]}" "$remote" "set -Eeuo pipefail; umask 077; test ! -e '$remote_artifact'; install -d -m 0750 '$remote_source' '$remote_artifact'"
    backend_image_id=''
    if [[ "$mode" == static ]]; then
      [[ -z "$backend_image" ]] || die 'static preview must not receive a backend image'
    else
      backend_image_id="$(load_backend_image "$release_dir/backend-build.json" "$backend_image")"
    fi
    sync_trusted_controller
    rsync -a --delete -e "$ssh_transport" "$release_dir/" "$remote:$remote_artifact/"
    ssh "${ssh_options[@]}" "$remote" "set -Eeuo pipefail; export XDG_RUNTIME_DIR=/run/user/\$(id -u); '$remote_controller' install; '$remote_controller' configure-observer '$prometheus_origin'; '$remote_controller' deploy '$preview_number' '$revision' '$remote_artifact' '${backend_image_id}'"
    ;;
  remove)
    sync_trusted_controller
    ssh "${ssh_options[@]}" "$remote" "set -Eeuo pipefail; export XDG_RUNTIME_DIR=/run/user/\$(id -u); '$remote_controller' remove '$preview_number'"
    ;;
  status)
    sync_trusted_controller
    ssh "${ssh_options[@]}" "$remote" "set -Eeuo pipefail; export XDG_RUNTIME_DIR=/run/user/\$(id -u); '$remote_controller' status '$preview_number'"
    ;;
esac
