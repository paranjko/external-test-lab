#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$root/scripts/prepare-isolated-preview-ci-artifact.sh"
verifier="$root/scripts/verify-isolated-preview-ci-artifact.sh"
workflow="$root/../.github/workflows/site-preview-publish.yml"
build_workflow="$root/../.github/workflows/site-preview-build.yml"

for file in "$builder" "$verifier"; do
  [[ -x "$file" ]] || { echo "missing executable CI artifact helper: $file" >&2; exit 1; }
  bash -n "$file"
done
grep -Fq 'prepare-isolated-preview-ci.sh' "$builder"
grep -Fq 'SKIP no source-bound preview artifact was produced' "$builder"
grep -Fq 'docker image save' "$builder"
grep -Fq 'docker image save "$backend_image"' "$builder"
grep -Fq 'backend-image.tar.sha256' "$builder"
grep -Fq 'verify-site-preview-artifact.sh' "$verifier"
grep -Fq 'docker image load -i' "$verifier"
grep -Fq 'download-artifact@v8.0.1' "$workflow"
grep -Fq 'verify-isolated-preview-ci-artifact' "$workflow"
grep -Fq 'prepare-isolated-preview-ci-artifact' "$build_workflow"
grep -Fq 'fetch-depth: 0' "$build_workflow"
if grep -Eq 'path: source|ref: \$\{\{ needs\.publish-context\.outputs\.head_sha \}\}' "$workflow"; then
  echo 'trusted publication workflow must not checkout untrusted PR source' >&2
  exit 1
fi
printf 'PASS CI transfers a verified artifact without a privileged PR checkout\n'
