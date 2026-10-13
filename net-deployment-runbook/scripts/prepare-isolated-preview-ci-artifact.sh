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
# The composition already binds the archive bytes; another docker save can
# change them even for the same image.
"$root/scripts/verify-site-preview-artifact.sh" "$release_dir" "$PREVIEW_REVISION"
printf 'PASS prepared credential-free source-bound preview artifact\n'
