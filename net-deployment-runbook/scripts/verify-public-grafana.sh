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

# A served dashboard must be the committed definition. Grafana owns only the
# database id and the save counter; every other field is the provisioned file.
verify_dashboard_matches_source() {
  local source="$1"
  # Grafana writes numbers back in its own form (0.70 is served as 0.7), so
  # compare the two definitions as values, not as text.
  jq -e --slurpfile committed "$source" \
    '(.dashboard | del(.id, .version)) == ($committed[0] | del(.id, .version))' >/dev/null
}

# A pinned expression that is no longer on a board keeps the gate green while
# measuring nothing. Read the served definition, not the query result.
verify_required_expression_on_board() {
  local expression="$1"
  jq -e --arg e "$expression" '[.dashboard.panels[]?.targets[]?.expr] | index($e) != null'
}

# An operator must be able to tell a measured zero from a panel that measured
# nothing. A panel declares that it may legitimately be empty by carrying a
# noValue text, which is what a reader sees in its body. A description is
# documentation and does not excuse an empty result: otherwise the gate could be
# switched off one comment at a time.
dashboard_panel_inventory() {
  local dashboard="$1"
  jq -r --arg dashboard "$dashboard" '
    .dashboard.panels[]?
    | . as $panel
    | ($panel.fieldConfig.defaults.noValue // "") as $novalue
    | $panel.targets[]?
    | select((.expr // "") != "")
    | [$dashboard, ($panel.id | tostring), ($panel.title + " [" + (.refId // "A") + "]"),
       (if $novalue != "" then "explained" else "unexplained" end),
       .expr,
       (.expr | @base64)]
    | @tsv'
}

# Decide each panel from its own query result. A failed query is never an empty
# result: it is reported separately so a broken datasource can never be excused
# by a panel that happens to explain itself.
classify_panel_results() {
  local dashboard panel_id panel_title panel_state encoded_result result
  # Columns five and six carry the expression in plain and encoded form; the
  # classification needs neither, only the result that came back for them.
  while IFS=$'\t' read -r dashboard panel_id panel_title panel_state _ _ encoded_result; do
    if [[ -z "${encoded_result:-}" || "$encoded_result" == QUERY_FAILED ]]; then
      printf 'failed\t%s\t%s\t%s\n' "$dashboard" "$panel_id" "$panel_title"
      continue
    fi
    result="$(printf '%s' "$encoded_result" | base64 -d 2>/dev/null || printf 'invalid')"
    if ! jq -e '.status == "success"' <<<"$result" >/dev/null 2>&1; then
      printf 'failed\t%s\t%s\t%s\n' "$dashboard" "$panel_id" "$panel_title"
    elif jq -e '[.data.result[]? | (if has("value") then .value[1] else (.values[]? | .[1]) end)] | any(. != "NaN")' <<<"$result" >/dev/null 2>&1; then
      printf 'data\t%s\t%s\t%s\n' "$dashboard" "$panel_id" "$panel_title"
    elif [[ "$panel_state" == explained ]]; then
      printf 'explained\t%s\t%s\t%s\n' "$dashboard" "$panel_id" "$panel_title"
    else
      printf 'unexplained\t%s\t%s\t%s\n' "$dashboard" "$panel_id" "$panel_title"
    fi
  done
}

# ssh reads stdin; inside a while-read loop it would swallow the remaining lines.
prom_query() {
  local expression="$1" encoded
  encoded="$(printf '%s' "$expression" | base64 -w0)"
  ssh -T "$GATEWAY_NODE" "query=\$(printf %s '$encoded' | base64 -d); curl -fsSG --data-urlencode query=\"\$query\" http://127.0.0.1:9099/api/v1/query" </dev/null
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
INFERENCE_URL="https://$GRAFANA_HOST/d/gdc-inference/gonka-devnet-inference?orgId=1&from=now-24h&to=now&timezone=utc&kiosk"
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

# The public runtime serves provisioned files through a bind mount. A stale
# mount or a skipped reconcile keeps an older definition online while the
# repository already carries the new one; compare the served definition with
# the committed file before judging its panels.
for dashboard in gdc-network gdc-inference gdc-overview; do
  curl -fsS "https://$GRAFANA_HOST/api/dashboards/uid/$dashboard" >"$RUN/$dashboard.json"
  verify_dashboard_matches_source "$ROOT/04-ops/edge-node/public-grafana/dashboards/$dashboard.json" <"$RUN/$dashboard.json" \
    || die "public Grafana dashboard $dashboard differs from the committed definition"
done
for dashboard in gdc-network gdc-inference; do
  jq -e --arg dashboard "$dashboard" '.dashboard.uid == $dashboard and ([.dashboard.panels[]? | select(.targets? != null)] | length >= 20) and ([.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)] | length >= 20)' "$RUN/$dashboard.json" >/dev/null || die "public Grafana dashboard $dashboard is incomplete"
done
# A deployed dashboard must prove its collector, chain, Host, gateway and
# readiness sources. Request, executor and escrow series are intentionally
# optional: before the first routed completion they are absent rather than
# zero, and treating that absence as a Grafana deployment failure hides the
# operational distinction the board is intended to show. That tolerance is not
# unconditional: a panel may return nothing only if it says so itself, which is
# judged panel by panel below. The Telegram consumer is deliberately not pinned:
# its values are gated on an exporter that a network may not deploy at all.
cat >"$RUN/required-panel-expressions.txt" <<'EOF'
max(cometbft_consensus_height)
sum(up{job="gonka-node"})
100 - avg by(host)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100
max(up{job="gateway"})
time() - max(gdc_gateway_readiness_observed_timestamp_seconds)
max(devshard_gateway_capacity_scale) * 100
EOF
# A pinned expression that no longer appears on any board keeps this gate green
# while measuring nothing. Prove the pin before trusting the value it returns.
while IFS= read -r expression; do
  [[ -n "$expression" ]] || continue
  pinned_panel_found=false
  for dashboard in gdc-network gdc-inference gdc-overview; do
    if verify_required_expression_on_board "$expression" <"$RUN/$dashboard.json" >/dev/null; then
      pinned_panel_found=true
      break
    fi
  done
  [[ "$pinned_panel_found" == true ]] \
    || die "required panel expression is no longer on a served dashboard: $expression"
done <"$RUN/required-panel-expressions.txt"
# A visitor's board queries Prometheus through the anonymous public datasource
# proxy. The loopback check below cannot see a broken anonymous path, so read the
# same pinned expressions the way the public board reads them.
while IFS= read -r expression; do
  [[ -n "$expression" ]] || continue
  # A gateway restart makes its series briefly absent, so one shot would fail the
  # deploy for a reason that is not a Grafana fault.
  anonymous_deadline=$((SECONDS + 60))
  anonymous_answered=false
  anonymous_reachable=false
  while (( SECONDS < anonymous_deadline )); do
    if curl -fsSG --connect-timeout 5 --max-time 20 "https://$GRAFANA_HOST/api/datasources/proxy/uid/prometheus/api/v1/query" \
      --data-urlencode "query=$expression" >"$RUN/anonymous-probe.json" 2>/dev/null; then
      anonymous_reachable=true
      if jq -e '.status == "success" and (.data.result | length) > 0' "$RUN/anonymous-probe.json" >/dev/null; then
        anonymous_answered=true
        break
      fi
    fi
    sleep 5
  done
  if [[ "$anonymous_answered" != true ]]; then
    [[ "$anonymous_reachable" == true ]] \
      || die "anonymous public datasource proxy refused a pinned expression: $expression"
    die "anonymous public datasource proxy returned no result for: $expression"
  fi
done <"$RUN/required-panel-expressions.txt"
printf 'PASS anonymous public datasource proxy answers every pinned expression\n'
while IFS= read -r expression; do printf '%s' "$expression" | base64 -w0; printf '\n'; done <"$RUN/required-panel-expressions.txt" >"$RUN/panel-expressions.b64"
panel_deadline=$((SECONDS + 180))
panel_data_ready=false
missing_expression=''
while (( SECONDS < panel_deadline )); do
  ssh -T "$GATEWAY_NODE" 'while IFS= read -r encoded; do
    query="$(printf %s "$encoded" | base64 -d)"
    result="$(curl -fsSG --connect-timeout 5 --max-time 20 --data-urlencode query="$query" http://127.0.0.1:9099/api/v1/query)"
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

# Criterion: an operator must be able to tell a measured zero from a panel that
# measured nothing. A panel that returns no series is acceptable only when it
# declares that state with a noValue text; an undeclared empty panel is a
# deployment failure, whatever the browser renders.
: >"$RUN/panel-inventory.tsv"
for dashboard in gdc-network gdc-inference gdc-overview; do
  dashboard_panel_inventory "$dashboard" <"$RUN/$dashboard.json" >>"$RUN/panel-inventory.tsv"
done
cut -f6 "$RUN/panel-inventory.tsv" >"$RUN/panel-inventory.b64"
panel_inventory_lines="$(wc -l <"$RUN/panel-inventory.tsv" | tr -d ' ')"
# Series are late after a datasource restart; the pinned block above already
# waits for that. Give the whole board the same warm-up before calling a panel
# unmeasured, and re-read it every round rather than judging one snapshot.
judgement_deadline=$((SECONDS + 180))
judgement_ready=false
while (( SECONDS < judgement_deadline )); do
  ssh -T "$GATEWAY_NODE" 'while IFS= read -r encoded; do
  query="$(printf %s "$encoded" | base64 -d)"
  if result="$(curl -fsSG --connect-timeout 5 --max-time 20 --data-urlencode query="$query" http://127.0.0.1:9099/api/v1/query)"; then
    printf "%s\n" "$(printf %s "$result" | base64 -w0)"
  else
    printf "QUERY_FAILED\n"
  fi
done' <"$RUN/panel-inventory.b64" >"$RUN/panel-inventory-results.b64"
  # A short answer file would pair every panel with the wrong result and report
  # the whole board as unmeasured. Refuse to judge unless every panel answered.
  panel_result_lines="$(wc -l <"$RUN/panel-inventory-results.b64" | tr -d ' ')"
  [[ "$panel_inventory_lines" == "$panel_result_lines" ]] \
    || die "panel judgement queried $panel_inventory_lines panels and received $panel_result_lines answers"
  paste "$RUN/panel-inventory.tsv" "$RUN/panel-inventory-results.b64" \
    | classify_panel_results >"$RUN/panel-classification.tsv"
  awk -F'\t' '$1 == "unexplained"' "$RUN/panel-classification.tsv" >"$RUN/unexplained-empty-panels.txt"
  awk -F'\t' '$1 == "explained"' "$RUN/panel-classification.tsv" >"$RUN/explained-empty-panels.txt"
  awk -F'\t' '$1 == "failed"' "$RUN/panel-classification.tsv" >"$RUN/failed-panel-queries.txt"
  if [[ ! -s "$RUN/unexplained-empty-panels.txt" && ! -s "$RUN/failed-panel-queries.txt" ]]; then
    judgement_ready=true
    break
  fi
  printf 'WAIT  public Grafana panel judgement: %s unexplained, %s failed; retrying before deadline=%ss\n' \
    "$(wc -l <"$RUN/unexplained-empty-panels.txt" | tr -d ' ')" \
    "$(wc -l <"$RUN/failed-panel-queries.txt" | tr -d ' ')" \
    "$((judgement_deadline - SECONDS))"
  sleep 3
done
if [[ "$judgement_ready" != true ]]; then
  while IFS=$'\t' read -r _ dashboard panel_id panel_title; do
    printf 'FAIL  panel query never returned a result: %s %s %s\n' "$dashboard" "$panel_id" "$panel_title" >&2
  done <"$RUN/failed-panel-queries.txt"
  while IFS=$'\t' read -r _ dashboard panel_id panel_title; do
    printf 'FAIL  served panel returns no series and does not explain it: %s %s %s\n' "$dashboard" "$panel_id" "$panel_title" >&2
  done <"$RUN/unexplained-empty-panels.txt"
  [[ ! -s "$RUN/failed-panel-queries.txt" ]] \
    || die 'public Grafana could not query every served panel'
  die 'public Grafana serves a panel that measures nothing and says nothing'
fi
printf 'PASS every served panel returns data or explains its absence (%s explained)\n' \
  "$(wc -l <"$RUN/explained-empty-panels.txt" | tr -d ' ')"

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
    --user-data-dir="$browser_profile" --virtual-time-budget=12000 --window-size=1440,3600 --dump-dom "$NETWORK_URL" \
    >"$RUN/gdc-network-dom.html" 2>"$RUN/gdc-network-chrome.stderr" || network_chrome_rc=$?
  timeout --kill-after=5s "${BROWSER_RENDER_TIMEOUT_SECONDS}s" google-chrome --headless=new --no-sandbox --disable-gpu \
    --disable-background-networking --disable-component-update --disable-sync --no-first-run --no-default-browser-check \
    --user-data-dir="$browser_profile" --virtual-time-budget=12000 --window-size=1440,6400 --dump-dom "$INFERENCE_URL" \
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
    # Whether an empty panel renders the words "no data" or its own explanation is
    # a rendering detail; the panel judgement above already decided the question
    # against Prometheus. Here the DOM only has to prove the board rendered at all.
    if grep -Eqi 'panel plugin not found|unauthorized|sign in to grafana' "$RUN/$dashboard-dom.html"; then
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
- Dashboards: gdc-network, gdc-inference, gdc-overview match the committed definitions
- Expected Prometheus targets: $(wc -l <"$expected_targets") are up; linked GPU inventory is fresh.
- Prometheus panel expressions: $(wc -l <"$RUN/required-panel-expressions.txt") returned live data.
- Served panels: $(wc -l <"$RUN/panel-inventory.tsv") judged, $(wc -l <"$RUN/explained-empty-panels.txt") empty and explained, none empty and unexplained.
- Browser DOM contains both rendered dashboards and no plugin or authentication failure.
EOF
printf 'PASS public Grafana: %s\n' "$RUN"
