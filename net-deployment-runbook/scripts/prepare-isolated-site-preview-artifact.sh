#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare one immutable preview artifact from a Git object. The publisher sees
# only the completed directory and never executes its contents.

source_repository="${1:-}"
release_dir="${2:-}"
base_revision="${3:-}"
revision="${4:-}"
inventory="${5:-}"
preview_number="${6:-}"
backend_dir="${7:-}"
backend_image="${8:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository_root="$(cd "$root/.." && pwd)"
frontend_builder="$repository_root/ops/preview/build-frontend-artifact.sh"
backend_builder="$repository_root/ops/preview/build-status-backend-image.sh"
runtime_config="$root/scripts/prepare-isolated-preview-runtime-config.sh"
composition_builder="$root/scripts/prepare-isolated-preview-composition.sh"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }

git -C "$source_repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'source repository is not a Git checkout'
for candidate in "$base_revision" "$revision"; do
  [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || die 'base and head revisions must be full SHA-1 values'
  git -C "$source_repository" cat-file -e "$candidate^{commit}" || die 'requested revision is unavailable'
done
[[ -f "$inventory" && ! -L "$inventory" ]] || die 'safe renderer inventory is unavailable'
[[ "$preview_number" =~ ^[1-9][0-9]*$ ]] || die 'preview number must be positive'
[[ "$release_dir" = /* && "$release_dir" != / && "$release_dir" != *..* && ! -e "$release_dir" ]] || die 'release directory must be a new absolute safe path'

tmp_root="$(dirname "$release_dir")/.preview-composition"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/${preview_number}.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

git -C "$source_repository" diff --name-only "$base_revision" "$revision" | LC_ALL=C sort >"$tmp/changed-files.txt"
"$root/scripts/plan-site-preview.py" \
  --files "$tmp/changed-files.txt" \
  --base "$base_revision" \
  --head "$revision" \
  --output "$tmp/preview-composition.json" \
  --repository-root "$root" \
  --endpoint-input "$root/04-ops/edge-node/PublicCaddyfile" \
  --endpoint-input "$root/04-ops/render-ops.sh"
mode="$(jq -r .mode "$tmp/preview-composition.json")"
if [[ "$mode" == none ]]; then
  printf 'SKIP no source-bound preview is required\n'
  exit 0
fi
[[ "$mode" =~ ^(static|endpoint|combined)$ ]] || die 'preview composition mode is invalid'
frontend_revision="$(jq -r .static_revision "$tmp/preview-composition.json")"
[[ "$frontend_revision" =~ ^[0-9a-f]{40}$ ]] || die 'preview frontend revision is invalid'

"$frontend_builder" "$source_repository" "$frontend_revision" "$release_dir"
renderer_config="$release_dir/config.js"
if [[ "$mode" == endpoint || "$mode" == combined ]]; then
  [[ "$backend_dir" = /* && "$backend_dir" != / && "$backend_dir" != *..* && ! -e "$backend_dir" ]] \
    || die 'backend directory must be a new absolute safe path'
  [[ "$backend_image" =~ ^[a-z0-9][a-z0-9._/-]*:[a-z0-9][a-z0-9._-]*$ ]] || die 'backend image reference is invalid'
  "$backend_builder" "$source_repository" "$inventory" "$revision" "$preview_number" "$backend_dir" "$backend_image"
  renderer_config="$backend_dir/rendered/config.js"
else
  renderer_dir="$tmp/renderer"
  "$source_repository/net-deployment-runbook/04-ops/render-ops.sh" --inventory "$inventory" --output-dir "$renderer_dir"
  renderer_config="$renderer_dir/config.js"
fi
cp -p "$tmp/changed-files.txt" "$release_dir/preview-changed-files.txt"
cp -p "$tmp/preview-composition.json" "$release_dir/preview-composition.json"
"$runtime_config" "$release_dir" "$renderer_config" "$preview_number" "$revision" "$inventory.receipt.json"
"$root/scripts/render-site-build-info.sh" "$release_dir" "$revision"
"$composition_builder" "$release_dir" "$revision" "$backend_dir"

"$root/scripts/verify-site-preview-artifact.sh" "$release_dir" "$revision"
printf 'PASS prepared isolated source-bound preview artifact pr=%s revision=%s frontend=%s mode=%s\n' "$preview_number" "$revision" "$frontend_revision" "$mode"
