#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_project

RUN="${GDC_GRAFANA_EVIDENCE_DIR:-$ROOT/artifacts/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}-public-grafana}"
NETWORK_URL="${GDC_PUBLIC_GRAFANA_URL:-https://$GRAFANA_HOST/d/gdc-network/gonka-devnet-network?orgId=1&from=now-24h&to=now&timezone=utc&kiosk}"
INFERENCE_URL="https://$GRAFANA_HOST/d/gdc-inference/gonka-devnet-inference?orgId=1&from=now-7d&to=now&timezone=utc&kiosk"
mkdir -p "$RUN"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  if curl -fsS "https://$GRAFANA_HOST/api/health" | jq -e '.database == "ok"' >"$RUN/health.json" 2>/dev/null; then break; fi
  printf 'WAIT  public Grafana health\n'; sleep 3
done
test -s "$RUN/health.json" || die 'public Grafana did not become healthy'

for dashboard in gdc-network gdc-inference; do
  curl -fsS "https://$GRAFANA_HOST/api/dashboards/uid/$dashboard" >"$RUN/$dashboard.json"
  jq -e --arg dashboard "$dashboard" '.dashboard.uid == $dashboard and ([.dashboard.panels[]? | select(.targets? != null)] | length >= 20) and ([.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)] | length >= 20)' "$RUN/$dashboard.json" >/dev/null || die "public Grafana dashboard $dashboard is incomplete"
done
jq -r '.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)' "$RUN/gdc-network.json" "$RUN/gdc-inference.json" | sort -u >"$RUN/panel-expressions.txt"
while IFS= read -r expression; do printf '%s' "$expression" | base64 -w0; printf '\n'; done <"$RUN/panel-expressions.txt" >"$RUN/panel-expressions.b64"
ssh -T gdc-node0 'while IFS= read -r encoded; do
  query="$(printf %s "$encoded" | base64 -d)"
  result="$(curl -fsSG --data-urlencode query="$query" http://127.0.0.1:9099/api/v1/query)"
  printf "%s\t%s\n" "$encoded" "$(printf %s "$result" | base64 -w0)"
done' <"$RUN/panel-expressions.b64" >"$RUN/panel-results.b64"
while IFS=$'\t' read -r encoded result_encoded; do
  expression="$(printf '%s' "$encoded" | base64 -d)"
  result="$(printf '%s' "$result_encoded" | base64 -d)"
  jq -e '.status == "success" and (.data.result | length > 0)' <<<"$result" >/dev/null || die "public Grafana panel expression returned no Prometheus data: $expression"
done <"$RUN/panel-results.b64"

command -v google-chrome >/dev/null || die 'google-chrome is required to validate public Grafana rendering'
google-chrome --headless=new --no-sandbox --disable-gpu --virtual-time-budget=12000 --window-size=1440,1000 --dump-dom "$NETWORK_URL" >"$RUN/gdc-network-dom.html" 2>"$RUN/gdc-network-chrome.stderr"
google-chrome --headless=new --no-sandbox --disable-gpu --virtual-time-budget=12000 --window-size=1440,1000 --dump-dom "$INFERENCE_URL" >"$RUN/gdc-inference-dom.html" 2>"$RUN/gdc-inference-chrome.stderr"
for dashboard in gdc-network gdc-inference; do
  ! grep -Eqi 'no data|panel plugin not found|unauthorized|sign in to grafana' "$RUN/$dashboard-dom.html" || die "public Grafana browser DOM reports a data, panel, or authentication failure on $dashboard"
done
grep -q 'Gonka DevNet Network' "$RUN/gdc-network-dom.html" || die 'public Grafana browser DOM did not render the network dashboard'
grep -q 'Gonka DevNet Inference' "$RUN/gdc-inference-dom.html" || die 'public Grafana browser DOM did not render the inference dashboard'
cat >"$RUN/finalize.md" <<EOF
# Public Grafana: PASS

- Network: $NETWORK_URL
- Inference: $INFERENCE_URL
- Dashboards: gdc-network, gdc-inference
- Prometheus panel expressions: $(wc -l <"$RUN/panel-expressions.txt") returned live data.
- Browser DOM contains both rendered dashboards and no No data, plugin, or authentication failure.
EOF
printf 'PASS public Grafana: %s\n' "$RUN"
