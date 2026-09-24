#!/usr/bin/env bash
set -Eeuo pipefail

# Build site bytes from an exact Git object in a disposable container. The
# source checkout, GDC_HOME, SSH keys and Docker socket are never mounted.

source_repository="${1:-}"
revision="${2:-}"
output="${3:-}"
builder_image="${PREVIEW_FRONTEND_BUILDER_IMAGE:-gdc-preview-frontend-builder:local}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dockerfile="$root/ops/preview/Dockerfile.frontend-builder"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }
git -C "$source_repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'source repository is not a Git checkout'
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'revision must be a full SHA-1'
git -C "$source_repository" cat-file -e "$revision^{commit}" || die 'revision is unavailable in the source repository'
[[ "$output" = /* && "$output" != / && "$output" != *..* ]] || die 'output must be an absolute non-root path without ..'
[[ ! -e "$output" ]] || die 'output must not already exist'
[[ "$builder_image" =~ ^[a-z0-9][a-z0-9._/-]*:[a-z0-9][a-z0-9._-]*$ ]] || die 'builder image reference is invalid'
[[ -f "$dockerfile" && ! -L "$dockerfile" ]] || die 'trusted frontend builder Dockerfile is unavailable'

parent="$(dirname "$output")"
lock_dir="$parent/.${output##*/}.lock"
mkdir "$lock_dir" 2>/dev/null || die 'frontend build for this output is already running or retained for diagnosis'
workspace="$(mktemp -d "$parent/.preview-frontend-build.XXXXXX")"
source_archive="$workspace/source.tar"
source_dir="$workspace/source"
stage="$workspace/artifact"
build_log="$workspace/build.log"
failure_log="${output}.failed.log"
mkdir -p "$source_dir" "$stage"
chmod 0755 "$stage"
cleanup() {
  rm -rf -- "$workspace"
  rmdir -- "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$source_repository" archive --format=tar "$revision" >"$source_archive"
source_archive_sha256="$(sha256sum "$source_archive" | awk '{print $1}')"
tar -xf "$source_archive" -C "$source_dir"

docker build --pull=false -q -t "$builder_image" -f "$dockerfile" "$root/ops/preview" >/dev/null
builder_image_id="$(docker image inspect --format '{{.Id}}' "$builder_image")"
build_uid="$(id -u)"
build_gid="$(id -g)"
if ! docker run --rm --network bridge --read-only --user "$build_uid:$build_gid" --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 256 --memory 1g --cpus 1 \
  --tmpfs /workspace:rw,exec,nosuid,nodev,size=2g,uid="$build_uid",gid="$build_gid" \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m,uid="$build_uid",gid="$build_gid" \
  --tmpfs /cache:rw,exec,nosuid,nodev,size=512m,uid="$build_uid",gid="$build_gid" \
  -e HOME=/tmp/home -e npm_config_cache=/cache/npm -e PREVIEW_SOURCE_REVISION="$revision" \
  -v "$source_dir:/input:ro" -v "$stage:/out" \
  "$builder_image" bash -ceu '
    cp -R /input/. /workspace/
    git -C /workspace init -q
    cd /workspace/net-deployment-runbook
    ./scripts/install-site-vendor.sh
    make prepare-static-site site_release_dir=/out site_revision="$PREVIEW_SOURCE_REVISION"
  ' >"$build_log" 2>&1; then
  install -m 0644 "$build_log" "$failure_log"
  sed -n '1,240p' "$build_log" >&2
  die "disposable frontend build failed; terminal log retained at $failure_log"
fi

[[ -s "$stage/index.html" && -s "$stage/app.js" && -s "$stage/site-build.js" ]] \
  || die 'disposable frontend build did not produce the required static artifact'
jq -n --arg revision "$revision" --arg archive "$source_archive_sha256" --arg builder "$builder_image_id" \
  '{schema_version:1,source_revision:$revision,source_archive_sha256:$archive,builder_image_id:$builder}' \
  >"$stage/frontend-build.json"
mv -T "$stage" "$output"
printf 'PASS built disposable source-bound frontend revision=%s\n' "$revision"
