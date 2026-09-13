#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:-}"
origin="${2:-}"
release_dir="${release_dir%/}"
[[ -d "$release_dir" ]] || { echo 'release directory is required' >&2; exit 2; }
[[ "$origin" =~ ^https?://[^/]+$ ]] || { echo 'site origin is invalid' >&2; exit 2; }
wait_seconds="${GDC_SITE_RELEASE_VERIFY_WAIT_SECONDS:-30}"
[[ "$wait_seconds" =~ ^[1-9][0-9]*$ ]] || { echo 'release verification wait must be a positive number of seconds' >&2; exit 2; }

manifest="$release_dir/site-build.js"
[[ -s "$manifest" ]] || { echo 'site build manifest is required' >&2; exit 1; }
expected_digest="$(sed -n 's/.*"artifactDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$manifest")"
[[ -n "$expected_digest" ]] || { echo 'site build manifest has no payload digest' >&2; exit 1; }
[[ "$expected_digest" == "$(bash "$(dirname "$0")/site-static-digest.sh" "$release_dir")" ]] || {
  echo 'site build manifest does not describe the local static payload' >&2
  exit 1
}

last_failure='site release did not return a matching static payload'
verify_static_payload() {
  local actual expected file relative
  while IFS= read -r -d '' file; do
    relative="${file#"$release_dir/"}"
    [[ "$relative" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$relative" != *..* ]] || {
      last_failure="unsafe static artifact path: $relative"
      return 1
    }
    expected="$(sha256sum "$file" | awk '{print $1}')"
    if ! actual="$(curl --fail --silent -H 'Cache-Control: no-cache' "$origin/$relative" | sha256sum | awk '{print $1}')"; then
      last_failure="published static file is not available yet: $relative"
      return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
      last_failure="published static file differs: $relative"
      return 1
    fi
  done < <(find "$release_dir" -type f -print0 | LC_ALL=C sort -z)
}

deadline=$((SECONDS + wait_seconds))
attempt=1
until verify_static_payload; do
  if (( SECONDS >= deadline )); then
    echo "site release verification did not converge after ${wait_seconds}s: $last_failure" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done
printf 'PASS static site release matched local payload after %s attempt(s)\n' "$attempt"
