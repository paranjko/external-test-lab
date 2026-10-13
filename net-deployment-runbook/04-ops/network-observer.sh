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
NETWORKS_DIR="$STATE_DIR/networks"
REQUESTS_DIR="$STATE_DIR/requests"
GEO_DIR="$STATE_DIR/geo"
GEO_TTL_SECONDS="${GDC_NETWORK_GEO_TTL_SECONDS:-604800}"
GEO_MAX_LOOKUPS="${GDC_NETWORK_GEO_MAX_LOOKUPS:-12}"
BOOTSTRAP_URL="${GDC_NETWORK_BOOTSTRAP_URL:-https://gonka-dev.net/gonka-devnet-community/bootstrap.json}"
CHAIN_ID="${GDC_NETWORK_CHAIN_ID:-gonka-devnet-community}"
DEFAULT_CHAIN_ID="${GDC_NETWORK_DEFAULT_CHAIN_ID:-$CHAIN_ID}"
BOOTSTRAP_ORIGIN="${GDC_NETWORK_BOOTSTRAP_ORIGIN:-https://gonka-dev.net}"
CHAIN_API_ORIGIN="${GDC_NETWORK_CHAIN_API_ORIGIN:-}"
CHAIN_API_ORIGIN="${CHAIN_API_ORIGIN%/}"

die() { printf '%s\n' "$*" >&2; exit 1; }
timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

bootstrap_url_for() {
  local chain_id="$1" origin="${BOOTSTRAP_ORIGIN%/}"
  [[ "$chain_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid_chain_id'
  [[ "$origin" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]{0,253}$ ]] || die 'invalid_bootstrap_origin'
  printf '%s/%s/bootstrap.json\n' "$origin" "$chain_id"
}

valid_chain_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

network_state_file() {
  local chain_id="$1"
  valid_chain_id "$chain_id" || die 'invalid_chain_id'
  printf '%s/%s.json\n' "$NETWORKS_DIR" "$chain_id"
}

request_file() {
  local chain_id="$1"
  valid_chain_id "$chain_id" || die 'invalid_chain_id'
  printf '%s/%s\n' "$REQUESTS_DIR" "$chain_id"
}

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

validate_chain_api_origin() {
  local port
  [[ -n "$CHAIN_API_ORIGIN" ]] || return 0
  if [[ ! "$CHAIN_API_ORIGIN" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]{0,253}(:([1-9][0-9]{0,4}))?$ ]]; then
    die 'invalid_chain_api_origin'
  fi
  port="${BASH_REMATCH[3]:-}"
  [[ -z "$port" || "$port" -le 65535 ]] || die 'invalid_chain_api_origin'
}

validate_chain_api_network() {
  local status
  [[ -n "$CHAIN_API_ORIGIN" ]] || return 0
  status="$(http_json "$CHAIN_API_ORIGIN/chain-rpc/status" 2>/dev/null)" || {
    printf 'central_chain_api_unavailable\n' >&2
    return 1
  }
  jq -e --arg chain_id "$CHAIN_ID" '.result.node_info.network == $chain_id' <<<"$status" >/dev/null 2>&1 || {
    printf 'central_chain_api_chain_id_mismatch\n' >&2
    return 1
  }
}

chain_api_base() {
  local dapi_url="$1"
  if [[ -n "$CHAIN_API_ORIGIN" ]]; then
    printf '%s/chain-api/productscience/inference/inference\n' "$CHAIN_API_ORIGIN"
  else
    printf '%s/chain-api/productscience/inference/inference\n' "${dapi_url%/}"
  fi
}

chain_rpc_origin() {
  local dapi_url="$1"
  if [[ -n "$CHAIN_API_ORIGIN" ]]; then
    printf '%s\n' "$CHAIN_API_ORIGIN"
  else
    printf '%s\n' "${dapi_url%/}"
  fi
}

ipv4_from_url() {
  local url="$1" host
  host="$(rpc_host "$url")"
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s\n' "$host"
}

geo_for_ip() {
  local ip="$1" cache now modified response observed_at geo
  cache="$GEO_DIR/$ip.json"
  now="$(date +%s)"
  if [[ -r "$cache" ]]; then
    modified="$(date -r "$cache" +%s 2>/dev/null || printf 0)"
    if (( now - modified <= GEO_TTL_SECONDS )) &&
      jq -e 'type == "object" and (.latitude|type) == "number" and (.longitude|type) == "number"' "$cache" >/dev/null; then
      cat "$cache"
      return
    fi
  fi
  response="$(http_json "https://ipwho.is/$ip" 2>/dev/null || true)"
  observed_at="$(timestamp)"
  geo="$(jq -cer --arg ip "$ip" --arg observed_at "$observed_at" '
    select(.success == true) |
    (.latitude | tonumber?) as $latitude |
    (.longitude | tonumber?) as $longitude |
    select($latitude != null and $longitude != null) |
    {
      latitude:$latitude, longitude:$longitude,
      city:(.city // "Unknown"), country:(.country // "Unknown"),
      isp:(.connection.isp // "unknown"), source:"ip-geolocation",
      observedAt:$observed_at, accuracy:"city", resolvedIp:$ip,
      locationLabel:((.city // "Unknown") + ", " + (.country // "Unknown"))
    }
  ' <<<"$response" 2>/dev/null || true)"
  [[ -n "$geo" ]] || { printf 'null\n'; return; }
  mkdir -p "$GEO_DIR"
  printf '%s\n' "$geo" >"$cache"
  chmod 0644 "$cache"
  printf '%s\n' "$geo"
}

enrich_geo() {
  local node="$1" ip geo
  ip="$(ipv4_from_url "$(jq -r '.url // .dapi_url // empty' <<<"$node")" 2>/dev/null || true)"
  geo='null'
  if [[ -n "$ip" ]] && (( GEO_MAX_LOOKUPS > 0 )); then
    geo="$(geo_for_ip "$ip")"
  fi
  jq -cn --argjson node "$node" --argjson geo "$geo" '$node + {geo:$geo}'
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
          validator_voting_power:(.validator_info.voting_power // null),
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
    peers)
      endpoint="${dapi_url%/}/chain-rpc/net_info"
      if ! response="$(http_json "$endpoint" 2>&1)"; then
        error="$(network_error "$response")"
      elif ! value="$(jq -cer '
        (.result.n_peers | tonumber?) as $count |
        select(($count | type) == "number" and $count >= 0 and $count <= 100000 and ($count | floor) == $count) |
        {count:$count}
      ' <<<"$response")"; then
        error=invalid_net_info_response
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
        local versions_endpoint versions_response
        versions_endpoint="${dapi_url%/}/v1/versions"
        if versions_response="$(http_json "$versions_endpoint" 2>/dev/null)" &&
          value="$(jq -cer '
            .node_version | {
              application_name:(.application_name // .name // .app_name),version,
              commit:(.commit // .git_commit),go_version:(.go_version // null)
            } | select((.application_name|type)=="string" and (.version|type)=="string" and (.commit|type)=="string")
          ' <<<"$versions_response" 2>/dev/null)"; then
          jq -cn --arg endpoint "$versions_endpoint" --arg observed_at "$observed_at" --argjson value "$value" \
            '{state:"observed",source_endpoint:$endpoint,observed_at:$observed_at}+ $value'
          return
        fi
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
        local stats_endpoint stats_response stats stats_observed_at
        stats_endpoint="${dapi_url%/}/devshard/stats/shards"
        stats_observed_at="$(timestamp)"
        stats='null'
        if jq -e 'any(.[]; .status? == "running" and (.name? | if type == "string" then test("^v([4-9]|[1-9][0-9]+)([._-]|$)") else false end))' <<<"$response" >/dev/null 2>&1; then
          if ! stats_response="$(http_json "$stats_endpoint" 2>&1)"; then
            stats="$(jq -cn --arg endpoint "$stats_endpoint" --arg observed_at "$stats_observed_at" --arg error "$(network_error "$stats_response")" \
              '{state:"unavailable",source_endpoint:$endpoint,observed_at:$observed_at,error:$error}')"
          elif ! stats="$(jq -cer '
            select(type == "object") |
            (.current_epoch_id | tonumber?) as $epoch |
            (.cached_at | tonumber?) as $cached_at |
            (.cache_ttl_seconds | tonumber?) as $cache_ttl |
            select($epoch != null and $epoch >= 0 and $cached_at != null and $cached_at > 0 and
              $cache_ttl != null and $cache_ttl >= 0 and $cache_ttl <= 3600 and
              (.active_escrows | type) == "array" and (.active_escrows | length) <= 128 and
              (.shards | type) == "array" and (.shards | length) <= 128) |
            [ .active_escrows[] | tostring | select(test("^[0-9]+$")) ] as $escrows |
            [ .shards[] |
              (.escrow_id | tostring) as $escrow_id | (.epoch_id | tonumber?) as $shard_epoch |
              select($escrow_id | test("^[0-9]+$")) | select($shard_epoch != null and $shard_epoch >= 0) |
              {escrow_id:$escrow_id,epoch_id:$shard_epoch} ] as $shards |
            select(($escrows | length) == (.active_escrows | length) and ($shards | length) == (.shards | length)) |
            {protocol_version:(.protocol_version // null),binary_version:(.binary_version // null),
             current_epoch_id:$epoch,cached_at:$cached_at,cache_ttl_seconds:$cache_ttl,
             active_escrows:$escrows,shards:$shards}
          ' <<<"$stats_response" 2>/dev/null)"; then
            stats="$(jq -cn --arg endpoint "$stats_endpoint" --arg observed_at "$stats_observed_at" \
              '{state:"unavailable",source_endpoint:$endpoint,observed_at:$observed_at,error:"invalid_devshard_stats_response"}')"
          else
            stats="$(jq -cn --arg endpoint "$stats_endpoint" --arg observed_at "$stats_observed_at" --argjson value "$stats" \
              '{state:"observed",source_endpoint:$endpoint,observed_at:$observed_at}+ $value')"
          fi
        else
          stats="$(jq -cn --arg endpoint "$stats_endpoint" --arg observed_at "$stats_observed_at" \
            '{state:"not_exposed",source_endpoint:$endpoint,observed_at:$observed_at,error:"stats_requires_v4_or_newer_runtime"}')"
        fi
        jq -cn --arg endpoint "$endpoint" --arg observed_at "$observed_at" --argjson value "$value" --argjson stats "$stats" \
          '{state:"observed",source_endpoint:$endpoint,observed_at:$observed_at}+ $value + {stats:$stats}'
        return
      fi
      ;;
    models)
      endpoint="$(chain_api_base "$dapi_url")/models_all"
      if ! response="$(http_json "$endpoint" 2>&1)"; then
        error="$(network_error "$response")"
      elif ! value="$(jq -cer '
        select(type == "object" and (.model | type) == "array" and (.model | length) <= 128) |
        {models:[.model[] | {id:(.id // null), v_ram:(.v_ram // null)}]} |
        select(.models | length > 0) |
        select(all(.models[];
          (.id | type) == "string" and (.id | length) > 0 and (.id | length) <= 256 and
          (.v_ram == null or (.v_ram | type) == "string")
        ))
      ' <<<"$response")"; then
        error=invalid_models_response
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
  local node="$1" dapi_url versions chain_rpc peers inferenced devshard models observed_node_id components_dir
  dapi_url="$(jq -r '.dapi_url // empty' <<<"$node")"
  if [[ -z "$dapi_url" ]]; then
    jq -c '. + {components:{versions:{state:"not_exposed",error:"missing_dapi_url"},chain_rpc:{state:"not_exposed",error:"missing_dapi_url"},peers:{state:"not_exposed",error:"missing_dapi_url"},inferenced:{state:"not_exposed",error:"missing_dapi_url"},devshard:{state:"not_exposed",error:"missing_dapi_url"},models:{state:"not_exposed",error:"missing_dapi_url"}}}' <<<"$node"
    return
  fi
  # Each endpoint is independent.  Probe them concurrently so an unavailable
  # optional endpoint does not add another timeout to the public snapshot.
  components_dir="$(mktemp -d)"
  component versions "$dapi_url" >"$components_dir/versions" &
  component chain_rpc "$dapi_url" >"$components_dir/chain_rpc" &
  component peers "$dapi_url" >"$components_dir/peers" &
  component inferenced "$dapi_url" >"$components_dir/inferenced" &
  component devshard "$dapi_url" >"$components_dir/devshard" &
  component models "$dapi_url" >"$components_dir/models" &
  wait
  versions="$(<"$components_dir/versions")"
  chain_rpc="$(<"$components_dir/chain_rpc")"
  peers="$(<"$components_dir/peers")"
  inferenced="$(<"$components_dir/inferenced")"
  devshard="$(<"$components_dir/devshard")"
  models="$(<"$components_dir/models")"
  rm -rf -- "$components_dir"
  # Bootstrap addresses a seed endpoint, but its node_id may outlive a node
  # key rotation. A current RPC status response is the authoritative P2P
  # identity for the observed Host; retain the bootstrap value only when RPC
  # identity is unavailable.
  observed_node_id="$(jq -r 'if .state == "observed" and (.p2p_node_id | test("^[0-9a-f]{40}$")) then .p2p_node_id else empty end' <<<"$chain_rpc")"
  jq -cn --argjson node "$node" --arg observed_node_id "$observed_node_id" --argjson versions "$versions" --argjson chain_rpc "$chain_rpc" --argjson peers "$peers" --argjson inferenced "$inferenced" --argjson devshard "$devshard" --argjson models "$models" \
    '($node + {node_id:(if $observed_node_id == "" then $node.node_id else $observed_node_id end)}) + {components:{versions:$versions,chain_rpc:$chain_rpc,peers:$peers,inferenced:$inferenced,devshard:$devshard,models:$models}}'
}

# Read a complete validator set at a fixed height.  The public response is
# paginated, and a partial page must not become evidence about effective power.
collect_validator_snapshot() {
  local dapi_url="$1" requested_height="$2" first total page_count page expected raw output_dir validators
  first="$(http_json "${dapi_url%/}/chain-rpc/validators?height=${requested_height}&page=1&per_page=100" 2>/dev/null)" || return 1
  total="$(jq -er --argjson height "$requested_height" '
    .result |
    (.block_height | tonumber?) as $actual_height |
    (.total | tonumber?) as $total |
    (.count | tonumber?) as $count |
    select($actual_height == $height and $total != null and $total >= 0 and $total <= 10000 and
      $count != null and $count >= 0 and (.validators | type) == "array") |
    $total
  ' <<<"$first" 2>/dev/null)" || return 1
  if (( total == 0 )); then
    printf '%s\n' '[]'
    return 0
  fi
  page_count=$(((total + 99) / 100))
  output_dir="$(mktemp -d)"
  for ((page = 1; page <= page_count; page += 1)); do
    expected=$((total - ((page - 1) * 100)))
    (( expected > 100 )) && expected=100
    if (( page == 1 )); then raw="$first"; else raw="$(http_json "${dapi_url%/}/chain-rpc/validators?height=${requested_height}&page=${page}&per_page=100" 2>/dev/null || true)"; fi
    if ! jq -cer --argjson height "$requested_height" --argjson expected "$expected" '
      .result |
      (.block_height | tonumber?) as $actual_height |
      (.count | tonumber?) as $count |
      select($actual_height == $height and $count == $expected and (.validators | type) == "array") |
      [ .validators[] |
        (.address | tostring | ascii_upcase) as $address |
        (.voting_power | tostring) as $power |
        select($address | test("^[0-9A-F]{40}$")) |
        select($power | test("^[0-9]+$")) |
        {address:$address,voting_power:$power,
         validator_key:(if (.pub_key.value? | type) == "string" and (.pub_key.value | length) > 0 and (.pub_key.value | length) <= 256 then .pub_key.value else null end)}
      ] | select(length == $expected)
    ' <<<"$raw" >"$output_dir/$page" 2>/dev/null; then
      rm -rf -- "$output_dir"
      return 1
    fi
  done
  if ! validators="$(jq -sc --argjson total "$total" '
    add as $validators |
    select(($validators | length) == $total) |
    select(($validators | map(.address) | unique | length) == $total) |
    $validators
  ' "$output_dir"/* 2>/dev/null)"; then
    rm -rf -- "$output_dir"
    return 1
  fi
  rm -rf -- "$output_dir"
  printf '%s\n' "$validators"
}

collect_epoch_group() {
  local api="$1" requested_epoch="$2" reference_height="$3" response
  response="$(http_json "${api}/epoch_group_data/${requested_epoch}" 2>/dev/null)" || return 1
  jq -cer --argjson requested_epoch "$requested_epoch" --argjson reference_height "$reference_height" '
    .epoch_group_data |
    (.epoch_index | tonumber?) as $epoch_index |
    (.poc_start_block_height | tonumber?) as $poc_stage |
    (.effective_block_height | tonumber?) as $effective_height |
    select($epoch_index == $requested_epoch and $poc_stage != null and $poc_stage > 0 and
      $effective_height != null and $effective_height > 0 and $effective_height <= $reference_height and
      (.validation_weights | type) == "array") |
    [ .validation_weights[] |
      (.member_address | tostring) as $participant_address |
      (.weight | tostring) as $validation_weight |
      (.confirmation_weight | tostring) as $confirmation_weight |
      select($participant_address | test("^gonka1[0-9a-z]+$")) |
      select($validation_weight | test("^[0-9]+$")) |
      select($confirmation_weight | test("^[0-9]+$")) |
      {participant_address:$participant_address,validation_weight:$validation_weight,
       confirmation_weight:$confirmation_weight,
       reputation:(if (.reputation | type) == "number" then .reputation else null end)}
    ] as $weights |
    select(($weights | map(.participant_address) | unique | length) == ($weights | length)) |
    {epoch_index:($epoch_index|tostring),poc_start_block_height:($poc_stage|tostring),
     effective_block_height:($effective_height|tostring),validation_weights:$weights}
  ' <<<"$response" 2>/dev/null
}

collect_finalized_epoch() {
  local api="$1" dapi_url="$2" reference_height="$3" latest_epoch="$4" participants="$5"
  local offset candidate group previous_group validators previous_validators commits votes events stage raw
  group=''
  for offset in 1 2 3; do
    candidate=$((latest_epoch - offset))
    (( candidate > 0 )) || break
    if group="$(collect_epoch_group "$api" "$candidate" "$reference_height" 2>/dev/null)"; then break; fi
    group=''
  done
  if [[ -z "$group" ]]; then
    printf '%s\n' '{"state":"unavailable","error":"finalized_epoch_unavailable"}'
    return
  fi
  stage="$(jq -r '.poc_start_block_height' <<<"$group")"
  validators='null'
  if raw="$(collect_validator_snapshot "$dapi_url" "$(jq -r '.effective_block_height' <<<"$group")" 2>/dev/null)"; then validators="$raw"; fi
  previous_group='null'; previous_validators='null'
  candidate=$(( $(jq -r '.epoch_index' <<<"$group") - 1 ))
  if (( candidate > 0 )) && raw="$(collect_epoch_group "$api" "$candidate" "$reference_height" 2>/dev/null)"; then
    previous_group="$raw"
    if raw="$(collect_validator_snapshot "$dapi_url" "$(jq -r '.effective_block_height' <<<"$previous_group")" 2>/dev/null)"; then previous_validators="$raw"; fi
  fi
  commits='null'; votes='null'; events='null'
  if raw="$(http_json "${api}/all_poc_v2_store_commits/${stage}" 2>/dev/null || true)"; then
    # A missing response field is an evidence gap, never an empty submission set.
    commits="$(jq -cer '
      (.commits | select(type == "array")) |
      [.[] | (.participant_address | tostring) as $participant_address |
       (.count | tostring) as $count | (.model_id // null) as $model_id |
       select($participant_address | test("^gonka1[0-9a-z]+$")) | select($count | test("^[0-9]+$")) |
       select($model_id == null or (($model_id | type) == "string" and ($model_id | length) <= 512)) |
       {participant_address:$participant_address,count:$count,model_id:$model_id}]
    ' <<<"$raw" 2>/dev/null || printf 'null')"
  fi
  if raw="$(http_json "${api}/poc_v2_validations_for_stage/${stage}" 2>/dev/null || true)"; then
    votes="$(jq -cer '
      (.poc_validation | select(type == "array")) |
      [.[]? | (.poc_validation | select(type == "array"))[]? |
       (.participant_address | tostring) as $participant_address |
       (.validator_participant_address | tostring) as $validator_participant_address |
       (.poc_stage_start_block_height | tostring) as $stage |
       (.validated_weight | tostring) as $validated_weight |
       (.model_id // null) as $model_id |
       select($participant_address | test("^gonka1[0-9a-z]+$")) |
       select($validator_participant_address | test("^gonka1[0-9a-z]+$")) |
       select($stage | test("^[1-9][0-9]*$")) |
       select($validated_weight | test("^-?[0-9]+$")) |
       select($model_id == null or (($model_id | type) == "string" and ($model_id | length) > 0 and ($model_id | length) <= 512)) |
       {participant_address:$participant_address,validator_participant_address:$validator_participant_address,
        poc_stage_start_block_height:$stage,validated_weight:$validated_weight,model_id:$model_id}]
    ' <<<"$raw" 2>/dev/null || printf 'null')"
  fi
  if raw="$(http_json "${api}/confirmation_poc_events/$(jq -r '.epoch_index' <<<"$group")" 2>/dev/null || true)"; then
    events="$(jq -cer '
      (.events | select(type == "array")) |
      [.[] | (.epoch_index | tostring) as $epoch_index |
       (.event_sequence | tostring) as $sequence | (.trigger_height | tostring) as $trigger |
       select($epoch_index | test("^[1-9][0-9]*$")) | select($sequence | test("^[0-9]+$")) |
       select($trigger | test("^[1-9][0-9]*$")) |
       select((.phase | type) == "string" and (.phase | length) > 0 and (.phase | length) <= 128) |
       {event_sequence:$sequence,trigger_height:$trigger,phase:.phase}]
      | sort_by(.event_sequence | tonumber)
    ' <<<"$raw" 2>/dev/null || printf 'null')"
  fi
  jq -cn --argjson group "$group" --argjson participants "$participants" --argjson validators "$validators" \
    --argjson previous_group "$previous_group" --argjson previous_validators "$previous_validators" \
    --argjson commits "$commits" --argjson votes "$votes" --argjson events "$events" '
      def validator_result($address; $set):
        ([ $participants[]? | select(.address == $address) | .validator_key |
           select(type == "string" and length > 0) ][0]) as $key |
        if $key == null then {state:"unmapped",voting_power:null}
        elif ($set | type) != "array" then {state:"unavailable",voting_power:null}
        else ([ $set[] | select(.validator_key == $key) | .voting_power ][0]) as $power |
          if $power == null then {state:"not_in_set",voting_power:null}
          else {state:"observed",voting_power:$power} end
        end;
      {state:"observed",epoch_index:$group.epoch_index,poc_start_block_height:$group.poc_start_block_height,
       effective_block_height:$group.effective_block_height,
       previous_epoch_index:(if ($previous_group | type) == "object" then $previous_group.epoch_index else null end),
       previous_effective_block_height:(if ($previous_group | type) == "object" then $previous_group.effective_block_height else null end),
       poc_commits:$commits,poc_votes:$votes,cpoc_events:$events,
       participants:[$group.validation_weights[] |
         . + {effective_validator:validator_result(.participant_address; $validators),
              previous_effective_validator:validator_result(.participant_address; $previous_validators)}]}
    '
}

# Chain state is queried through one identity-verified, synchronized public
# seed.  It is kept in the same snapshot as endpoint observations so the
# browser never needs a second, differently privileged data path for a
# selected bootstrap network.
collect_chain_state() {
  local nodes="$1" reference dapi_url node_id height observed_at api api_origin rpc_origin status validators participants approvals epoch stage commits votes cpoc_active cpoc_stage cpoc_commits cpoc_votes cpoc hardware_dir hardware latest_block_time sample_height sampled_block block_interval epoch_index history_dir recent_events history_epoch offset history_response finalized_epoch
  local -a history_files
  observed_at="$(timestamp)"
  reference="$(jq -cer --arg chain "$CHAIN_ID" '
    [ .[] | select(
      .components.chain_rpc.state == "observed" and
      .components.chain_rpc.chain_id == $chain and
      .components.chain_rpc.catching_up == false and
      (.components.chain_rpc.latest_block_height | type) == "number" and
      (.dapi_url | type) == "string"
    ) ] | sort_by(.components.chain_rpc.latest_block_height) | last
  ' <<<"$nodes" 2>/dev/null || true)"
  if [[ -z "$reference" ]]; then
    jq -cn --arg observed_at "$observed_at" \
      '{state:"unavailable",observed_at:$observed_at,error:"no_synchronized_seed"}'
    return
  fi
  dapi_url="$(jq -r '.dapi_url' <<<"$reference")"
  node_id="$(jq -r '.components.chain_rpc.p2p_node_id' <<<"$reference")"
  height="$(jq -r '.components.chain_rpc.latest_block_height' <<<"$reference")"
  api="$(chain_api_base "$dapi_url")"
  api_origin="${CHAIN_API_ORIGIN:-${dapi_url%/}}"
  rpc_origin="$(chain_rpc_origin "$dapi_url")"

  if ! status="$(http_json "${dapi_url%/}/chain-rpc/status" 2>&1)" ||
    ! jq -e --arg node_id "$node_id" --arg chain "$CHAIN_ID" --argjson height "$height" '
      .result.node_info.id == $node_id and .result.node_info.network == $chain and
      .result.sync_info.catching_up == false and
      (.result.sync_info.latest_block_height | tonumber?) >= $height
    ' <<<"$status" >/dev/null; then
    jq -cn --arg observed_at "$observed_at" --arg error "$(network_error "${status:-}")" \
      '{state:"unavailable",observed_at:$observed_at,error:$error}'
    return
  fi
  height="$(jq -r '.result.sync_info.latest_block_height' <<<"$status")"
  latest_block_time="$(jq -r '.result.sync_info.latest_block_time // empty' <<<"$status")"
  block_interval='null'
  sample_height=$((height - 20))
  if (( sample_height > 0 )) && [[ -n "$latest_block_time" ]]; then
    sampled_block="$(http_json "${rpc_origin}/chain-rpc/block?height=${sample_height}" 2>/dev/null || true)"
    block_interval="$(jq -cer --arg latest_block_time "$latest_block_time" --arg chain "$CHAIN_ID" --argjson height "$height" --argjson sample_height "$sample_height" '
      def unix_time: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?;
      ($latest_block_time | unix_time) as $latest |
      select(.result.block.header.chain_id == $chain) |
      (.result.block.header.height | tonumber?) as $observed_height |
      (.result.block.header.time | unix_time) as $observed_time |
      select($observed_height == $sample_height and $latest > $observed_time and $height > $sample_height) |
      (($latest - $observed_time) / ($height - $sample_height)) as $seconds |
      select($seconds >= 0.1 and $seconds <= 600) |
      (($seconds * 10 | round) / 10)
    ' <<<"$sampled_block" 2>/dev/null || printf 'null')"
  fi

  if ! validators="$(http_json "${dapi_url%/}/chain-rpc/validators?height=${height}&page=1&per_page=100" 2>&1)" ||
    ! validators="$(jq -cer --argjson height "$height" '
      .result | select((.block_height | tonumber?) == $height and
        (.count | tonumber?) == (.total | tonumber?) and
        (.total | tonumber?) <= 100 and
        (.validators | type) == "array") |
      .validators | map({address, voting_power}) |
      select(all(.[]; ((.address | type) == "string") and (.address | test("^[0-9A-Fa-f]{40}$")) and
        (.voting_power | tostring | test("^[0-9]+$"))))
    ' <<<"$validators" 2>/dev/null)"; then
    jq -cn --arg observed_at "$observed_at" \
      '{state:"unavailable",observed_at:$observed_at,error:"validator_set_unavailable"}'
    return
  fi
  if ! participants="$(http_json "${api}/participant?pagination.limit=100" 2>&1)" ||
    ! participants="$(jq -cer '
      select((.pagination.next_key == null or .pagination.next_key == "") and
        (.participant | type) == "array") |
      .participant | map({address, inference_url, status, validator_key}) |
      select(all(.[]; ((.address | type) == "string") and (.address | test("^gonka1[0-9a-z]+$")) and
        ((.inference_url | type) == "string") and ((.status | type) == "string")))
    ' <<<"$participants" 2>/dev/null)"; then
    jq -cn --arg observed_at "$observed_at" \
      '{state:"unavailable",observed_at:$observed_at,error:"participant_inventory_unavailable"}'
    return
  fi
  if ! approvals="$(http_json "${api}/devshard_approved_versions" 2>&1)" ||
    ! approvals="$(jq -cer '
      (.versions // []) | select(type == "array") |
      map({name, sha256}) |
      select(all(.[]; ((.name | type) == "string") and (.name | test("^v[0-9][A-Za-z0-9._-]*$")) and
        ((.sha256 | type) == "string") and (.sha256 | test("^[0-9a-f]{64}$"))))
    ' <<<"$approvals" 2>/dev/null)"; then
    jq -cn --arg observed_at "$observed_at" \
      '{state:"unavailable",observed_at:$observed_at,error:"approved_devshards_unavailable"}'
    return
  fi

  hardware_dir="$(mktemp -d)"
  while IFS= read -r participant; do
    local account response
    account="$(jq -r '.address' <<<"$participant")"
    if response="$(http_json "${api}/hardware_nodes/${account}" 2>&1)" &&
      jq -e --arg account "$account" '
        .nodes.participant == $account and (.nodes.hardware_nodes | type) == "array"
      ' <<<"$response" >/dev/null; then
      jq -c --arg account "$account" '
        {address:$account,nodes:[.nodes.hardware_nodes[] | {local_id,host,port,version,hardware}]}
      ' <<<"$response" >>"$hardware_dir/records"
    fi
  done < <(jq -c '.[]' <<<"$participants")
  hardware="$(jq -sc '.' "$hardware_dir/records" 2>/dev/null || printf '[]\n')"
  rm -rf -- "$hardware_dir"

  epoch="$(http_json "${api}/epoch_info" 2>/dev/null || true)"
  stage="$(jq -r '.latest_epoch.poc_start_block_height // empty' <<<"$epoch")"
  commits='null'; votes='null'
  if [[ "$stage" =~ ^[1-9][0-9]*$ ]]; then
    commits="$(http_json "${api}/all_poc_v2_store_commits/${stage}" 2>/dev/null || printf 'null')"
    votes="$(http_json "${api}/poc_v2_validations_for_stage/${stage}" 2>/dev/null || printf 'null')"
  fi
  epoch="$(jq -c --argjson height "$height" --argjson block_interval "$block_interval" '
    (.latest_epoch.index | tostring) as $index |
    (.latest_epoch.poc_start_block_height | tonumber?) as $start |
    (.params.epoch_params.epoch_length | tonumber?) as $length |
    select($index | test("^[1-9][0-9]*$")) |
    select($start != null and $start > 0 and $length != null and $length > 0) |
    ($start + $length) as $end |
    (($end - $height) | if . < 0 then 0 else . end) as $remaining |
    {latest_epoch:{index:$index,poc_start_block_height:($start|tostring),end_height:($end|tostring),blocks_remaining:($remaining|tostring)},
     block_interval_seconds:$block_interval,
     estimated_remaining_seconds:(if ($block_interval|type) == "number" then (($block_interval * $remaining) | round) else null end),
     is_confirmation_poc_active:(if (.is_confirmation_poc_active | type) == "boolean" then .is_confirmation_poc_active else null end),
     active_confirmation_poc_event:(.active_confirmation_poc_event | if type == "object" then {generation_start_height:(.generation_start_height // null),phase:(.phase // null)} else null end)}
  ' <<<"$epoch" 2>/dev/null || printf 'null')"
  commits="$(jq -c '{commits:[(.commits // [])[] | {participant_address,count,model_id}]}' <<<"$commits" 2>/dev/null || printf 'null')"
  votes="$(jq -c '{poc_validation:[(.poc_validation // [])[] | {participant,poc_validation:[(.poc_validation // [])[] | {participant_address,validator_participant_address,poc_stage_start_block_height,validated_weight,model_id}]}]}' <<<"$votes" 2>/dev/null || printf 'null')"
  cpoc_active="$(http_json "${api}/active_confirmation_poc_event" 2>/dev/null || true)"
  cpoc='null'
  if cpoc="$(jq -cer '
    if .is_active == false and .event == null then
      {state:"observed",active:false,event:null,commits:null,votes:null}
    elif .is_active == true and (.event | type) == "object" and
      (.event.epoch_index | tostring | test("^[1-9][0-9]*$")) and
      (.event.event_sequence | tostring | test("^[0-9]+$")) and
      (.event.trigger_height | tostring | test("^[1-9][0-9]*$")) and
      (.event.phase | type) == "string" then
      {state:"observed",active:true,event:{epoch_index:(.event.epoch_index|tostring),event_sequence:(.event.event_sequence|tostring),trigger_height:(.event.trigger_height|tostring),generation_start_height:(.event.generation_start_height // null | tostring),phase:.event.phase},commits:null,votes:null}
    else error("invalid_confirmation_poc_event") end
  ' <<<"$cpoc_active" 2>/dev/null)"; then
    cpoc_stage="$(jq -r 'select(.active == true) | .event.trigger_height // empty' <<<"$cpoc")"
    if [[ "$cpoc_stage" =~ ^[1-9][0-9]*$ ]]; then
      cpoc_commits="$(http_json "${api}/all_poc_v2_store_commits/${cpoc_stage}" 2>/dev/null || printf 'null')"
      cpoc_votes="$(http_json "${api}/poc_v2_validations_for_stage/${cpoc_stage}" 2>/dev/null || printf 'null')"
      cpoc_commits="$(jq -c '{commits:[(.commits // [])[] | {participant_address,count,model_id}]}' <<<"$cpoc_commits" 2>/dev/null || printf 'null')"
      cpoc_votes="$(jq -c '{poc_validation:[(.poc_validation // [])[] | {participant,poc_validation:[(.poc_validation // [])[] | {participant_address,validator_participant_address,poc_stage_start_block_height,validated_weight,model_id}]}]}' <<<"$cpoc_votes" 2>/dev/null || printf 'null')"
      cpoc="$(jq -cn --argjson cpoc "$cpoc" --argjson commits "$cpoc_commits" --argjson votes "$cpoc_votes" '$cpoc + {commits:$commits,votes:$votes}')"
    fi
  else
    cpoc="$(jq -cn '{state:"unavailable",error:"confirmation_poc_event_unavailable"}')"
  fi
  epoch_index="$(jq -r '.latest_epoch.index // empty' <<<"$epoch")"
  if [[ "$epoch_index" =~ ^[1-9][0-9]*$ ]]; then
    history_dir="$(mktemp -d)"
    history_files=()
    for offset in 0 1 2 3; do
      history_epoch=$((epoch_index - offset))
      (( history_epoch > 0 )) || break
      history_files+=("$history_dir/$history_epoch.json")
      {
        history_response="$(http_json "${api}/confirmation_poc_events/${history_epoch}" 2>/dev/null || true)"
        jq -cer '
          (.events | select(type == "array")) |
          [ .[] |
            (.epoch_index | tostring) as $event_epoch |
            (.event_sequence | tostring) as $sequence |
            (.trigger_height | tostring) as $trigger |
            select($event_epoch | test("^[1-9][0-9]*$")) |
            select($sequence | test("^[0-9]+$")) |
            select($trigger | test("^[1-9][0-9]*$")) |
            select((.phase | type) == "string" and (.phase | length) > 0 and (.phase | length) <= 128) |
            {epoch_index:$event_epoch,event_sequence:$sequence,trigger_height:$trigger,
             generation_start_height:(.generation_start_height // null | tostring),phase:.phase}
          ] | {state:"observed",events:.}
        ' <<<"$history_response" 2>/dev/null || printf '%s\n' '{"state":"unavailable","events":[]}'
      } >"$history_dir/$history_epoch.json" &
    done
    wait
    recent_events="$(jq -sc '
      if all(.[]; .state == "observed" and (.events | type) == "array") then
        {state:"observed",events:(map(.events) | add | sort_by([(.epoch_index|tonumber),(.event_sequence|tonumber)]) | reverse | .[:3])}
      else {state:"unavailable",events:[]} end
    ' "${history_files[@]}" 2>/dev/null || printf '%s\n' '{"state":"unavailable","events":[]}')"
    rm -rf -- "$history_dir"
  else
    recent_events='{"state":"unavailable","events":[]}'
  fi
  if [[ "$(jq -r '.state // empty' <<<"$cpoc")" == "observed" ]]; then
    cpoc="$(jq -cn --argjson cpoc "$cpoc" --argjson history "$recent_events" '$cpoc + {recent_events_state:$history.state,recent_events:$history.events}')"
  fi
  finalized_epoch='null'
  if [[ "$epoch_index" =~ ^[1-9][0-9]*$ ]]; then
    finalized_epoch="$(collect_finalized_epoch "$api" "$dapi_url" "$height" "$epoch_index" "$participants" 2>/dev/null || printf '%s' '{"state":"unavailable","error":"finalized_epoch_collection_failed"}')"
  fi
  jq -cn --arg endpoint "$dapi_url" --arg api_endpoint "$api_origin" --arg observed_at "$observed_at" --arg node_id "$node_id" --argjson height "$height" \
    --argjson validators "$validators" --argjson participants "$participants" --argjson approvals "$approvals" \
    --argjson hardware "$hardware" --argjson epoch "${epoch:-null}" --argjson commits "$commits" --argjson votes "$votes" --argjson cpoc "$cpoc" --argjson finalized_epoch "$finalized_epoch" \
    '{state:"observed",source_endpoint:$endpoint,observed_at:$observed_at,
      api_source_endpoint:$api_endpoint,
      reference:{node_id:$node_id,height:$height},validators:$validators,participants:$participants,
      hardware_nodes:$hardware,approved_devshards:$approvals,
      activity:{epoch:$epoch,commits:$commits,votes:$votes,cpoc:$cpoc,finalized_epoch:$finalized_epoch}}'
}

collect_nodes() {
  local bootstrap seeds seed_rpc seed_authority seed_scheme seed_port net_info records
  bootstrap="$(http_json "$BOOTSTRAP_URL")" || die "bootstrap_unavailable"
  seeds="$(jq -cer --arg chain_id "$CHAIN_ID" '
    select(.chain_id == $chain_id) |
    .seeds | select(type == "array" and length > 0 and length <= 32) |
    [ .[] | select((.rpc|type)=="string" and (.rpc|test("^https?://[^/?#]+/chain-rpc$"))) ] |
    select(length > 0)
  ' <<<"$bootstrap")" || die "invalid_bootstrap"
  records="$(mktemp)"
  while IFS= read -r seed_rpc; do
    seed_scheme="${seed_rpc%%://*}"
    seed_authority="${seed_rpc#*://}"
    seed_authority="${seed_authority%%/*}"
    seed_port=""
    if [[ "$seed_authority" == *:* ]]; then
      seed_port=":${seed_authority##*:}"
    fi
    if net_info="$(http_json "${seed_rpc%/}/net_info" 2>&1)"; then
      # A bootstrap seed is an entry point for peer discovery, not proof that
      # it is a current network participant. The viewer receives only peers
      # advertised by a reachable seed's live P2P table.
      jq -cer --arg seed_scheme "$seed_scheme" --arg seed_port "$seed_port" '
        [.result.peers[]? | select(
          (.node_info.id|type)=="string" and (.node_info.id|test("^[0-9a-f]{40}$")) and
          (.node_info.listen_addr|type)=="string" and (.remote_ip|type)=="string"
        ) | (.node_info.listen_addr | sub("^tcp://";"") | split(":")[0]) as $peer_host |
        {node_id:.node_info.id,node_name:($peer_host|split(".")[0]),url:("http://" + .remote_ip + ":8000"),dapi_url:(if $peer_host == "" then null else ($seed_scheme + "://" + $peer_host + $seed_port) end),priority:1,active:true}
        ] | .[]
      ' <<<"$net_info" >>"$records" || true
    fi
  done < <(jq -r '.[] | .rpc' <<<"$seeds")
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
  local nodes dir geo_dir index node output observed_at geo_count=0 chain
  validate_chain_api_origin
  if ! validate_chain_api_network; then return 1; fi
  nodes="$(collect_nodes)" || return 1
  jq -e 'type == "array" and length > 0' <<<"$nodes" >/dev/null || return 1
  dir="$(mktemp -d)"
  index=0
  while IFS= read -r node; do
    enrich_node "$node" >"$dir/$index.json" &
    index=$((index + 1))
    # Preview containers are constrained by a 128-task PID limit. Each node
    # fans out several independent probes, so keep node-level concurrency to
    # two while retaining that per-node parallelism.
    if (( index % 2 == 0 )); then wait; fi
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
  geo_dir="$(mktemp -d)"
  index=0
  while IFS= read -r node; do
    if (( geo_count < GEO_MAX_LOOKUPS )); then
      enrich_geo "$node" >"$geo_dir/$index.json"
      geo_count=$((geo_count + 1))
    else
      jq -c '. + {geo:null}' <<<"$node" >"$geo_dir/$index.json"
    fi
    index=$((index + 1))
  done < <(jq -c '.[]' <<<"$output")
  output="$(jq -sc 'sort_by(.node_name // "", .node_id)' "$geo_dir"/*.json)"
  rm -rf -- "$geo_dir"
  chain="$(collect_chain_state "$output")"
  jq -cn --arg chain_id "$CHAIN_ID" --arg observed_at "$observed_at" --arg bootstrap_url "$BOOTSTRAP_URL" --argjson nodes "$output" --argjson chain "$chain" \
    '{schema_version:1,chain_id:$chain_id,observed_at:$observed_at,bootstrap_url:$bootstrap_url,nodes:$nodes,chain:$chain}'
}

refresh() {
  local temporary target
  target="$(network_state_file "$CHAIN_ID")"
  mkdir -p "$STATE_DIR" "$NETWORKS_DIR"
  temporary="$(mktemp "$STATE_DIR/network.json.XXXXXX")"
  if collect >"$temporary"; then
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$target"
    if [[ "$CHAIN_ID" == "$DEFAULT_CHAIN_ID" ]]; then
      cp -- "$target" "$STATE_FILE"
    fi
  else
    rm -f -- "$temporary"
    return 1
  fi
}

request_observation() {
  local chain_id="$1" marker
  local -a markers=()
  marker="$(request_file "$chain_id")"
  mkdir -p "$REQUESTS_DIR"
  [[ -e "$marker" ]] && return 0
  shopt -s nullglob
  markers=("$REQUESTS_DIR"/*)
  (( ${#markers[@]} < 8 )) || return 2
  : >"$marker"
  chmod 0644 "$marker"
}

refresh_requested() {
  local marker chain_id count=0 status=0
  mkdir -p "$REQUESTS_DIR" "$NETWORKS_DIR"
  if ! refresh; then status=1; fi
  shopt -s nullglob
  for marker in "$REQUESTS_DIR"/*; do
    chain_id="${marker##*/}"
    valid_chain_id "$chain_id" || { rm -f -- "$marker"; continue; }
    [[ "$chain_id" == "$CHAIN_ID" ]] && continue
    count=$((count + 1))
    (( count <= 8 )) || break
    GDC_NETWORK_DEFAULT_CHAIN_ID="$DEFAULT_CHAIN_ID" GDC_NETWORK_CHAIN_ID="$chain_id" GDC_NETWORK_BOOTSTRAP_URL="$(bootstrap_url_for "$chain_id")" "$BASH" "$0" --refresh || status=1
  done
  return "$status"
}

respond() {
  local status="$1" body="$2"
  printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: %s\r\n\r\n%s' \
    "$status" "$(LC_ALL=C printf %s "$body" | wc -c)" "$body"
}

serve() {
  local request method target version extra headers_done=false body requested_chain="" state_file
  IFS= read -r -t 3 request || exit 0
  request="${request%$'\r'}"
  read -r method target version extra <<<"$request"
  if [[ -n "${extra:-}" || ! "${version:-}" =~ ^HTTP/1\.[01]$ || "${#request}" -gt 4096 ]]; then respond '400 Bad Request' '{"error":"invalid_request"}'; return; fi
  if [[ "$method" != GET ]]; then respond '405 Method Not Allowed' '{"error":"read_only"}'; return; fi
  if [[ "$target" =~ ^/status/network\?chainId=([A-Za-z0-9][A-Za-z0-9._-]{0,127})$ ]]; then
    requested_chain="${BASH_REMATCH[1]}"
  elif [[ "$target" != /status/network ]]; then
    respond '404 Not Found' '{"error":"not_found"}'
    return
  fi
  for ((count=0;count<64;count++)); do
    IFS= read -r -t 3 header || break
    [[ "${#header}" -le 8192 ]] || break
    if [[ -z "${header%$'\r'}" ]]; then headers_done=true; break; fi
  done
  [[ "$headers_done" == true ]] || { respond '400 Bad Request' '{"error":"invalid_headers"}'; return; }
  if [[ -n "$requested_chain" ]]; then
    state_file="$(network_state_file "$requested_chain")"
    if [[ -r "$state_file" ]] && body="$(cat "$state_file")" &&
      jq -e --arg chain_id "$requested_chain" '.schema_version == 1 and .chain_id == $chain_id and (.nodes | type == "array")' <<<"$body" >/dev/null; then
      respond '200 OK' "$body"
    elif request_observation "$requested_chain"; then
      respond '202 Accepted' "{\"state\":\"observation_pending\",\"chain_id\":\"$requested_chain\"}"
    else
      respond '429 Too Many Requests' '{"error":"network_observation_capacity_reached"}'
    fi
  elif [[ -r "$STATE_FILE" ]] && body="$(cat "$STATE_FILE")" && jq -e '.schema_version == 1 and (.nodes | type == "array")' <<<"$body" >/dev/null; then
    respond '200 OK' "$body"
  else
    respond '503 Service Unavailable' '{"error":"network_observation_unavailable"}'
  fi
}

case "${1:-}" in
  --collect) collect ;;
  --refresh) refresh ;;
  --refresh-requested) refresh_requested ;;
  --serve) serve ;;
  *) die "Usage: $0 --collect|--refresh|--refresh-requested|--serve" ;;
esac
