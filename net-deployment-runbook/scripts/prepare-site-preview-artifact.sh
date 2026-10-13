#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${site_release_dir:?site_release_dir is required}"
base_revision="${preview_base_revision:?preview_base_revision is required}"
head_revision="${site_revision:?site_revision is required}"
[[ "$base_revision" =~ ^[0-9a-f]{40}$ && "$head_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'preview revisions must be full commit IDs' >&2
  exit 2
}
files="$release_dir/preview-changed-files.txt"
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$release_dir"
git diff --name-only "$base_revision" "$head_revision" | LC_ALL=C sort >"$files"
"$(dirname "$0")/plan-site-preview.py" \
  --files "$files" \
  --base "$base_revision" \
  --head "$head_revision" \
  --output "$release_dir/preview-composition.json" \
  --repository-root "$root" \
  --endpoint-input "$root/04-ops/edge-node/PublicCaddyfile" \
  --endpoint-input "$root/04-ops/render-ops.sh"
mode="$(jq -r .mode "$release_dir/preview-composition.json")"
[[ "$mode" != none ]] || { echo 'no preview-relevant paths changed' >&2; exit 1; }
make -C "$root" prepare-static-site site_release_dir="$release_dir" site_revision="$head_revision"
# Preview configuration and status responses are served by the real public
# origin at runtime.  Do not materialize a topology snapshot or a synthetic
# status API into a deployable preview artifact.
revision="$head_revision" "$(dirname "$0")/render-site-build-info.sh" "$release_dir" "$head_revision"
printf 'PASS preview artifact prepared mode=%s\n' "$mode"
