#!/usr/bin/env bash
set -Eeuo pipefail

# Select the backend image from the verified composition instead of requiring a
# workflow to infer the mode from a PR. The trusted publisher remains the
# common local and CI deployment entry point.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="${site_release_dir:-}"
number="${preview_number:-}"
revision="${preview_revision:-}"
backend_image="${preview_backend_image:-}"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }
[[ -d "$release_dir" && ! -L "$release_dir" ]] || die 'site_release_dir is unavailable or unsafe'
[[ "$number" =~ ^[1-9][0-9]*$ && "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'preview identity is invalid'
mode="$(jq -r '.mode // empty' "$release_dir/preview-composition.json")"
case "$mode" in
  static) backend_image='' ;;
  backend|combined) [[ -n "$backend_image" ]] || die 'preview_backend_image is required for a backend preview' ;;
  *) die 'preview composition mode is invalid' ;;
esac
"$root/scripts/isolated-preview-publish.sh" publish "$release_dir" "$number" "$revision" "$backend_image"
