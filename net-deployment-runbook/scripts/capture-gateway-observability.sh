#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 5 ]] || {
  echo 'Usage: capture-gateway-observability.sh OUT_DIR CHAIN_BASE GATEWAY_URL HEIGHT LABEL' >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_project
load_public_observability_hosts

out="$1"
chain_base="${2%/}"
gateway_url="${3%/}"
height="$4"
label="$5"
[[ "$height" =~ ^[1-9][0-9]*$ ]] || { echo 'HEIGHT must be positive' >&2; exit 2; }
[[ "$label" =~ ^[a-z0-9-]+$ ]] || { echo 'LABEL must be lowercase, numeric, or hyphenated' >&2; exit 2; }
mkdir -p "$out"

client_key_file="$SECRETS/gateway.client-keys"
[[ -s "$client_key_file" ]] || { echo 'gateway assurance key is unavailable' >&2; exit 1; }
client_key="$(cut -d, -f1 "$client_key_file")"
[[ -n "$client_key" ]] || { echo 'gateway assurance key is empty' >&2; exit 1; }

prom_query() {
  local expression="$1" encoded
  encoded="$(printf '%s' "$expression" | base64 -w0)"
  ssh -T "$GATEWAY_NODE" "query=\$(printf %s '$encoded' | base64 -d); curl -fsSG --data-urlencode query=\"\$query\" http://127.0.0.1:9099/api/v1/query"
}

jq -n --arg captured_at "$(date -u +%FT%TZ)" --arg label "$label" --argjson height "$height" \
  '{captured_at:$captured_at,label:$label,height:$height}' >"$out/context.json"

gateway_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key")"
jq '
  {routable:(.routable // false), mode:(.mode // null), runtimes:(.runtimes // null),
   active:([.devshards[]? | select(.active == true) | {phase:(.runtime.phase // .phase // null),
     chain_phase:(.runtime.chain_phase // .chain_phase // null), requests_blocked:(.runtime.requests_blocked // .requests_blocked // false)}])}
' <<<"$gateway_status" >"$out/gateway-status.json"

curl -fsS --connect-timeout 5 --max-time 15 "https://$SITE_HOST/status/gateway-health" \
  | jq -e '
    (((keys - ["recovery"]) | sort) == ["checked_at","curl_exit","http_status","latency_ms","reason","state"])
    and (.state == "READY" or .state == "UNAVAILABLE" or .state == "RECOVERING")
    and (.checked_at | fromdateiso8601 > 0)
    and (.curl_exit | type == "number")
    and (.http_status | type == "number")
    and (.latency_ms | type == "number")
    and (.reason | type == "string")
    and (
      if .state == "RECOVERING" then
        (.recovery | type == "object")
        and (.recovery.stage | type == "string")
        and (.recovery.started_at | fromdateiso8601 > 0)
        and (.recovery.next_check_seconds | type == "number")
      else
        (.recovery? == null)
      end
    )
  ' >"$out/public-health.json"

ssh -T "$GATEWAY_NODE" 'sudo jq "{state,reason,checked_at,current_balance,low_watermark,liabilities,target_balance}" /srv/dai/ops/status/gateway-reserve.json' \
  >"$out/reserve.json"
ssh -T "$GATEWAY_NODE" 'sudo jq "{state,reason,checked_at,entered_at,attempts}" /srv/dai/ops/status/gateway-reconciliation.json' \
  >"$out/reconciliation.json"

expected="$out/expected-targets.tsv"
: >"$expected"
for node in "${GDC_NODES[@]}"; do printf '%s\t\n' "$node" >>"$expected"; done
for node in "${GDC_NODES[@]}"; do
  ml_host="$(node_ml_host "$node" || true)"
  [[ -z "$ml_host" ]] || printf '%s\t%s\n' "$ml_host" "$node" >>"$expected"
done

: >"$out/prometheus-targets.jsonl"
while IFS=$'\t' read -r host validator; do
  result="$(prom_query "up{job=\"host\",host=\"$host\"}")"
  jq -e --arg host "$host" --arg validator "$validator" '
    .status == "success" and ([.data.result[] | select(.metric.host == $host and (.value[1]|tonumber) == 1)
      | if $validator == "" then true else .metric.validator == $validator end] | any)
  ' <<<"$result" >/dev/null || { echo "expected Prometheus target is down or mislabeled: $host" >&2; exit 1; }
  jq -n --arg host "$host" --arg validator "$validator" '{host:$host,validator:$validator,up:true}' >>"$out/prometheus-targets.jsonl"
done <"$expected"

while IFS=$'\t' read -r host validator; do
  [[ -n "$validator" ]] || continue
  gpu="$(prom_query "gdc_nvidia_memory_total_bytes{host=\"$host\"}")"
  jq -e --arg host "$host" '.status == "success" and ([.data.result[] | select(.metric.host == $host)] | length > 0)' <<<"$gpu" >/dev/null \
    || { echo "linked GPU inventory is missing: $host" >&2; exit 1; }
  fresh="$(prom_query "time() - max by(host) (node_textfile_mtime_seconds{host=\"$host\",file=~\".*nvidia[.]prom\"})")"
  jq -e --arg host "$host" '.status == "success" and ([.data.result[] | select(.metric.host == $host and (.value[1]|tonumber) <= 120)] | any)' <<<"$fresh" >/dev/null \
    || { echo "linked GPU inventory is stale: $host" >&2; exit 1; }
done <"$expected"

central="$(curl -fsS "$chain_base/chain-rpc/status")"
central_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$central")"
: >"$out/host-sync.jsonl"
for node in "${GDC_NODES[@]}"; do
  host="$(node_public_host "$node")"
  status="$(curl -fsS --connect-timeout 5 --max-time 15 "https://$host/chain-rpc/status")"
  node_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$status")"
  catching="$(jq -r 'if (.result.sync_info | has("catching_up")) then .result.sync_info.catching_up else true end' <<<"$status")"
  [[ "$catching" =~ ^(true|false)$ ]] || { echo "Host has invalid catching_up state: $host" >&2; exit 1; }
  lag=$(( central_height - node_height )); (( lag < 0 )) && lag=$(( -lag ))
  jq -n --arg host "$host" --argjson height "$node_height" --argjson lag "$lag" --argjson catching_up "$catching" \
    '{host:$host,height:$height,lag:$lag,catching_up:$catching_up}' >>"$out/host-sync.jsonl"
  (( lag <= 5 )) && [[ "$catching" == false ]] || { echo "Host is not synchronized: $host" >&2; exit 1; }
done

curl -fsS "https://$SITE_HOST/status/gpus" | jq -e '
  .status == "success" and ([.data.result[]? | select(.metric.host == "gdc-node4-ml" and .metric.gpu_name == "NVIDIA RTX PRO 2000 Blackwell")] | any)
' >"$out/public-gpus.json"
site_code="$(curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "https://$SITE_HOST/" || true)"
[[ "$site_code" == 200 ]] || { echo "public site returned HTTP $site_code" >&2; exit 1; }

: >"$out/dashboard-results.jsonl"
for dashboard in gdc-network gdc-inference; do
  curl -fsS "https://$GRAFANA_HOST/api/dashboards/uid/$dashboard" >"$out/$dashboard.json"
  jq -r '.dashboard.panels[]?.targets[]?.expr | select(type == "string" and length > 0)' "$out/$dashboard.json" | sort -u \
    | while IFS= read -r expression; do
        result="$(prom_query "$expression")"
        count="$(jq -er '.status == "success" and (.data.result|length > 0) | if . then 1 else 0 end' <<<"$result")"
        [[ "$count" == 1 ]] || { echo "dashboard expression returned no data: $dashboard" >&2; exit 1; }
        jq -n --arg dashboard "$dashboard" --arg expression "$expression" '{dashboard:$dashboard,expression:$expression,result_nonempty:true}' >>"$out/dashboard-results.jsonl"
      done
done

jq -n --arg captured_at "$(date -u +%FT%TZ)" --arg label "$label" --argjson height "$height" \
  '{verdict:"PASS",captured_at:$captured_at,label:$label,height:$height}' >"$out/finalize.json"
printf 'PASS continuity observability snapshot: %s\n' "$out"
