#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/make" "$tmp/scripts" "$tmp/04-ops/site"
cp "$root/make/site.mk" "$tmp/make/site.mk"
printf '%s\n' "\$(error GDC Makefile must not be loaded by site CI)" > "$tmp/Makefile"
cat > "$tmp/scripts/verify-devnet-hardware-profile.mjs" <<'JS'
import assert from 'node:assert/strict';
assert.deepEqual(process.argv.slice(2), ['profiles/devnet-hadware.json', '04-ops/site/index.html']);
console.log('PASS standalone site target runs without the GDC Makefile');
JS
make --no-print-directory -C "$tmp" -f make/site.mk site-host-requirements-check
# Verify recipe equivalence for both operator entrypoints without invoking publication
for target in site-js test-gateway-site-state prepare-static-site publish-site-release prepare-isolated-preview-ci-artifact; do
  make --no-print-directory -C "$root" -n "$target" > "$tmp/shared"
  make --no-print-directory -C "$root" -f make/site.mk -n "$target" > "$tmp/site"
  cmp "$tmp/shared" "$tmp/site"
done
for workflow in site-preview-build site-publish; do
  mapfile -t patterns < <(sed -n "s/^      - '\(.*\)'$/\1/p" "$root/../.github/workflows/$workflow.yml")
  ((${#patterns[@]} > 0))
  matches() {
    local pattern
    for pattern in "${patterns[@]}"; do
      # GitHub paths use glob patterns, these fixtures exercise exact paths and **
      # shellcheck disable=SC2254 # Match workflow globs, not literal strings
      case "$1" in $pattern) return 0 ;; esac
    done
    return 1
  }
  for file in net-deployment-runbook/Makefile net-deployment-runbook/02-node/render-node-config.sh model/qwen3-4b-instruct-2507-devnet.lock; do
    if matches "$file"; then echo "Unexpected site workflow for $file" >&2; exit 1; fi
  done
  matches net-deployment-runbook/make/site.mk
  matches net-deployment-runbook/04-ops/site/src/app.js
done
for case in none static; do
  if [[ $case == none ]]; then printf '%s\n' net-deployment-runbook/Makefile > "$tmp/files";
  else printf '%s\n' net-deployment-runbook/make/site.mk > "$tmp/files"; fi
  python3 "$root/scripts/plan-site-preview.py" --files "$tmp/files" \
    --base aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --repository-root "$root/.." --output "$tmp/plan.json"
  jq -e --arg mode "$case" '.mode == $mode' "$tmp/plan.json" >/dev/null
done
printf '%s\n' 'PASS site recipes, workflow path selection and preview classification are isolated from GDC changes'
