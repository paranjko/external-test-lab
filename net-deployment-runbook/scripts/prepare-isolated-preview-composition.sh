#!/usr/bin/env bash
set -Eeuo pipefail

# Convert the legacy static artifact description into the contract consumed by
# the isolated runtime. Endpoint changes deliberately do not pass here: they
# require an actual PR-built backend image, not the production status proxy.

release_dir="${1:-}"
expected_revision="${2:-}"
backend_build_dir="${3:-}"
[[ -d "$release_dir" && ! -L "$release_dir" ]] || { echo 'release directory is unavailable or unsafe' >&2; exit 2; }
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'preview revision must be a full SHA-1' >&2; exit 2; }

legacy="$release_dir/preview-composition.json"
build="$release_dir/site-build.js"
runtime_config="$release_dir/preview-runtime-config.json"
config="$release_dir/config.js"
[[ -f "$legacy" && ! -L "$legacy" && -s "$build" && -f "$runtime_config" && ! -L "$runtime_config" && -f "$config" && ! -L "$config" ]] || { echo 'legacy preview composition, build manifest and generation-bound runtime config are required' >&2; exit 2; }
mode="$(jq -r '.mode // empty' "$legacy")"
[[ "$mode" =~ ^(static|endpoint|combined)$ ]] || { echo 'legacy preview composition mode is invalid' >&2; exit 1; }
head="$(jq -r '.head_revision // empty' "$legacy")"
[[ "$head" == "$expected_revision" ]] || { echo 'legacy composition revision differs from expected revision' >&2; exit 1; }
frontend_revision="$(jq -r '.static_revision // empty' "$legacy")"
endpoint_revision="$(jq -r '.endpoint_revision // empty' "$legacy")"
[[ "$frontend_revision" =~ ^[0-9a-f]{40}$ && "$endpoint_revision" =~ ^[0-9a-f]{40}$ ]] \
  || { echo 'legacy composition source revisions are invalid' >&2; exit 1; }
frontend_digest="$(sed -n 's/.*"artifactDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$build")"
[[ "$frontend_digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'site build artifact digest is invalid' >&2; exit 1; }
config_digest="$(sha256sum "$config" | awk '{print $1}')"
jq -e --arg head "$expected_revision" --arg config "$config_digest" '
  .schema_version == 1 and .source_revision == $head and
  (.config_sha256 | . == $config and test("^[0-9a-f]{64}$")) and
  (.renderer_config_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
' "$runtime_config" >/dev/null || { echo 'runtime config does not bind this generation' >&2; exit 1; }

legacy_sha="$(sha256sum "$legacy" | awk '{print $1}')"
candidate="$release_dir/preview-composition.isolated.$$.json"
if [[ "$mode" == static ]]; then
  jq -n \
    --arg head "$head" \
    --arg frontend "$frontend_digest" --arg frontend_revision "$frontend_revision" \
    --arg config "$config_digest" \
    --arg legacy_sha "$legacy_sha" \
    '{schema_version:1,head_revision:$head,mode:"static",frontend_revision:$frontend_revision,backend_revision:null,frontend_digest:$frontend,runtime_config_sha256:$config,backend_digest:null,legacy_composition_sha256:$legacy_sha}' \
    >"$candidate"
  jq -e --arg head "$expected_revision" '
    .schema_version == 1 and .head_revision == $head and .mode == "static" and .frontend_revision == $head and .backend_revision == null and
    (.frontend_digest | test("^[0-9a-f]{64}$")) and (.runtime_config_sha256 | test("^[0-9a-f]{64}$")) and .backend_digest == null and
    (.legacy_composition_sha256 | test("^[0-9a-f]{64}$"))
  ' "$candidate" >/dev/null
else
  backend_manifest="$backend_build_dir/backend-build.json"
  [[ -f "$backend_manifest" && ! -L "$backend_manifest" ]] || {
    echo "isolated preview requires a PR-built backend manifest for legacy mode=$mode" >&2
    exit 1
  }
  jq -e --arg endpoint "$endpoint_revision" '
    .schema_version == 1 and .source_revision == $endpoint and
    (.preview_number | type == "number" and . > 0) and
    (.source_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.rendered_caddy_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.backend_caddy_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.image_id | type == "string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$backend_manifest" >/dev/null || { echo 'backend build manifest is invalid' >&2; exit 1; }
  cp -p "$backend_manifest" "$release_dir/backend-build.json"
  isolated_mode=backend
  [[ "$mode" == combined ]] && isolated_mode=combined
  jq -n \
    --arg head "$head" --arg frontend_revision "$frontend_revision" --arg endpoint_revision "$endpoint_revision" --arg mode "$isolated_mode" \
    --arg frontend "$frontend_digest" \
    --arg config "$config_digest" \
    --arg legacy_sha "$legacy_sha" \
    --arg backend "$(jq -r .backend_caddy_sha256 "$backend_manifest")" \
    --arg image "$(jq -r .image_id "$backend_manifest")" \
    --arg source "$(jq -r .source_digest "$backend_manifest")" \
    '{schema_version:1,head_revision:$head,mode:$mode,frontend_revision:$frontend_revision,backend_revision:$endpoint_revision,frontend_digest:$frontend,runtime_config_sha256:$config,backend_digest:$backend,backend_image_id:$image,backend_source_digest:$source,legacy_composition_sha256:$legacy_sha}' \
    >"$candidate"
  jq -e --arg head "$expected_revision" '
    .schema_version == 1 and .head_revision == $head and (.mode == "backend" or .mode == "combined") and
    (.frontend_revision | test("^[0-9a-f]{40}$")) and (.backend_revision | test("^[0-9a-f]{40}$")) and
    (.frontend_digest | test("^[0-9a-f]{64}$")) and
    (.runtime_config_sha256 | test("^[0-9a-f]{64}$")) and
    (.backend_digest | test("^[0-9a-f]{64}$")) and
    (.backend_image_id | test("^sha256:[0-9a-f]{64}$")) and
    (.backend_source_digest | test("^[0-9a-f]{64}$")) and
    (.legacy_composition_sha256 | test("^[0-9a-f]{64}$"))
  ' "$candidate" >/dev/null
fi
mv -f "$legacy" "$release_dir/preview-legacy-composition.json"
mv -f "$candidate" "$legacy"
printf 'PASS isolated preview composition prepared revision=%s mode=%s\n' "$expected_revision" "$mode"
