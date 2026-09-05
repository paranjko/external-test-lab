#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-public-homepage.sh"
OPS="$ROOT/scripts/phase-ops.sh"

grep -Fq 'GDC_SITE_RENDERED_ASSETS' "$VERIFY"
grep -Fq 'rendered site asset is missing' "$VERIFY"
grep -Fq 'expected_gateway_state="$GDC_SITE_RENDERED_ASSETS/gateway-state.js"' "$VERIFY"
grep -Fq 'GDC_SITE_RENDERED_ASSETS="$SITE_ASSETS_RENDER" "$ROOT/scripts/verify-public-homepage.sh"' "$OPS"
grep -Fq 'install -m 0644 "$OPS_RENDER/config.js" "$SITE_ASSETS_RENDER/config.js"' "$OPS"
! grep -Fq 'identify ' "$VERIFY"
grep -Fq 'screenshotBytes.readUInt32BE(16)' "$ROOT/scripts/capture-homepage-viewport.mjs"
grep -Fq 'screenshotBytes.readUInt32BE(20)' "$ROOT/scripts/capture-homepage-viewport.mjs"
grep -Fq 'screenshotWidth !== width || screenshotHeight !== height' "$ROOT/scripts/capture-homepage-viewport.mjs"

printf 'PASS public homepage verification uses the rendered deploy asset\n'
