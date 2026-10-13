#!/usr/bin/env bash
set -Eeuo pipefail

# Restrict the source-bound collector to the preview's trusted egress routes.
# Accept the bounded collector options, optionally with a pinned model height.

preview_valid_validators_query() {
  local query="$1" height='' page='' per_page=''
  [[ "$query" == 'per_page=100' ]] && return 0
  [[ "$query" =~ ^(height=[1-9][0-9]{0,14}\&page=[1-9][0-9]{0,14}\&per_page=100|height=[1-9][0-9]{0,14}\&per_page=100\&page=[1-9][0-9]{0,14}|page=[1-9][0-9]{0,14}\&height=[1-9][0-9]{0,14}\&per_page=100|page=[1-9][0-9]{0,14}\&per_page=100\&height=[1-9][0-9]{0,14}|per_page=100\&height=[1-9][0-9]{0,14}\&page=[1-9][0-9]{0,14}|per_page=100\&page=[1-9][0-9]{0,14}\&height=[1-9][0-9]{0,14})$ ]] || return 1
  local pair
  IFS='&' read -r -a pairs <<<"$query"
  for pair in "${pairs[@]}"; do
    case "$pair" in
      height=*) height="${pair#height=}" ;;
      page=*) page="${pair#page=}" ;;
      per_page=*) per_page="${pair#per_page=}" ;;
    esac
  done
  [[ -n "$height" && -n "$page" && "$per_page" == 100 ]] || return 1
  (( 10#$page <= 100 ))
}

preview_chain_api_path_allowed() {
  local path="$1" query="$2" suffix
  case "$path" in
    /chain-api/cosmos/base/tendermint/v1beta1/node_info|\
    /chain-api/productscience/inference/inference/params|\
    /chain-api/productscience/inference/inference/devshard_approved_versions|\
    /chain-api/productscience/inference/inference/models_all|\
    /chain-api/productscience/inference/inference/epoch_info|\
    /chain-api/productscience/inference/inference/current_epoch_group_data|\
    /chain-api/productscience/inference/inference/active_confirmation_poc_event|\
    /chain-rpc/status|/chain-rpc/net_info)
      [[ -z "$query" ]]
      return
      ;;
    /chain-rpc/block)
      [[ "$query" =~ ^height=([1-9][0-9]{0,14})$ ]]
      return
      ;;
    /chain-rpc/validators)
      [[ -n "$query" ]] && preview_valid_validators_query "$query"
      return
      ;;
    /chain-api/productscience/inference/inference/participant)
      [[ "$query" == 'pagination.limit=100' ||
        "$query" == 'pagination.limit=100&pagination.count_total=true' ]]
      return
      ;;
    /chain-api/productscience/inference/inference/hardware_nodes/*)
      [[ "$path" =~ ^/chain-api/productscience/inference/inference/hardware_nodes/gonka1[02-9ac-hj-np-z]{6,90}$ && -z "$query" ]]
      return
      ;;
  esac
  suffix="${path#/chain-api/productscience/inference/inference/}"
  [[ "$path" == "$suffix" ]] && return 1
  if [[ "$suffix" =~ ^epoch_group_data/[1-9][0-9]{0,14}$ && -n "$query" ]]; then
    [[ ${#query} -le 777 && "$query" =~ ^model_id=([A-Za-z0-9._~-]|%[0-9A-Fa-f]{2})+$ ]]
    return
  fi
  [[ -z "$query" && "$suffix" =~ ^(epoch_group_data|all_poc_v2_store_commits|poc_v2_validations_for_stage|confirmation_poc_events)/[1-9][0-9]{0,14}$ ]]
}

preview_node_path_allowed() {
  local path="$1" query="$2"
  case "$path" in
    /health|/v1/versions|/devshard/healthz|/chain-rpc/status|/chain-rpc/net_info|\
    /chain-api/productscience/inference/inference/params)
      [[ -z "$query" ]]
      return
      ;;
    /chain-rpc/validators)
      [[ -n "$query" ]] && preview_valid_validators_query "$query"
      return
      ;;
    /chain-api/productscience/inference/inference/hardware_nodes/*)
      [[ "$path" =~ ^/chain-api/productscience/inference/inference/hardware_nodes/gonka1[02-9ac-hj-np-z]{6,90}$ && -z "$query" ]]
      return
      ;;
    /chain-api/productscience/inference/inference/participant)
      [[ "$query" == 'pagination.limit=100&pagination.count_total=true' ]]
      return
      ;;
  esac
  return 1
}

preview_curl_target() {
  local url="${1:-}" ip a b c d path query preview_number node_number
  if [[ "$url" =~ ^https://gonka-dev\.net/([A-Za-z0-9][A-Za-z0-9._-]{0,127})/bootstrap\.json$ ]]; then
    printf '/gonka-api/%s/bootstrap.json\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$url" =~ ^https://api\.gonka-dev\.net(/[^?#]+)(\?([A-Za-z0-9._~%&=+-]+))?$ ]]; then
    [[ "${GDC_NETWORK_CHAIN_API_ORIGIN:-}" == 'https://api.gonka-dev.net' ]] || return 1
    path="${BASH_REMATCH[1]}"
    query="${BASH_REMATCH[3]:-}"
    preview_chain_api_path_allowed "$path" "$query" || return 1
    printf '/gonka-api/%s%s\n' "${path#/}" "${query:+?$query}"
    return 0
  fi
  if [[ "$url" =~ ^https://node([0-9]+)\.gonka-dev\.net(/[^?#]*)(\?([A-Za-z0-9._~%&=+-]+))?$ ]]; then
    node_number="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
    query="${BASH_REMATCH[4]:-}"
    preview_number="${GDC_PREVIEW_NUMBER:-}"
    [[ "$preview_number" =~ ^[1-9][0-9]{0,8}$ ]] || return 1
    if [[ -z "$query" && ( "$path" == '/chain-api/cosmos/base/tendermint/v1beta1/node_info' ||
      "$path" == '/devshard/stats/shards' ) ]]; then
      printf '/observer/node/node%s%s\n' "$node_number" "$path"
      return 0
    fi
    preview_node_path_allowed "$path" "$query" || return 1
    printf '/preview/%s/node/node%s%s%s\n' \
      "$preview_number" "$node_number" "$path" "${query:+?$query}"
    return 0
  fi
  if [[ "$url" =~ ^https://ipwho\.is/([0-9]{1,3}(\.[0-9]{1,3}){3})$ ]]; then
    ip="${BASH_REMATCH[1]}"
    IFS=. read -r a b c d <<<"$ip"
    [[ "$a" =~ ^[0-9]{1,3}$ && "$b" =~ ^[0-9]{1,3}$ &&
      "$c" =~ ^[0-9]{1,3}$ && "$d" =~ ^[0-9]{1,3}$ ]] || return 1
    a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d))
    ((a <= 223 && b <= 255 && c <= 255 && d <= 255)) || return 1
    ((a != 0 && a != 10 && a != 127)) || return 1
    ((a != 100 || b < 64 || b > 127)) || return 1
    ((a != 169 || b != 254)) || return 1
    ((a != 172 || b < 16 || b > 31)) || return 1
    ((a != 192 || b != 0 || c != 0)) || return 1
    ((a != 192 || b != 0 || c != 2)) || return 1
    ((a != 192 || b != 88 || c != 99)) || return 1
    ((a != 192 || b != 168)) || return 1
    ((a != 198 || b < 18 || b > 19)) || return 1
    ((a != 198 || b != 51 || c != 100)) || return 1
    ((a != 203 || b != 0 || c != 113)) || return 1
    printf '/observer/geo/%s\n' "$ip"
    return 0
  fi
  return 1
}

main() {
  [[ ( $# -eq 8 || $# -eq 10 ) && "$1" == -fsS && "$2" == --connect-timeout && "$3" == 3 &&
    "$4" == --max-time && "$5" == 5 && "$6" == --max-filesize && "$7" == 16777216 ]] || {
    echo 'preview collector request is outside the read-only transport contract' >&2
    return 2
  }
  local target url="${*: -1}"
  local -a headers=()
  if [[ $# -eq 10 ]]; then
    [[ "$8" == -H && "$9" =~ ^x-cosmos-block-height:\ [1-9][0-9]{0,14}$ &&
      "$url" =~ ^https://api\.gonka-dev\.net/chain-api/productscience/inference/inference/(current_epoch_group_data|epoch_group_data/[1-9][0-9]{0,14}\?model_id=.+)$ ]] || {
      echo 'preview collector height header is outside the model query contract' >&2
      return 2
    }
    headers=(-H "$9")
  fi
  target="$(preview_curl_target "$url")" || {
    echo 'preview collector URL is outside the read-only transport contract' >&2
    return 2
  }
  exec /usr/bin/curl -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 \
    "${headers[@]}" \
    "http://gdc-preview-egress:8080$target"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
