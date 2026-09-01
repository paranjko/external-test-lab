#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
SITE_HOST="${GDC_SITE_HOST:-gonka-dev.net}"
GRAFANA_NETWORK_URL="${GDC_GRAFANA_NETWORK_URL:-https://grafana.gonka-dev.net/d/gdc-network/gonka-devnet-network?orgId=1&from=now-24h&to=now&timezone=utc&kiosk}"
GRAFANA_INFERENCE_URL="${GDC_GRAFANA_INFERENCE_URL:-https://grafana.gonka-dev.net/d/gdc-inference/gonka-devnet-inference?orgId=1&from=now-7d&to=now&timezone=utc&kiosk}"
RUN_ID="${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-homepage}"
OUT="${GDC_HOMEPAGE_EVIDENCE_DIR:-$GDC_HOME/runs/$RUN_ID-homepage}"
CHROME="${CHROME_BIN:-google-chrome}"
EXPECT_RESET_STATE="${GDC_EXPECT_RESET_STATE:-false}"
[[ "$EXPECT_RESET_STATE" =~ ^(true|false)$ ]] || { echo 'GDC_EXPECT_RESET_STATE must be true or false' >&2; exit 2; }
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
test "$(grep -o '<pre><code>' "$OUT/homepage.html" | wc -l)" -eq 1
grep -Fq '<section id="join-node"' "$OUT/homepage.html"
grep -Fq 'How to Join node' "$OUT/homepage.html"
grep -Fq 'alias gdc="$PWD/external-test-lab/net-deployment-runbook/gdc.sh"' "$OUT/homepage.html"
grep -Fq 'gdc host join --public-host &lt;IP_or_DOMAIN&gt; &lt;ssh-alias&gt;' "$OUT/homepage.html"
grep -Fq 'https://github.com/paranjko/external-test-lab/blob/main/net-deployment-runbook/ROLE-JOIN.md#join-add-a-host' "$OUT/homepage.html"
! grep -Eq 'curl-example|request-example' "$OUT/homepage.html"
grep -q 'The Telegram bot consumes inference and does not issue API keys' "$OUT/homepage.html"
if grep -q 'Keys are broker credentials' "$OUT/homepage.html"; then
  echo 'obsolete Telegram key-issuer copy is still present' >&2
  exit 1
fi
grep -q 'github.com/gonka-ai/gonka/discussions/1388' "$OUT/homepage.html"
grep -q 'Successful requests' "$OUT/homepage.html"
grep -q 'completed since gateway restart' "$OUT/homepage.html"
grep -q 'Rate-limited requests' "$OUT/homepage.html"
grep -q 'rejected since gateway restart' "$OUT/homepage.html"
! grep -q 'Accepted requests\|Limit rejections\|gateway process counter' "$OUT/homepage.html"
grep -q 'gateway-state.js' "$OUT/homepage.html"
curl -fsS "https://$SITE_HOST/gateway-state.js" -o "$OUT/gateway-state.js"
if [[ -n "${GDC_SITE_RENDERED_ASSETS:-}" ]]; then
  expected_gateway_state="$GDC_SITE_RENDERED_ASSETS/gateway-state.js"
  [[ -s "$expected_gateway_state" ]] || {
    echo "rendered site asset is missing: $expected_gateway_state" >&2
    exit 1
  }
else
  site_build="$(mktemp -d)"
  trap 'rm -rf "$site_build"' EXIT
  "$ROOT/scripts/build-site-js.sh" --output "$site_build"
  expected_gateway_state="$site_build/gateway-state.js"
fi
cmp "$expected_gateway_state" "$OUT/gateway-state.js"
curl -fsS "https://$SITE_HOST/status/gateway-health" -o "$OUT/gateway-health.json"
jq -e '
  def iso_epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  (((keys - ["recovery"]) | sort) == ["admission","admission_id","arrival_height","checked_at","curl_exit","dispatch_height","http_status","latency_ms","permit_height","reason","response_height","safe_generation","state"])
  and (.state == "READY" or .state == "DEGRADED" or .state == "UNAVAILABLE" or .state == "RECOVERING")
  and (.checked_at | iso_epoch > 0)
  and (.curl_exit | type == "number")
  and (.http_status | type == "number")
  and (.latency_ms | type == "number")
  and (.reason | type == "string")
  and (.admission == "not_observed" or .admission == "dispatched_once" or .admission == "pre_dispatch_rejected" or .admission == "dispatch_attempt_failed")
  and (.admission_id | type == "string")
  and (.safe_generation | type == "string")
  and (.arrival_height | type == "number")
  and (.permit_height | type == "number")
  and (.dispatch_height | type == "number")
  and (.response_height | type == "number")
  and (
    if .state == "RECOVERING" then
      (.recovery | type == "object")
      and (.recovery.stage | type == "string")
      and (.recovery.started_at | iso_epoch > 0)
      and (.recovery.next_check_seconds | type == "number")
    else
      (.recovery? == null)
    end
  )
' "$OUT/gateway-health.json" >/dev/null || die 'public gateway health response has an invalid schema'

curl -fsS "https://$SITE_HOST/config.js" | sed -e 's/^window.GDC_CONFIG = //' -e 's/;$//' >"$OUT/config.json"
if [[ "$EXPECT_RESET_STATE" == true ]]; then
  # The reset contract deliberately removes inferenced.  Caddy therefore has
  # no chain REST upstream for this one endpoint; represent that truth as an
  # empty participant set instead of treating it as a public-site outage.
  set +e
  participant_http_status="$(curl -sS -o "$OUT/participants.json" -w '%{http_code}' "https://$SITE_HOST/status/participants")"
  participant_curl_exit=$?
  set -e
  if [[ "$participant_curl_exit" != 0 || "$participant_http_status" != 502 ]]; then
    die "reset participant endpoint did not report the expected unavailable upstream: url=https://$SITE_HOST/status/participants http_status=${participant_http_status:-0} curl_exit=$participant_curl_exit curl_status=$(curl_exit_status "$participant_curl_exit")"
  fi
  printf 'INFO reset participant endpoint unavailable as expected: http_status=%s\n' "$participant_http_status"
  printf '{"participant":[]}\n' >"$OUT/participants.json"
else
  curl -fsS "https://$SITE_HOST/status/participants" >"$OUT/participants.json"
fi
live_participant_count="$(jq -er '[.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1")] | length' "$OUT/participants.json")"
if [[ "$EXPECT_RESET_STATE" != true ]]; then
  (( live_participant_count > 0 ))
fi
curl -fsS "https://$SITE_HOST/fonts/JetBrainsMono-Regular.woff2" -o "$OUT/JetBrainsMono-Regular.woff2"
test -s "$OUT/JetBrainsMono-Regular.woff2"
jq -e '
  (.nodeCatalog | type == "array")
  and all(.nodeCatalog[];
    (.ip | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))
    and (.geo.latitude | type == "number")
    and (.geo.longitude | type == "number")
  )
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

GDC_EXPECT_RESET_STATE="$EXPECT_RESET_STATE" CHROME_BIN="$CHROME" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 1440 900 "$OUT/homepage-1440x900.png" "$live_participant_count"
GDC_EXPECT_RESET_STATE="$EXPECT_RESET_STATE" GDC_CHECK_MAP_FULLSCREEN=true CHROME_BIN="$CHROME" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 390 844 "$OUT/homepage-390x844.png"
identify "$OUT/homepage-1440x900.png" | grep -q '1440x900'
identify "$OUT/homepage-390x844.png" | grep -q '390x844'

cat >"$OUT/finalize.md" <<EOF
# Public homepage: PASS

- Purpose: External Test Lab / Community DevNet.
- Initial topology: at least one active participant; disconnected nodes are
  omitted.
- Checks: live topology, native gateway metrics, Grafana, desktop and mobile browser contracts.
EOF
printf 'PASS public homepage contract evidence: %s\n' "$OUT"
