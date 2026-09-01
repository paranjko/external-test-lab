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
wait_seconds="${GDC_SITE_PREVIEW_VERIFY_WAIT_SECONDS:-30}"
[[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] || { echo 'preview verification wait must be a positive number of seconds' >&2; exit 2; }

manifest="$release_dir/site-build.js"
expected_digest="$(sed -n 's/.*"artifactDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$manifest")"
[[ "$expected_digest" == "$(bash "$(dirname "$0")/site-static-digest.sh" "$release_dir")" ]] || exit 1

last_failure='preview did not return a matching payload'
verify_live_payload() {
  local actual expected file live relative
  if ! live="$(curl --fail --silent -H 'Cache-Control: no-cache' "$origin/$prefix/site-build.js")"; then
    last_failure='site build manifest is not available yet'
    return 1
  fi
  if ! grep -Fq "\"revision\":\"$expected_revision\"" <<<"$live"; then
    last_failure='site build manifest does not contain the expected revision'
    return 1
  fi
  if ! grep -Fq "\"artifactDigest\":\"$expected_digest\"" <<<"$live"; then
    last_failure='site build manifest does not contain the expected payload digest'
    return 1
  fi
  while IFS= read -r -d '' file; do
    relative="${file#"$release_dir/"}"
    [[ "$relative" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$relative" != *..* ]] || {
      last_failure="unsafe static artifact path: $relative"
      return 1
    }
    expected="$(sha256sum "$file" | awk '{print $1}')"
    if ! actual="$(curl --fail --silent -H 'Cache-Control: no-cache' "$origin/$prefix/$relative" | sha256sum | awk '{print $1}')"; then
      last_failure="published file is not available yet: $relative"
      return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
      last_failure="published file differs: $relative"
      return 1
    fi
  done < <(find "$release_dir" -type f ! -name site-build.js -print0 | LC_ALL=C sort -z)
}

deadline=$((SECONDS + wait_seconds))
attempt=1
until verify_live_payload; do
  if (( SECONDS >= deadline )); then
    echo "preview verification did not converge after ${wait_seconds}s: $last_failure" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done
printf 'PASS preview payload converged after %s attempt(s)\n' "$attempt"
