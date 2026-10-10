#!/usr/bin/env bash
# Read-only Community DevNet topology and component observer.
#
# The public site deliberately observes the network from bootstrap seeds and
# their P2P peers.  Participant records are identities and can be historical;
# they are not the inventory of running Hosts.
set -Eeuo pipefail
umask 077

STATE_DIR="${GDC_NETWORK_OBSERVATION_STATE_DIR:-/var/lib/gonka-network-observer}"
STATE_FILE="$STATE_DIR/network.json"
BOOTSTRAP_URL="${GDC_NETWORK_BOOTSTRAP_URL:-https://gonka-dev.net/gonka-devnet-community/bootstrap.json}"
CHAIN_ID="${GDC_NETWORK_CHAIN_ID:-gonka-devnet-community}"

die() { printf '%s\n' "$*" >&2; exit 1; }
timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

rpc_base() { printf '%s\n' "${1%/chain-rpc}"; }
rpc_host() {
  local host="${1#*://}"
  host="${host%%/*}"
  printf '%s\n' "${host%%:*}"
}

node_name() {
  local host
  host="$(rpc_host "$1")"
  printf '%s\n' "${host%%.*}"
}

http_json() {
  curl -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 "$1"
}

network_error() {
  local value="$1"
  if [[ "$value" =~ returned\ error:\ ([0-9]{3}) ]]; then
    printf 'HTTP %s\n' "${BASH_REMATCH[1]}"
  elif [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf 'unknown_error\n'
  fi
}

component() {
  local kind="$1" dapi_url="$2" response observed_at error endpoint value
  observed_at="$(timestamp)"
  case "$kind" in
    versions)
      endpoint="${dapi_url%/}/v1/versions"
      if ! response="$(http_json "$endpoint" 2>&1)"; then
        error="$(network_error "$response")"
      elif ! value="$(jq -cer '
        select(type == "object" and (.api_version | type) == "object" and (.node_version | type) == "object") |
        {api_version, node_version, source_timestamp:(.timestamp // null)} +
        (if (.mlnodes|type)=="array" then {mlnodes} else {} end)
      ' <<<"$response")"; then
        error=invalid_versions_response
      else
        jq -cn --arg endpoint "$endpoint" --arg observed_at "$observed_at" --argjson value "$value" \
          '{state:"observed",source_endpoint:$endpoint,observed_at:$observed_at}+ $value'
        return
      fi
      ;;
    chain_rpc)
      endpoint="${dapi_url%/}/chain-rpc/status"
      if ! response="$(http_json "$endpoint" 2>&1)"; then
        error="$(network_error "$response")"
      elif ! value="$(jq -cer '
        .result | {
          p2p_node_id:.node_info.id, chain_id:.node_info.network,
          validator_address:(.validator_info.address // null),
          cometbft_version:.node_info.version,
          latest_block_height:(.sync_info.latest_block_height | tonumber?),
          latest_block_time:.sync_info.latest_block_time, catching_up:.sync_info.catching_up
        } | select(
          (.p2p_node_id|type)=="string" and (.chain_id|type)=="string" and
          (.cometbft_version|type)=="string" and (.latest_block_height|type)=="number" and
          (.latest_block_time|type)=="string" and (.catching_up|type)=="boolean"
        )
      ' <<<"$response")"; then
        error=invalid_status_response
      else
        jq -cn --arg endpoint "$endpoint" --arg observed_at "$observed_at" --argjson value "$value" \
          '{state:"observed",source_endpoint:$endpoint,observed_at:$observed_at}+ $value'
        return
      fi
      ;;
    inferenced)
      endpoint="${dapi_url%/}/chain-api/cosmos/base/tendermint/v1beta1/node_info"
      if ! response="$(http_json "$endpoint" 2>&1)"; then
        error="$(network_error "$response")"
      elif ! value="$(jq -cer '
        .application_version | {application_name:(.name // .app_name),version,commit:.git_commit,go_version:(.go_version // null)} |
        select((.application_name|type)=="string" and (.version|type)=="string" and (.commit|type)=="string")
      ' <<<"$response")"; then
        error=invalid_node_info_response
      else
        jq -cn --arg endpoint "$endpoint" --arg observed_at "$observed_at" --argjson value "$value" \
          '{state:"observed",source_endpoint:$endpoint,observed_at:$observed_at}+ $value'
        return
      fi
      ;;
    devshard)
      endpoint="${dapi_url%/}/devshard/healthz"
      if ! response="$(http_json "$endpoint" 2>&1)"; then
        error="$(network_error "$response")"
      elif ! value="$(jq -cer 'select(type == "array") | {runtimes:.}' <<<"$response")"; then
        error=invalid_devshard_health_response
      else
        jq -cn --arg endpoint "$endpoint" --arg observed_at "$observed_at" --argjson value "$value" \
          '{state:"observed",source_endpoint:$endpoint,observed_at:$observed_at}+ $value'
        return
      fi
      ;;
    *) die "unknown component: $kind" ;;
  esac
  jq -cn --arg endpoint "$endpoint" --arg observed_at "$observed_at" --arg error "$error" \
    '{state:"unavailable",source_endpoint:$endpoint,observed_at:$observed_at,error:$error}'
}

enrich_node() {
  local node="$1" dapi_url versions chain_rpc inferenced devshard
  dapi_url="$(jq -r '.dapi_url // empty' <<<"$node")"
  if [[ -z "$dapi_url" ]]; then
    jq -c '. + {components:{versions:{state:"not_exposed",error:"missing_dapi_url"},chain_rpc:{state:"not_exposed",error:"missing_dapi_url"},inferenced:{state:"not_exposed",error:"missing_dapi_url"},devshard:{state:"not_exposed",error:"missing_dapi_url"}}}' <<<"$node"
    return
  fi
  versions="$(component versions "$dapi_url")"
  chain_rpc="$(component chain_rpc "$dapi_url")"
  inferenced="$(component inferenced "$dapi_url")"
  devshard="$(component devshard "$dapi_url")"
  jq -cn --argjson node "$node" --argjson versions "$versions" --argjson chain_rpc "$chain_rpc" --argjson inferenced "$inferenced" --argjson devshard "$devshard" \
    '$node + {components:{versions:$versions,chain_rpc:$chain_rpc,inferenced:$inferenced,devshard:$devshard}}'
}

collect_nodes() {
  local bootstrap seeds seed_id seed_rpc net_info error host name dapi records
  bootstrap="$(http_json "$BOOTSTRAP_URL")" || die "bootstrap_unavailable"
  seeds="$(jq -cer '
    .seeds | select(type == "array" and length > 0 and length <= 32) |
    [ .[] | select((.node_id|type)=="string" and (.node_id|test("^[0-9a-f]{40}$")) and (.rpc|type)=="string" and (.rpc|test("^https?://[^/?#]+/chain-rpc$"))) ] |
    select(length > 0)
  ' <<<"$bootstrap")" || die "invalid_bootstrap"
  records="$(mktemp)"
  while IFS=$'\t' read -r seed_id seed_rpc; do
    host="$(rpc_host "$seed_rpc")"
    name="$(node_name "$seed_rpc")"
    dapi="$(rpc_base "$seed_rpc")"
    if net_info="$(http_json "${seed_rpc%/}/net_info" 2>&1)"; then
      jq -cer --arg node_id "$seed_id" --arg node_name "$name" --arg dapi_url "$dapi" '
        {node_id:$node_id,node_name:$node_name,url:null,dapi_url:$dapi_url,priority:0,active:true},
        (.result.peers[]? | select(
          (.node_info.id|type)=="string" and (.node_info.id|test("^[0-9a-f]{40}$")) and
          (.node_info.listen_addr|type)=="string" and (.remote_ip|type)=="string"
        ) | (.node_info.listen_addr | sub("^tcp://";"") | split(":")[0]) as $peer_host |
        {node_id:.node_info.id,node_name:($peer_host|split(".")[0]),url:("http://" + .remote_ip + ":8000"),dapi_url:(if $peer_host == "" then null else "https://" + $peer_host end),priority:1,active:true})
      ' <<<"$net_info" >>"$records"
    else
      error="$(network_error "$net_info")"
      jq -cn --arg node_id "$seed_id" --arg node_name "$name" --arg dapi_url "$dapi" --arg error "$error" \
        '{node_id:$node_id,node_name:$node_name,url:null,dapi_url:$dapi_url,priority:0,active:false,error:$error}' >>"$records"
    fi
  done < <(jq -r '.[] | [.node_id,.rpc] | @tsv' <<<"$seeds")
  jq -sc '[
    group_by(.node_id)[] | . as $records | ($records|sort_by(.priority)) as $preferred |
    ($records|map(.active)|any) as $active |
    ($preferred|map(select(.node_name != ""))|.[0].node_name // null) as $name |
    ($preferred|map(select(.dapi_url != null and .dapi_url != ""))|.[0].dapi_url // null) as $dapi |
    ($preferred|map(select(.url != null and .url != ""))|.[0].url // null) as $url |
    if $active then {node_id:$records[0].node_id,node_name:$name,url:$url,dapi_url:$dapi,priority:$preferred[0].priority,active:true}
    else {node_id:$records[0].node_id,node_name:$name,url:$url,dapi_url:$dapi,priority:$preferred[0].priority,active:false,error:($preferred|map(select(.error? != null))|.[0].error // "unknown_error")}
    end
  ]
  ' "$records"
  rm -f -- "$records"
}

collect() {
  local nodes dir index node output observed_at
  nodes="$(collect_nodes)" || return 1
  jq -e 'type == "array" and length > 0' <<<"$nodes" >/dev/null || return 1
  dir="$(mktemp -d)"
  index=0
  while IFS= read -r node; do
    enrich_node "$node" >"$dir/$index.json" &
    index=$((index + 1))
  done < <(jq -c '.[]' <<<"$nodes")
  wait
  output="$(jq -sc '
    map(select(type == "object")) |
    group_by(.components.chain_rpc.p2p_node_id // .node_id) |
    map(sort_by(.priority) | .[0] | del(.priority)) |
    sort_by(.node_name // "", .node_id)
  ' "$dir"/*.json)"
  observed_at="$(timestamp)"
  rm -rf -- "$dir"
  jq -cn --arg chain_id "$CHAIN_ID" --arg observed_at "$observed_at" --arg bootstrap_url "$BOOTSTRAP_URL" --argjson nodes "$output" \
    '{schema_version:1,chain_id:$chain_id,observed_at:$observed_at,bootstrap_url:$bootstrap_url,nodes:$nodes}'
}

refresh() {
  local temporary
  temporary="$(mktemp "$STATE_DIR/network.json.XXXXXX")"
  if collect >"$temporary"; then
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$STATE_FILE"
  else
    rm -f -- "$temporary"
    return 1
  fi
}

respond() {
  local status="$1" body="$2"
  printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: %s\r\n\r\n%s' \
    "$status" "$(LC_ALL=C printf %s "$body" | wc -c)" "$body"
}

serve() {
  local request method target version extra headers_done=false body
  IFS= read -r -t 3 request || exit 0
  request="${request%$'\r'}"
  read -r method target version extra <<<"$request"
  if [[ -n "${extra:-}" || ! "${version:-}" =~ ^HTTP/1\.[01]$ || "${#request}" -gt 4096 ]]; then respond '400 Bad Request' '{"error":"invalid_request"}'; return; fi
  if [[ "$method" != GET ]]; then respond '405 Method Not Allowed' '{"error":"read_only"}'; return; fi
  if [[ "${target%%\?*}" != /status/network ]]; then respond '404 Not Found' '{"error":"not_found"}'; return; fi
  for ((count=0;count<64;count++)); do
    IFS= read -r -t 3 header || break
    [[ "${#header}" -le 8192 ]] || break
    if [[ -z "${header%$'\r'}" ]]; then headers_done=true; break; fi
  done
  [[ "$headers_done" == true ]] || { respond '400 Bad Request' '{"error":"invalid_headers"}'; return; }
  if [[ -r "$STATE_FILE" ]] && body="$(cat "$STATE_FILE")" && jq -e '.schema_version == 1 and (.nodes | type == "array")' <<<"$body" >/dev/null; then
    respond '200 OK' "$body"
  else
    respond '503 Service Unavailable' '{"error":"network_observation_unavailable"}'
  fi
}

case "${1:-}" in
  --collect) collect ;;
  --refresh) refresh ;;
  --serve) serve ;;
  *) die "Usage: $0 --collect|--refresh|--serve" ;;
esac
