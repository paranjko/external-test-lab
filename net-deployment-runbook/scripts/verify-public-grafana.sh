#!/usr/bin/env bash
set -Eeuo pipefail

verify_expected_target_result() {
  local host="$1" validator="$2"
  jq -e --arg host "$host" --arg validator "$validator" '
    .status == "success"
    and ([.data.result[] | select(.metric.host == $host and (.value[1] | tonumber) == 1)
      | if $validator == "" then true else .metric.validator == $validator end] | any)
  '
}

verify_linked_gpu_result() {
  local host="$1"
  jq -e --arg host "$host" '
    .status == "success" and ([.data.result[] | select(.metric.host == $host)] | length > 0)
  '
}

verify_linked_gpu_freshness_result() {
  local host="$1"
  jq -e --arg host "$host" '
    .status == "success" and ([.data.result[] | select(.metric.host == $host and (.value[1] | tonumber) <= 120)] | any)
  '
}

# The target predicates are intentionally importable for deterministic negative
# tests. The normal verifier always continues into the live public checks.
if [[ "${GDC_GRAFANA_VERIFIER_LIBRARY:-false}" == true ]]; then
  return 0 2>/dev/null || exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_project

RUN="${GDC_GRAFANA_EVIDENCE_DIR:-$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}-public-grafana}"
NETWORK_URL="${GDC_PUBLIC_GRAFANA_URL:-https://$GRAFANA_HOST/d/gdc-network/gonka-devnet-network?orgId=1&from=now-24h&to=now&timezone=utc&kiosk}"
INFERENCE_URL="https://$GRAFANA_HOST/d/gdc-inference/gonka-devnet-inference?orgId=1&from=now-7d&to=now&timezone=utc&kiosk"
mkdir -p "$RUN"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  health_tmp="$RUN/health.tmp"
  health_status='000'
  health_rc=0
  health_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$health_tmp" -w '%{http_code}' "https://$GRAFANA_HOST/api/health" 2>/dev/null)" || health_rc=$?
  if [[ "$health_rc" == 0 && "$health_status" == 200 ]] \
    && jq -e '.database == "ok"' "$health_tmp" >/dev/null 2>&1; then
    mv "$health_tmp" "$RUN/health.json"
    break
  fi
  rm -f "$health_tmp"
  printf 'WAIT  public Grafana health url=https://%s/api/health http_status=%s curl_exit=%s curl_status=%s\n' \
    "$GRAFANA_HOST" "$health_status" "$health_rc" "$(curl_exit_status "$health_rc")"
  sleep 3
done
test -s "$RUN/health.json" || die 'public Grafana did not become healthy'

prom_query() {
  local expression="$1" encoded
  encoded="$(printf '%s' "$expression" | base64 -w0)"
  ssh -T "$GATEWAY_NODE" "query=\$(printf %s '$encoded' | base64 -d); curl -fsSG --data-urlencode query=\"\$query\" http://127.0.0.1:9099/api/v1/query"
}

expected_targets="$RUN/expected-targets.tsv"
: >"$expected_targets"
for node in "${GDC_NODES[@]}"; do
  printf '%s\t\n' "$node" >>"$expected_targets"
done
for node in "${GDC_NODES[@]}"; do
  ml_host="$(node_ml_host "$node" || true)"
  [[ -z "$ml_host" ]] || printf '%s\t%s\n' "$ml_host" "$node" >>"$expected_targets"
done

while IFS=$'\t' read -r host validator; do
  target_result="$(prom_query "up{job=\"host\",host=\"$host\"}")"
  verify_expected_target_result "$host" "$validator" <<<"$target_result" >/dev/null \
    || die "expected Prometheus target is down or mislabeled: $host"
done <"$expected_targets"

while IFS=$'\t' read -r host validator; do
  [[ -n "$validator" ]] || continue
  gpu_result="$(prom_query "gdc_nvidia_memory_total_bytes{host=\"$host\"}")"
  verify_linked_gpu_result "$host" <<<"$gpu_result" >/dev/null \
    || die "linked GPU inventory is missing: $host"
  # PromQL string literals reject a single backslash before a dot. A character
  # class expresses the literal dot without adding another escaping layer.
  freshness_result="$(prom_query "time() - max by(host) (node_textfile_mtime_seconds{host=\"$host\",file=~\".*nvidia[.]prom\"})")"
  verify_linked_gpu_freshness_result "$host" <<<"$freshness_result" >/dev/null \
    || die "linked GPU inventory is stale: $host"
done <"$expected_targets"

for dashboard in gdc-network gdc-inference; do
  curl -fsS "https://$GRAFANA_HOST/api/dashboards/uid/$dashboard" >"$RUN/$dashboard.json"
  jq -e --arg dashboard "$dashboard" '.dashboard.uid == $dashboard and ([.dashboard.panels[]? | select(.targets? != null)] | length >= 20) and ([.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)] | length >= 20)' "$RUN/$dashboard.json" >/dev/null || die "public Grafana dashboard $dashboard is incomplete"
done
jq -r '.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)' "$RUN/gdc-network.json" "$RUN/gdc-inference.json" | sort -u >"$RUN/panel-expressions.txt"
while IFS= read -r expression; do printf '%s' "$expression" | base64 -w0; printf '\n'; done <"$RUN/panel-expressions.txt" >"$RUN/panel-expressions.b64"
panel_deadline=$((SECONDS + 180))
panel_data_ready=false
missing_expression=''
while (( SECONDS < panel_deadline )); do
  ssh -T "$GATEWAY_NODE" 'while IFS= read -r encoded; do
    query="$(printf %s "$encoded" | base64 -d)"
    result="$(curl -fsSG --data-urlencode query="$query" http://127.0.0.1:9099/api/v1/query)"
    printf "%s\t%s\n" "$encoded" "$(printf %s "$result" | base64 -w0)"
  done' <"$RUN/panel-expressions.b64" >"$RUN/panel-results.b64"
  missing_expression=''
  while IFS=$'\t' read -r encoded result_encoded; do
    expression="$(printf '%s' "$encoded" | base64 -d)"
    result="$(printf '%s' "$result_encoded" | base64 -d)"
    if ! jq -e '.status == "success" and (.data.result | length > 0)' <<<"$result" >/dev/null; then
      missing_expression="$expression"
      break
    fi
  done <"$RUN/panel-results.b64"
  if [[ -z "$missing_expression" ]]; then
    panel_data_ready=true
    break
  fi
  printf 'WAIT  public Grafana panel data after datasource restart: %s\n' "$missing_expression"
  sleep 3
done
[[ "$panel_data_ready" == true ]] || die "public Grafana panel expression returned no Prometheus data: $missing_expression"

command -v google-chrome >/dev/null || die 'google-chrome is required to validate public Grafana rendering'
BROWSER_RENDER_TIMEOUT_SECONDS="${GDC_PUBLIC_GRAFANA_BROWSER_TIMEOUT_SECONDS:-45}"
[[ "$BROWSER_RENDER_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || die 'GDC_PUBLIC_GRAFANA_BROWSER_TIMEOUT_SECONDS must be a positive integer'
GRAFANA_BROWSER_READY_WAIT_SECONDS="${GDC_PUBLIC_GRAFANA_BROWSER_READY_WAIT_SECONDS:-600}"
[[ "$GRAFANA_BROWSER_READY_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || die 'GDC_PUBLIC_GRAFANA_BROWSER_READY_WAIT_SECONDS must be a positive integer'
browser_profile="$(mktemp -d)"
trap 'rm -rf "$browser_profile"' EXIT
browser_deadline=$((SECONDS + GRAFANA_BROWSER_READY_WAIT_SECONDS))
browser_ready=false
browser_failure=''
while (( SECONDS < browser_deadline )); do
  network_chrome_rc=0
  inference_chrome_rc=0
  timeout --kill-after=5s "${BROWSER_RENDER_TIMEOUT_SECONDS}s" google-chrome --headless=new --no-sandbox --disable-gpu \
    --disable-background-networking --disable-component-update --disable-sync --no-first-run --no-default-browser-check \
    --user-data-dir="$browser_profile" --virtual-time-budget=12000 --window-size=1440,1000 --dump-dom "$NETWORK_URL" \
    >"$RUN/gdc-network-dom.html" 2>"$RUN/gdc-network-chrome.stderr" || network_chrome_rc=$?
  timeout --kill-after=5s "${BROWSER_RENDER_TIMEOUT_SECONDS}s" google-chrome --headless=new --no-sandbox --disable-gpu \
    --disable-background-networking --disable-component-update --disable-sync --no-first-run --no-default-browser-check \
    --user-data-dir="$browser_profile" --virtual-time-budget=12000 --window-size=1440,1000 --dump-dom "$INFERENCE_URL" \
    >"$RUN/gdc-inference-dom.html" 2>"$RUN/gdc-inference-chrome.stderr" || inference_chrome_rc=$?
  browser_failure=''
  for dashboard in gdc-network gdc-inference; do
    case "$dashboard" in
      gdc-network) chrome_rc="${network_chrome_rc:-125}" ;;
      gdc-inference) chrome_rc="${inference_chrome_rc:-125}" ;;
    esac
    if [[ "$chrome_rc" != 0 ]]; then
      browser_failure="$dashboard chrome_exit=$chrome_rc isolated_profile=true"
      break
    fi
    if grep -Eqi 'no data|panel plugin not found|unauthorized|sign in to grafana' "$RUN/$dashboard-dom.html"; then
      browser_failure="$dashboard"
      break
    fi
  done
  if [[ -z "$browser_failure" ]]; then
    browser_ready=true
    break
  fi
  printf 'WAIT  public Grafana browser render dashboard=%s; retrying before deadline=%ss\n' \
    "$browser_failure" "$((browser_deadline - SECONDS))"
  sleep 3
done
[[ "$browser_ready" == true ]] || die "public Grafana browser DOM reports a data, panel, or authentication failure on $browser_failure"
grep -q 'Gonka DevNet Network' "$RUN/gdc-network-dom.html" || die 'public Grafana browser DOM did not render the network dashboard'
grep -q 'Gonka DevNet Inference' "$RUN/gdc-inference-dom.html" || die 'public Grafana browser DOM did not render the inference dashboard'
cat >"$RUN/finalize.md" <<EOF
# Public Grafana: PASS

- Network: $NETWORK_URL
- Inference: $INFERENCE_URL
- Dashboards: gdc-network, gdc-inference
- Expected Prometheus targets: $(wc -l <"$expected_targets") are up; linked GPU inventory is fresh.
- Prometheus panel expressions: $(wc -l <"$RUN/panel-expressions.txt") returned live data.
- Browser DOM contains both rendered dashboards and no No data, plugin, or authentication failure.
EOF
printf 'PASS public Grafana: %s\n' "$RUN"
