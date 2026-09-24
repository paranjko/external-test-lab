#!/usr/bin/env bash
set -Eeuo pipefail

# Runs only in the untrusted pull-request workflow, it produces data for the
# trusted publisher and receives neither deployment nor GitHub-write secrets.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="${PREVIEW_RELEASE_DIR:-}"
backend_image="${PREVIEW_BACKEND_IMAGE:-}"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }
[[ "$release_dir" = /* && "$release_dir" != / && "$release_dir" != *..* ]] || die 'PREVIEW_RELEASE_DIR must be an absolute safe path'
[[ "$backend_image" =~ ^[a-z0-9][a-z0-9._/-]*:[a-z0-9][a-z0-9._-]*$ ]] || die 'PREVIEW_BACKEND_IMAGE is invalid'

"$root/scripts/prepare-isolated-preview-ci.sh"
if [[ ! -f "$release_dir/preview-composition.json" ]]; then
  printf 'SKIP no source-bound preview artifact was produced\n'
  exit 0
fi
mode="$(jq -r '.mode // empty' "$release_dir/preview-composition.json")"
case "$mode" in
  static) ;;
  backend|combined)
    image_id="$(docker image inspect --format '{{.Id}}' "$backend_image")"
    [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'built backend image is unavailable'
    docker image save "$backend_image" -o "$release_dir/backend-image.tar"
    sha256sum "$release_dir/backend-image.tar" | awk '{print $1}' >"$release_dir/backend-image.tar.sha256"
    ;;
  *) die 'preview composition mode is invalid' ;;
esac
printf 'PASS prepared credential-free source-bound preview artifact\n'
