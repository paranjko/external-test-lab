#!/usr/bin/env bash
set -Eeuo pipefail

# Runs in the trusted workflow after downloading an artifact created by the
# untrusted pull-request workflow. It validates only data and never executes
# files supplied by the pull request.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="${site_release_dir:-}"
number="${preview_number:-}"
base_revision="${preview_base_revision:-}"
revision="${preview_revision:-}"
backend_image="${preview_backend_image:-}"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }
[[ -d "$release_dir" && ! -L "$release_dir" ]] || die 'site_release_dir is unavailable or unsafe'
[[ "$number" =~ ^[1-9][0-9]*$ ]] || die 'preview number is invalid'
[[ "$base_revision" =~ ^[0-9a-f]{40}$ && "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'preview revisions are invalid'
[[ "$backend_image" =~ ^[a-z0-9][a-z0-9._/-]*:[a-z0-9][a-z0-9._-]*$ ]] || die 'preview backend image is invalid'
if find "$release_dir" -type l -print -quit | grep -q .; then
  die 'downloaded preview artifact contains a symbolic link'
fi
"$root/scripts/verify-site-preview-artifact.sh" "$release_dir" "$revision"
legacy="$release_dir/preview-legacy-composition.json"
[[ -s "$legacy" && ! -L "$legacy" ]] || die 'legacy preview composition is unavailable or unsafe'
jq -e --arg base "$base_revision" --arg head "$revision" '
  .schema_version == 1 and .base_revision == $base and .head_revision == $head
' "$legacy" >/dev/null || die 'legacy preview composition does not bind the selected PR range'
mode="$(jq -r '.mode // empty' "$release_dir/preview-composition.json")"
case "$mode" in
  static)
    [[ ! -e "$release_dir/backend-image.tar" && ! -e "$release_dir/backend-image.tar.sha256" ]] || die 'static artifact must not contain a backend image'
    ;;
  backend|combined)
    [[ -s "$release_dir/backend-image.tar" && -s "$release_dir/backend-image.tar.sha256" ]] || die 'backend artifact is incomplete'
    expected_tar="$(cat "$release_dir/backend-image.tar.sha256")"
    [[ "$expected_tar" =~ ^[0-9a-f]{64}$ ]] || die 'backend archive digest is invalid'
    [[ "$expected_tar" == "$(sha256sum "$release_dir/backend-image.tar" | awk '{print $1}')" ]] || die 'backend archive digest mismatch'
    docker image load -i "$release_dir/backend-image.tar" >/dev/null
    image_id="$(docker image inspect --format '{{.Id}}' "$backend_image")"
    manifest_id="$(jq -r '.backend_image_id // empty' "$release_dir/preview-composition.json")"
    [[ "$image_id" == "$manifest_id" ]] || die 'loaded backend image does not match the composition manifest'
    jq -e --argjson preview "$number" --arg revision "$revision" '
      .schema_version == 1 and .preview_number == $preview and .source_revision == $revision
    ' "$release_dir/backend-build.json" >/dev/null || die 'backend build manifest does not bind this PR and revision'
    source_revision="$(docker image inspect --format '{{ index .Config.Labels "gdc.preview.source-revision" }}' "$backend_image")"
    managed="$(docker image inspect --format '{{ index .Config.Labels "gdc.preview.managed" }}' "$backend_image")"
    [[ "$source_revision" == "$revision" && "$managed" == true ]] || die 'loaded backend image labels are invalid'
    ;;
  *) die 'preview composition mode is invalid' ;;
esac
printf 'PASS verified downloaded source-bound preview artifact pr=%s revision=%s\n' "$number" "$revision"
