#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:-}"
expected_revision="${2:-}"
[[ -d "$release_dir" ]] || { echo 'release directory is required' >&2; exit 2; }
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'preview revision must be a full SHA-1' >&2; exit 2; }

manifest="$release_dir/site-build.js"
[[ -s "$manifest" ]] || { echo 'site build manifest is required' >&2; exit 1; }
[[ -s "$release_dir/index.html" && -s "$release_dir/app.js" ]] || {
  echo 'preview static artifact is incomplete' >&2
  exit 1
}
grep -Fq 'src="config.js"' "$release_dir/index.html" || {
  echo 'preview must use its generation-bound relative config handler' >&2
  exit 1
}
grep -Fq 'src="preview-status-adapter.js"' "$release_dir/index.html" || {
  echo 'preview must load the trusted status adapter after its config' >&2
  exit 1
}
[[ -s "$release_dir/config.js" && -s "$release_dir/preview-status-adapter.js" && -s "$release_dir/preview-runtime-config.json" ]] || {
  echo 'preview runtime config is required' >&2
  exit 1
}
for synthetic_endpoint in \
  status/participants \
  status/software \
  status/gpus \
  status/gateway-health \
  status/gateway/v1/status \
  status/gateway/v1/admission-status; do
  [[ ! -e "$release_dir/$synthetic_endpoint" ]] || {
    echo "preview artifact must not contain synthetic endpoint data: $synthetic_endpoint" >&2
    exit 1
  }
done
if grep -r -Eq 'preview\.invalid|preview_fixture' "$release_dir"; then
  echo 'preview artifact must not contain synthetic preview values' >&2
  exit 1
fi
revision="$(sed -n 's/.*"revision":"\([0-9a-f]\{40\}\)".*/\1/p' "$manifest")"
digest="$(sed -n 's/.*"artifactDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$manifest")"
app_digest="$(sed -n 's/.*"appDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$manifest")"
composition="$release_dir/preview-composition.json"
[[ "$revision" == "$expected_revision" ]] || { echo 'preview artifact revision differs from PR head' >&2; exit 1; }
[[ "$digest" == "$(bash "$(dirname "$0")/site-static-digest.sh" "$release_dir")" ]] || { echo 'preview artifact digest is invalid' >&2; exit 1; }
[[ "$app_digest" == "$(sha256sum "$release_dir/app.js" | awk '{print $1}')" ]] || { echo 'preview app digest is invalid' >&2; exit 1; }
[[ -s "$composition" ]] || { echo 'preview composition manifest is required' >&2; exit 1; }
jq -e --arg head "$expected_revision" '
  .schema_version == 1 and
  .head_revision == $head and
  (.mode == "static" or .mode == "backend" or .mode == "combined") and
  (.frontend_revision | type == "string" and test("^[0-9a-f]{40}$")) and
  ((.backend_revision == null) or (.backend_revision | type == "string" and test("^[0-9a-f]{40}$"))) and
  (.frontend_digest | type == "string" and test("^[0-9a-f]{64}$")) and
  (.runtime_config_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.legacy_composition_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (if (.mode == "backend" or .mode == "combined") then
     (.backend_digest | type == "string" and test("^[0-9a-f]{64}$")) and
     (.backend_image_id | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
     (.backend_source_digest | type == "string" and test("^[0-9a-f]{64}$"))
   else .backend_digest == null and .backend_revision == null end)
' "$composition" >/dev/null || { echo 'preview composition manifest is invalid' >&2; exit 1; }
frontend_revision="$(jq -r .frontend_revision "$composition")"
jq -e --arg frontend "$frontend_revision" '
  .schema_version == 1 and .source_revision == $frontend and
  (.source_archive_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.builder_image_id | type == "string" and test("^sha256:[0-9a-f]{64}$"))
' "$release_dir/frontend-build.json" >/dev/null || { echo 'frontend build manifest is invalid' >&2; exit 1; }
config_digest="$(sha256sum "$release_dir/config.js" | awk '{print $1}')"
jq -e --arg head "$expected_revision" --arg config "$config_digest" '
  .schema_version == 1 and .source_revision == $head and
  (.preview_number | type == "number" and . > 0) and
  (.config_sha256 | . == $config and test("^[0-9a-f]{64}$")) and
  (.renderer_config_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.status_adapter_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
' "$release_dir/preview-runtime-config.json" >/dev/null || { echo 'preview runtime config receipt is invalid' >&2; exit 1; }
adapter_digest="$(sha256sum "$release_dir/preview-status-adapter.js" | awk '{print $1}')"
jq -e --arg adapter "$adapter_digest" '.status_adapter_sha256 == $adapter' "$release_dir/preview-runtime-config.json" >/dev/null \
  || { echo 'preview status adapter digest is invalid' >&2; exit 1; }
