#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_project

RUN="${GDC_GRAFANA_EVIDENCE_DIR:-$ROOT/artifacts/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}-public-grafana}"
URL="${GDC_PUBLIC_GRAFANA_URL:-https://$GRAFANA_HOST/d/gdc-overview/gonka-devnet-community-overview?orgId=1&from=now-6h&to=now}"
mkdir -p "$RUN"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  if curl -fsS "https://$GRAFANA_HOST/api/health" | jq -e '.database == "ok"' >"$RUN/health.json" 2>/dev/null; then break; fi
  printf 'WAIT  public Grafana health\n'; sleep 3
done
test -s "$RUN/health.json" || die 'public Grafana did not become healthy'

curl -fsS "https://$GRAFANA_HOST/api/dashboards/uid/gdc-overview" >"$RUN/dashboard.json"
jq -e '.dashboard.uid == "gdc-overview" and ([.dashboard.panels[]? | select(.targets? != null)] | length >= 14) and ([.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)] | length > 0)' "$RUN/dashboard.json" >/dev/null || die 'public Grafana dashboard is incomplete'
jq -r '.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)' "$RUN/dashboard.json" | sort -u >"$RUN/panel-expressions.txt"
while IFS= read -r expression; do
  encoded="$(printf '%s' "$expression" | base64 -w0)"
  result="$(ssh -n gdc-node0 "query=\$(printf %s '$encoded' | base64 -d); curl -fsSG --data-urlencode query=\"\$query\" http://127.0.0.1:9099/api/v1/query")"
  jq -e '.status == "success" and (.data.result | length > 0)' <<<"$result" >/dev/null || die "public Grafana panel expression returned no Prometheus data: $expression"
done <"$RUN/panel-expressions.txt"

command -v google-chrome >/dev/null || die 'google-chrome is required to validate public Grafana rendering'
google-chrome --headless=new --no-sandbox --disable-gpu --virtual-time-budget=10000 --window-size=1440,1000 --dump-dom "$URL" >"$RUN/dashboard-dom.html" 2>"$RUN/chrome.stderr"
! grep -Eqi 'no data|panel plugin not found|unauthorized|sign in to grafana' "$RUN/dashboard-dom.html" || die 'public Grafana browser DOM reports unavailable panel data or authentication'
grep -q 'Gonka DevNet Community Overview' "$RUN/dashboard-dom.html" || die 'public Grafana browser DOM did not render the overview dashboard'
cat >"$RUN/finalize.md" <<EOF
# Public Grafana: PASS

- URL: $URL
- Dashboard: gdc-overview
- Prometheus panel expressions: $(wc -l <"$RUN/panel-expressions.txt") returned live data.
- Browser DOM contains the rendered dashboard and no No data/authentication state.
EOF
printf 'PASS public Grafana: %s\n' "$RUN"
