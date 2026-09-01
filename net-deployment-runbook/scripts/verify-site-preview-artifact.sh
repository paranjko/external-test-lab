#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:-}"
expected_revision="${2:-}"
[[ -d "$release_dir" ]] || { echo 'release directory is required' >&2; exit 2; }
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'preview revision must be a full SHA-1' >&2; exit 2; }

manifest="$release_dir/site-build.js"
[[ -s "$manifest" ]] || { echo 'site build manifest is required' >&2; exit 1; }
revision="$(sed -n 's/.*"revision":"\([0-9a-f]\{40\}\)".*/\1/p' "$manifest")"
digest="$(sed -n 's/.*"artifactDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$manifest")"
app_digest="$(sed -n 's/.*"appDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$manifest")"
[[ "$revision" == "$expected_revision" ]] || { echo 'preview artifact revision differs from PR head' >&2; exit 1; }
[[ "$digest" == "$(bash "$(dirname "$0")/site-static-digest.sh" "$release_dir")" ]] || { echo 'preview artifact digest is invalid' >&2; exit 1; }
[[ "$app_digest" == "$(sha256sum "$release_dir/app.js" | awk '{print $1}')" ]] || { echo 'preview app digest is invalid' >&2; exit 1; }
