#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:-}"
revision="${2:-}"
[[ -d "$release_dir" ]] || { echo 'release directory is required' >&2; exit 2; }
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'site revision must be a full SHA-1' >&2; exit 2; }

# The manifest is intentionally excluded from its own digest. It identifies
# the exact static payload downloaded by the privileged publisher without
# requiring that publisher to execute any artifact code.
digest="$(bash "$(dirname "$0")/site-static-digest.sh" "$release_dir")"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'cannot calculate static site digest' >&2; exit 1; }
app_digest="$(sha256sum "$release_dir/app.js" | awk '{print $1}')"
[[ "$app_digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'cannot calculate app.js digest' >&2; exit 1; }

jq -cn --arg revision "$revision" --arg digest "$digest" --arg app_digest "$app_digest" \
  '{revision:$revision,artifactDigest:$digest,appDigest:$app_digest}' \
  | sed '1s/^/window.GDC_SITE_BUILD = /;$s/$/;/' >"$release_dir/site-build.js"
