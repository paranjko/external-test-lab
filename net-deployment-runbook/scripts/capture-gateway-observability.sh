#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 5 ]] || {
  echo 'Usage: capture-gateway-observability.sh OUT_DIR CHAIN_BASE GATEWAY_URL HEIGHT LABEL' >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/host-sync-verdict.sh"
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

declare -a curl_topology_resolve=()
append_tls_transport() {
  local host="$1" alias="$2" transport_ip
  transport_ip="$(ssh -G "$alias" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
  if [[ "$transport_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    curl_topology_resolve+=(--resolve "$host:443:$transport_ip")
  fi
}
append_tls_transport "$API_HOST" "$PUBLIC_EDGE_NODE"
append_tls_transport "$SITE_HOST" "$PUBLIC_EDGE_NODE"
append_tls_transport "$GRAFANA_HOST" "$PUBLIC_EDGE_NODE"
for node in "${GDC_NODES[@]}"; do
  append_tls_transport "$(node_public_host "$node")" "$node"
done

curl_dns_retry() {
  local command="$1" attempt=0 rc stderr
  shift
  while true; do
    stderr="$(mktemp)"
    set +e
    if [[ "$command" == curl ]]; then
      "$command" "${curl_topology_resolve[@]}" "$@" 2>"$stderr"
    else
      "$command" "$@" 2>"$stderr"
    fi
    rc=$?
    set -e
    if (( rc == 0 )); then
      rm -f "$stderr"
      return 0
    fi
    # A transient local resolver timeout is not an endpoint observation. Retry
    # it twice, then preserve the failure instead of synthesizing a snapshot.
    if ! { (( rc == 6 || rc == 28 )); } || (( attempt >= 2 )); then
      cat "$stderr" >&2
      rm -f "$stderr"
      return "$rc"
    fi
    rm -f "$stderr"
    attempt=$((attempt + 1))
    sleep 1
  done
}

prom_query() {
  local expression="$1" encoded
  encoded="$(printf '%s' "$expression" | base64 -w0)"
  ssh -T "$GATEWAY_NODE" "query=\$(printf %s '$encoded' | base64 -d); curl -fsSG --data-urlencode query=\"\$query\" http://127.0.0.1:9099/api/v1/query"
}

jq -n --arg captured_at "$(date -u +%FT%TZ)" --arg label "$label" --argjson height "$height" \
  '{captured_at:$captured_at,label:$label,height:$height}' >"$out/context.json"

gateway_status="$(curl_dns_retry curl -fsS --connect-timeout 5 --max-time 15 "$gateway_url/v1/status" -H "Authorization: Bearer $client_key")"
printf '%s\n' "$gateway_status" | jq . >"$out/gateway-status-raw.json"
gateway_status_routable=false
if printf '%s\n' "$gateway_status" | "$ROOT/04-ops/gateway-status-routable.sh"; then
  gateway_status_routable=true
fi
jq --argjson routable "$gateway_status_routable" '
  {routable:$routable, mode:(.mode // null), runtimes:(.runtimes // null),
   active:([.devshards[]? | select(.active == true) | {phase:(.runtime.phase // .phase // null),
     chain_phase:(.runtime.chain_phase // .chain_phase // null), requests_blocked:(.runtime.requests_blocked // .requests_blocked // false)}])}
' <<<"$gateway_status" >"$out/gateway-status.json"

public_health="$(curl_dns_retry curl -fsS --connect-timeout 5 --max-time 15 "https://$SITE_HOST/status/gateway-health")"
printf '%s\n' "$public_health" | jq . >"$out/public-health-raw.json"
printf '%s\n' "$public_health" | jq -e '
    def iso_epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    (((keys - ["recovery"]) | sort) == ["checked_at","curl_exit","http_status","latency_ms","reason","state"])
    and (.state == "READY" or .state == "DEGRADED" or .state == "UNAVAILABLE" or .state == "RECOVERING")
    and (.checked_at | iso_epoch > 0)
    and (.curl_exit | type == "number")
    and (.http_status | type == "number")
    and (.latency_ms | type == "number")
    and (.reason | type == "string")
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
  ' >"$out/public-health.json"

ssh -T "$GATEWAY_NODE" 'sudo jq "{state,reason,checked_at,current_balance,low_watermark,liabilities,target_balance}" /srv/dai/ops/status/gateway-reserve.json' \
  >"$out/reserve.json"
ssh -T "$GATEWAY_NODE" 'sudo jq "{state,reason,checked_at,entered_at,attempts}" /srv/dai/ops/status/gateway-reconciliation.json' \
  >"$out/reconciliation.json"

# Participant membership alone is not validator evidence. Capture voting
# power before the sequential progress samples so the value belongs to the
# requested observation boundary rather than a later lifecycle phase.
participants="$(curl_dns_retry curl -fsS --connect-timeout 5 --max-time 15 "$chain_base/chain-api/productscience/inference/inference/participant")"
validators="$(curl_dns_retry curl -fsS --connect-timeout 5 --max-time 15 "$chain_base/chain-rpc/validators?per_page=100")"
public_hosts=()
for node in "${GDC_NODES[@]}"; do public_hosts+=("$(node_public_host "$node")"); done
public_hosts_json="$(printf '%s\n' "${public_hosts[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
jq -n --argjson participants "$participants" --argjson validators "$validators" --argjson expected_hosts "$public_hosts_json" '
  $expected_hosts as $hosts
  | [ $hosts[] as $host
      | (($participants.participant[]? | select(.inference_url == ("https://" + $host))) // {}) as $participant
      | (($validators.result.validators[]? | select(.pub_key.value == $participant.validator_key)) // {}) as $validator
      | {host:$host, participant_status:($participant.status // null),
         voting_power:(($validator.voting_power // "0") | tonumber)}
    ]
' >"$out/validator-voting-power.json"
jq -e --argjson expected_count "${#GDC_NODES[@]}" '
  length == $expected_count and all(.[]; .participant_status == "ACTIVE" and .voting_power > 0)
' "$out/validator-voting-power.json" >/dev/null \
  || { echo 'every displayed Host must be ACTIVE with positive validator voting power' >&2; exit 1; }

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

host_progress_delay="${GDC_HOST_PROGRESS_SAMPLE_DELAY_SECONDS:-5}"
host_progress_timeout="${GDC_HOST_PROGRESS_SAMPLE_TIMEOUT_SECONDS:-30}"
host_block_max_age="${GDC_HOST_BLOCK_MAX_AGE_SECONDS:-90}"
[[ "$host_progress_delay" =~ ^[1-9][0-9]*$ && "$host_progress_timeout" =~ ^[1-9][0-9]*$ && "$host_block_max_age" =~ ^[1-9][0-9]*$ ]] \
  || { echo 'Host progress sample settings must be positive integers' >&2; exit 2; }
: >"$out/host-sync.jsonl"
declare -A observed_node_ids=()
for node in "${GDC_NODES[@]}"; do
  host="$(node_public_host "$node")"
  status_first="$(curl_dns_retry curl -fsS --connect-timeout 5 --max-time 15 "https://$host/chain-rpc/status")"
  first_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$status_first")"
  status="$status_first"
  node_height="$first_height"
  host_progress_deadline=$((SECONDS + host_progress_timeout))
  while (( node_height <= first_height && SECONDS < host_progress_deadline )); do
    sleep "$host_progress_delay"
    status="$(curl_dns_retry curl -fsS --connect-timeout 5 --max-time 15 "https://$host/chain-rpc/status")"
    node_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$status")"
  done
  # Compare this Host's second progress sample with a contemporaneous canonical reference.
  # A single reference captured before the sequential
  # Host loop would turn healthy later Hosts into artificial lag failures.
  central="$(curl_dns_retry curl -fsS --connect-timeout 5 --max-time 15 "$chain_base/chain-rpc/status")"
  local_status="$(ssh -T "$node" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status')"
  central_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' <<<"$central")"
  public_node_id="$(jq -er '.result.node_info.id | select(type == "string" and length > 0)' <<<"$status")"
  local_node_id="$(jq -er '.result.node_info.id | select(type == "string" and length > 0)' <<<"$local_status")"
  block_time="$(jq -er '.result.sync_info.latest_block_time | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' <<<"$status")"
  observed_at="$(date -u +%s)"
  catching="$(jq -r 'if (.result.sync_info | has("catching_up")) then .result.sync_info.catching_up else true end' <<<"$status")"
  [[ "$catching" =~ ^(true|false)$ ]] || { echo "Host has invalid catching_up state: $host" >&2; exit 1; }
  [[ "$public_node_id" == "$local_node_id" ]] || {
    echo "Host public chain RPC identity does not match local CometBFT: $host" >&2
    exit 1
  }
  [[ -z "${observed_node_ids[$public_node_id]:-}" ]] || {
    echo "Host public chain RPC identity is not unique: $host duplicates ${observed_node_ids[$public_node_id]}" >&2
    exit 1
  }
  observed_node_ids[$public_node_id]="$host"
  host_sync_record "$host" "$first_height" "$node_height" "$central_height" "$block_time" "$observed_at" "$catching" \
    | jq --arg node "$node" --arg public_node_id "$public_node_id" --arg local_node_id "$local_node_id" \
      '. + {node:$node,public_node_id:$public_node_id,local_node_id:$local_node_id,identity_matches:true}' \
    >>"$out/host-sync.jsonl"
  host_sync_accepts "$first_height" "$node_height" "$central_height" "$block_time" "$observed_at" "$catching" "$host_block_max_age" \
    || { echo "Host is not synchronized with fresh progress: $host" >&2; exit 1; }
done

curl_dns_retry curl -fsS "https://$SITE_HOST/status/gpus" | jq -e '
  .status == "success" and ([.data.result[]? | select(.metric.host == "gdc-node4-ml" and .metric.gpu_name == "NVIDIA RTX PRO 2000 Blackwell")] | any)
' >"$out/public-gpus.json"
site_code="$(curl_dns_retry curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "https://$SITE_HOST/" || true)"
[[ "$site_code" == 200 ]] || { echo "public site returned HTTP $site_code" >&2; exit 1; }

: >"$out/dashboard-results.jsonl"
for dashboard in gdc-network gdc-inference; do
  curl_dns_retry curl -fsS "https://$GRAFANA_HOST/api/dashboards/uid/$dashboard" >"$out/$dashboard.json"
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
