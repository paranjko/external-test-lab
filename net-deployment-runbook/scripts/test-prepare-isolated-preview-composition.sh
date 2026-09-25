#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$ROOT/.data/isolated-composition-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
revision=0123456789012345678901234567890123456789
digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

mkdir -p "$tmp/static"
printf 'window.GDC_SITE_BUILD={"revision":"%s","artifactDigest":"%s"};\n' "$revision" "$digest" >"$tmp/static/site-build.js"
printf '%s\n' '{"schema_version":1,"head_revision":"'"$revision"'","mode":"static","static_revision":"'"$revision"'","endpoint_revision":"'"$revision"'"}' >"$tmp/static/preview-composition.json"
printf 'window.GDC_CONFIG = {};\n' >"$tmp/static/config.js"
config_digest="$(sha256sum "$tmp/static/config.js" | awk '{print $1}')"
printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision"'","preview_number":172,"renderer_config_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","config_sha256":"'"$config_digest"'"}' >"$tmp/static/preview-runtime-config.json"
"$ROOT/scripts/prepare-isolated-preview-composition.sh" "$tmp/static" "$revision"
jq -e --arg revision "$revision" --arg digest "$digest" '
  .head_revision == $revision and .mode == "static" and .frontend_revision == $revision and .backend_revision == null and .frontend_digest == $digest and (.runtime_config_sha256 | test("^[0-9a-f]{64}$")) and .backend_digest == null
' "$tmp/static/preview-composition.json" >/dev/null
[[ -s "$tmp/static/preview-legacy-composition.json" ]]

mkdir -p "$tmp/endpoint"
cp "$tmp/static/site-build.js" "$tmp/endpoint/site-build.js"
cp "$tmp/static/config.js" "$tmp/endpoint/config.js"
cp "$tmp/static/preview-runtime-config.json" "$tmp/endpoint/preview-runtime-config.json"
base_revision=9999999999999999999999999999999999999999
printf '%s\n' '{"schema_version":1,"head_revision":"'"$revision"'","mode":"endpoint","static_revision":"'"$base_revision"'","endpoint_revision":"'"$revision"'"}' >"$tmp/endpoint/preview-composition.json"
before="$(sha256sum "$tmp/endpoint/preview-composition.json" | awk '{print $1}')"
if "$ROOT/scripts/prepare-isolated-preview-composition.sh" "$tmp/endpoint" "$revision"; then
  echo 'endpoint composition unexpectedly accepted without a backend image' >&2
  exit 1
fi
after="$(sha256sum "$tmp/endpoint/preview-composition.json" | awk '{print $1}')"
[[ "$before" == "$after" ]] || { echo 'endpoint rejection rewrote historical composition' >&2; exit 1; }

mkdir -p "$tmp/backend"
printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision"'","preview_number":172,"source_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","rendered_caddy_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","backend_caddy_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","image_id":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' >"$tmp/backend/backend-build.json"
"$ROOT/scripts/prepare-isolated-preview-composition.sh" "$tmp/endpoint" "$revision" "$tmp/backend"
jq -e --arg revision "$revision" '
  .head_revision == $revision and .mode == "backend" and .frontend_revision == "9999999999999999999999999999999999999999" and .backend_revision == $revision and
  .backend_digest == "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" and
  .backend_image_id == "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
' "$tmp/endpoint/preview-composition.json" >/dev/null
cmp "$tmp/backend/backend-build.json" "$tmp/endpoint/backend-build.json"

printf 'PASS isolated composition binds static and source-built backend artifacts\n'
