#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$root/scripts/prepare-isolated-site-preview-artifact.sh"

[[ -x "$builder" || -f "$builder" ]] || { echo 'isolated artifact builder is missing' >&2; exit 1; }
bash -n "$builder"
for required in \
  'build-frontend-artifact.sh' \
  'build-status-backend-image.sh' \
  'prepare-isolated-preview-runtime-config.sh' \
  'prepare-isolated-preview-composition.sh' \
  'verify-site-preview-artifact.sh'; do
  grep -Fq "$required" "$builder"
done
grep -Fq 'git -C "$source_repository" diff --name-only "$base_revision" "$revision"' "$builder"
grep -Fq 'SKIP no source-bound preview is required' "$builder"
grep -Fq 'frontend_revision="$(jq -r .static_revision' "$builder"
grep -Fq 'if [[ "$mode" == endpoint || "$mode" == combined ]]; then' "$builder"
grep -Fq 'renderer_config="$release_dir/config.js"' "$builder"
grep -Fq 'renderer_config="$backend_dir/rendered/config.js"' "$builder"
grep -Fq '"$runtime_config" "$release_dir" "$renderer_config"' "$builder"
grep -Fq 'release directory must be a new absolute safe path' "$builder"
grep -Fq 'backend directory must be a new absolute safe path' "$builder"

printf 'PASS isolated preview artifact builder binds frontend, config and backend stages\n'
