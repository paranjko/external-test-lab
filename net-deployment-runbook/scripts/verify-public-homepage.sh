#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_HOST="${GDC_SITE_HOST:-gonka-dev.net}"
GRAFANA_NETWORK_URL="${GDC_GRAFANA_NETWORK_URL:-https://grafana.gonka-dev.net/d/gdc-network/gonka-devnet-network?orgId=1&from=now-24h&to=now&timezone=utc&kiosk}"
GRAFANA_INFERENCE_URL="${GDC_GRAFANA_INFERENCE_URL:-https://grafana.gonka-dev.net/d/gdc-inference/gonka-devnet-inference?orgId=1&from=now-7d&to=now&timezone=utc&kiosk}"
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
test "$(grep -o 'grafana.gonka-dev.net/d/gdc-network' "$OUT/homepage.html" | wc -l)" -eq 1
test "$(grep -o 'grafana.gonka-dev.net/d/gdc-inference' "$OUT/homepage.html" | wc -l)" -eq 1
! grep -qi 'proxy\.gonka\.gg\|node0\.gonka-dev\.net:3000' "$OUT/homepage.html"
! grep -Eq '<(pre|code)([[:space:]>])|curl-example|request-example' "$OUT/homepage.html"
grep -q 'github.com/gonka-ai/gonka/discussions/1388' "$OUT/homepage.html"
grep -q 'Successful requests' "$OUT/homepage.html"
grep -q 'completed since gateway restart' "$OUT/homepage.html"
grep -q 'Rate-limited requests' "$OUT/homepage.html"
grep -q 'rejected since gateway restart' "$OUT/homepage.html"
! grep -q 'Accepted requests\|Limit rejections\|gateway process counter' "$OUT/homepage.html"
grep -q 'gateway-state.js' "$OUT/homepage.html"
curl -fsS "https://$SITE_HOST/gateway-state.js" -o "$OUT/gateway-state.js"
cmp "$ROOT/04-ops/site/gateway-state.js" "$OUT/gateway-state.js"
curl -fsS "https://$SITE_HOST/status/gateway-health" -o "$OUT/gateway-health.json"
jq -e '
  ((keys | sort) == ["checked_at","http_status","latency_ms","reason","state"])
  and (.state == "READY" or .state == "UNAVAILABLE" or .state == "RECOVERING")
  and (.checked_at | fromdateiso8601 > 0)
  and (.http_status | type == "number")
  and (.latency_ms | type == "number")
  and (.reason | type == "string")
' "$OUT/gateway-health.json" >/dev/null

curl -fsS "https://$SITE_HOST/config.js" | sed -e 's/^window.GDC_CONFIG = //' -e 's/;$//' >"$OUT/config.json"
curl -fsS "https://$SITE_HOST/status/participants" >"$OUT/participants.json"
live_participant_count="$(jq -er '[.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1")] | length' "$OUT/participants.json")"
(( live_participant_count > 0 ))
curl -fsS "https://$SITE_HOST/fonts/JetBrainsMono-Regular.woff2" -o "$OUT/JetBrainsMono-Regular.woff2"
test -s "$OUT/JetBrainsMono-Regular.woff2"
jq -e '
  ([.nodes[] | select(.mode == "active")] | length >= 1)
  and ([.nodeCatalog[] | select((.ip | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.geo.latitude | type == "number") and (.geo.longitude | type == "number"))] | length >= 4)
  and (.grafanaNetwork | contains("/d/gdc-network/"))
  and (.grafanaInference | contains("/d/gdc-inference/"))
' "$OUT/config.json" >/dev/null

curl -fsS "$GRAFANA_NETWORK_URL" -o "$OUT/grafana-network.html"
curl -fsS "$GRAFANA_INFERENCE_URL" -o "$OUT/grafana-inference.html"
grep -qi '<!doctype html>' "$OUT/grafana-network.html"
grep -qi '<!doctype html>' "$OUT/grafana-inference.html"
curl -fsS 'https://grafana.gonka-dev.net/api/dashboards/uid/gdc-network' | jq -e '.dashboard.title == "Gonka DevNet Network"' >"$OUT/grafana-dashboard.json"
curl -fsS 'https://grafana.gonka-dev.net/api/dashboards/uid/gdc-inference' | jq -e '.dashboard.title == "Gonka DevNet Inference"' >"$OUT/grafana-inference-dashboard.json"
! grep -Eqi 'token price|price comparison|real spend|cost per' "$OUT/homepage.html"

CHROME_BIN="$CHROME" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 1440 900 "$OUT/homepage-1440x900.png" "$live_participant_count"
CHROME_BIN="$CHROME" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 390 844 "$OUT/homepage-390x844.png"
identify "$OUT/homepage-1440x900.png" | grep -q '1440x900'
identify "$OUT/homepage-390x844.png" | grep -q '390x844'

cat >"$OUT/finalize.md" <<EOF
# Public homepage: PASS

- Purpose: External Test Lab / Community DevNet.
- Initial topology: at least one active participant; disconnected nodes are
  omitted unless explicitly marked as SKIP.
- Checks: live topology, native gateway metrics, Grafana, desktop and mobile browser contracts.
EOF
printf 'PASS public homepage contract evidence: %s\n' "$OUT"
