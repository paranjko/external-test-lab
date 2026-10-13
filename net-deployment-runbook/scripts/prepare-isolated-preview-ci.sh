#!/usr/bin/env bash
set -Eeuo pipefail

# Credential-free CI preparation. The selected PR checkout is treated only as
# source input by disposable builders, its scripts never run as a publisher.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_repository="${PREVIEW_SOURCE_REPOSITORY:-}"
release_dir="${PREVIEW_RELEASE_DIR:-}"
backend_dir="${PREVIEW_BACKEND_DIR:-}"
inventory="${PREVIEW_INVENTORY:-}"
number="${PREVIEW_NUMBER:-}"
base_revision="${PREVIEW_BASE_REVISION:-}"
revision="${PREVIEW_REVISION:-}"
backend_image="${PREVIEW_BACKEND_IMAGE:-}"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }

for required in source_repository release_dir backend_dir inventory number base_revision revision backend_image; do
  [[ -n "${!required}" ]] || die "PREVIEW_${required^^} is required"
done
[[ "$number" =~ ^[1-9][0-9]*$ ]] || die 'PREVIEW_NUMBER must be positive'
[[ "$base_revision" =~ ^[0-9a-f]{40}$ && "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'preview revisions must be full SHA-1 values'
[[ "$release_dir" = /* && "$backend_dir" = /* && "$inventory" = /* ]] || die 'CI output paths must be absolute'
[[ ! -e "$release_dir" && ! -e "$backend_dir" && ! -e "$inventory" ]] || die 'CI output paths must be new'

"$root/scripts/prepare-public-preview-inventory.sh" --output "$inventory"
"$root/scripts/prepare-isolated-site-preview-artifact.sh" \
  "$source_repository" "$release_dir" "$base_revision" "$revision" "$inventory" "$number" "$backend_dir" "$backend_image"
printf 'PASS prepared trusted CI source-bound preview pr=%s revision=%s\n' "$number" "$revision"
