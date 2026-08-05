#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_HOST="${GDC_SITE_HOST:-gonka-dev.net}"
GRAFANA_URL="${GDC_GRAFANA_URL:-https://grafana.gonka-dev.net/d/gdc-overview/gonka-devnet-community-overview?orgId=1&from=now-6h&to=now}"
RUN_ID="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-homepage}"
OUT="${GDC_HOMEPAGE_EVIDENCE_DIR:-$ROOT/artifacts/runs/$RUN_ID-homepage}"
CHROME="${CHROME_BIN:-google-chrome}"
mkdir -p "$OUT"

command -v "$CHROME" >/dev/null || { echo 'google-chrome is required for homepage visual evidence' >&2; exit 1; }
curl -fsS "https://$SITE_HOST/" -o "$OUT/homepage.html"
grep -q 'EXTERNAL TEST LAB' "$OUT/homepage.html"
grep -q 'Test network changes' "$OUT/homepage.html"
grep -q 'contract.css' "$OUT/homepage.html"
grep -q 'readability.css' "$OUT/homepage.html"
grep -q 'JetBrainsMono-Regular.woff2' "$OUT/homepage.html"
! grep -q '<span class="mark">G</span>GONKA' "$OUT/homepage.html"
! grep -q '<nav class="topbar"' "$OUT/homepage.html"
! grep -q '—' "$OUT/homepage.html"
! grep -qi 'LIVE DEVNET CHECK\|active endpoints online\|gateway-summary' "$OUT/homepage.html"
! grep -q 'Live status' "$OUT/homepage.html"
test "$(grep -o 'grafana.gonka-dev.net/d/gdc-overview' "$OUT/homepage.html" | wc -l)" -eq 1
! grep -qi 'proxy\.gonka\.gg\|node0\.gonka-dev\.net:3000' "$OUT/homepage.html"
! grep -Eq '<(pre|code)([[:space:]>])|curl-example|request-example' "$OUT/homepage.html"
grep -q 'github.com/gonka-ai/gonka/discussions/1388' "$OUT/homepage.html"

curl -fsS "https://$SITE_HOST/config.js" | sed -e 's/^window.GDC_CONFIG = //' -e 's/;$//' >"$OUT/config.json"
curl -fsS "https://$SITE_HOST/fonts/JetBrainsMono-Regular.woff2" -o "$OUT/JetBrainsMono-Regular.woff2"
test -s "$OUT/JetBrainsMono-Regular.woff2"
jq -e '
  (.nodes | length == 5)
  and (.nodes[] | select(.name == "gdc-node3" and .mode == "skip"))
  and ([.nodes[] | select(.mode == "active")] | length == 4)
' "$OUT/config.json" >/dev/null

curl -fsS "$GRAFANA_URL" -o "$OUT/grafana.html"
grep -qi '<!doctype html>' "$OUT/grafana.html"
curl -fsS 'https://grafana.gonka-dev.net/api/dashboards/uid/gdc-overview' | jq -e '.dashboard.title == "Gonka DevNet Community Overview"' >"$OUT/grafana-dashboard.json"
curl -fsS "https://$SITE_HOST/meter-api/health" | jq -e '.status == "ok" or .ok == true' >"$OUT/meter-health.json"
curl -fsS "https://$SITE_HOST/meter-api/metrics/dashboard/detail" >"$OUT/gateway-quality.json"
jq -e '
  .aggregate.api_uptime_pct >= 0
  and .aggregate.latency_s >= 0
  and .aggregate.output_speed_tps >= 0
  and .aggregate.real_world_gen_pct >= 0
  and ([.providers[0].metrics[].key] as $keys | ["api_uptime", "failed_probes", "latency", "output_speed", "real_world_gen"] | all(. as $key | $keys | index($key)))
  and (.providers[0].metrics[] | select(.key == "real_world_gen") | .raw.capability_matrix | type == "array")
' "$OUT/gateway-quality.json" >/dev/null
! grep -Eqi 'token price|price comparison|real spend|cost per' "$OUT/homepage.html"

CHROME_BIN="$CHROME" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 1440 900 "$OUT/homepage-1440x900.png" 5
CHROME_BIN="$CHROME" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 390 844 "$OUT/homepage-390x844.png"
identify "$OUT/homepage-1440x900.png" | grep -q '1440x900'
identify "$OUT/homepage-390x844.png" | grep -q '390x844'

cat >"$OUT/finalize.md" <<EOF
# Public homepage: PASS

- Purpose: External Test Lab / Community DevNet.
- Initial topology: four active participants and explicit gdc-node3 SKIP.
- Checks: live topology, Grafana, G-Meter, desktop and mobile browser contracts.
EOF
printf 'PASS public homepage contract evidence: %s\n' "$OUT"
