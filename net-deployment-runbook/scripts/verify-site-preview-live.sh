#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:-}"
prefix="${2:-}"
expected_revision="${3:-}"
origin="${4:-}"
[[ -d "$release_dir" ]] || { echo 'release directory is required' >&2; exit 2; }
[[ "$prefix" =~ ^preview/[1-9][0-9]*$ ]] || { echo 'preview path is invalid' >&2; exit 2; }
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'preview revision must be a full SHA-1' >&2; exit 2; }
[[ "$origin" =~ ^https?://[^/]+$ ]] || { echo 'site origin is invalid' >&2; exit 2; }

manifest="$release_dir/site-build.js"
expected_digest="$(sed -n 's/.*"artifactDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$manifest")"
[[ "$expected_digest" == "$(bash "$(dirname "$0")/site-static-digest.sh" "$release_dir")" ]] || exit 1
live="$(curl --fail --silent --show-error -H 'Cache-Control: no-cache' "$origin/$prefix/site-build.js")"
grep -Fq "\"revision\":\"$expected_revision\"" <<<"$live"
grep -Fq "\"artifactDigest\":\"$expected_digest\"" <<<"$live"
while IFS= read -r -d '' file; do
  relative="${file#"$release_dir/"}"
  [[ "$relative" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$relative" != *..* ]] || {
    echo "unsafe static artifact path: $relative" >&2
    exit 1
  }
  expected="$(sha256sum "$file" | awk '{print $1}')"
  actual="$(curl --fail --silent --show-error -H 'Cache-Control: no-cache' "$origin/$prefix/$relative" | sha256sum | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "published file differs: $relative" >&2; exit 1; }
done < <(find "$release_dir" -type f ! -name site-build.js -print0 | LC_ALL=C sort -z)
