#!/usr/bin/env bash
set -Eeuo pipefail

MAX_DOCUMENT_BYTES=262144

die() { printf 'bootstrap validation failed stage=%s field=%s: %s\n' "$1" "$2" "$3" >&2; exit 1; }
usage() { echo "Usage: $0 verify|env|stage|online FILE [DESTINATION]" >&2; }
require_jq() { command -v jq >/dev/null 2>&1 || die dependency jq 'jq is required by the operator runbook'; }

valid_http_url() {
  local value=$1 field=$2 host port
  [[ "$value" =~ ^(http|https)://([^/@:?]+)(:([0-9]{1,5}))?(/[A-Za-z0-9._~/%:-]*)?$ ]] || die semantics "$field" 'has an unsupported scheme or unsafe URL component'
  host=${BASH_REMATCH[2]}; port=${BASH_REMATCH[4]}
  [[ -n "$host" && "$value" != *'?'* && "$value" != *'#'* ]] || die semantics "$field" 'has an unsupported scheme or unsafe URL component'
  [[ -z "$port" || ("$port" -ge 1 && "$port" -le 65535) ]] || die semantics "$field" 'has an invalid port'
}

valid_p2p_url() {
  local value=$1 field=$2 port
  [[ "$value" =~ ^tcp://([^/@:?]+):([0-9]{1,5})$ ]] || die semantics "$field" 'must have a safe tcp URL with an explicit port'
  port=${BASH_REMATCH[2]}
  (( port >= 1 && port <= 65535 )) || die semantics "$field" 'has an invalid port'
}

validate() {
  local file=$1 size seed_count broker_count api_count i node_id rpc p2p api urls url
  require_jq
  [[ -r "$file" ]] || die read "$file" 'cannot read document'
  size=$(wc -c <"$file")
  (( size <= MAX_DOCUMENT_BYTES )) || die size "$file" 'document exceeds limit'
  jq -e . "$file" >/dev/null 2>&1 || die parse "$file" 'invalid JSON'
  jq --stream -e -s '[.[] | select(length == 2) | .[0] | @json] | length == (unique | length)' "$file" >/dev/null 2>&1 || die parse "$file" 'duplicate key'
  jq -e '
    type == "object" and (keys | sort) == ["$schema","brokers","chain_id","genesis","seeds"] and
    .["$schema"] == "https://gonka-dev.net/v1.bootstrap.schema.json" and
    (.chain_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.genesis | type == "object" and (keys | sort) == ["sha256"] and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    (.seeds | type == "array" and length >= 2) and
    (.brokers | type == "array") and
    all(.seeds[]; type == "object" and ((keys | sort) == ["node_id","p2p","rpc"] or (keys | sort) == ["api","node_id","p2p","rpc"]) and
      (.node_id | type == "string" and test("^[0-9a-f]{40}$")) and (.rpc | type == "string") and (.p2p | type == "string") and
      ((has("api") | not) or (.api | type == "string"))) and
    all(.brokers[]; type == "object" and ((keys | sort) == ["api_urls"] or (keys | sort) == ["access_url","api_urls"]) and
      (.api_urls | type == "array" and length >= 1 and all(.[]; type == "string")) and
      ((has("access_url") | not) or (.access_url | type == "string")))
  ' "$file" >/dev/null || die schema '$' 'does not match network bootstrap v1'
  seed_count=$(jq '.seeds | length' "$file")
  api_count=0
  declare -A ids=() rpcs=() p2ps=()
  for ((i=0; i<seed_count; i++)); do
    node_id=$(jq -r ".seeds[$i].node_id" "$file"); rpc=$(jq -r ".seeds[$i].rpc" "$file"); p2p=$(jq -r ".seeds[$i].p2p" "$file")
    [[ -z "${ids[$node_id]:-}" && -z "${rpcs[$rpc]:-}" && -z "${p2ps[$p2p]:-}" ]] || die semantics "seeds[$i]" 'duplicate seed identity or endpoint'
    ids[$node_id]=1; rpcs[$rpc]=1; p2ps[$p2p]=1
    valid_http_url "$rpc" "seeds[$i].rpc"; valid_p2p_url "$p2p" "seeds[$i].p2p"
    if jq -e ".seeds[$i] | has(\"api\")" "$file" >/dev/null; then api=$(jq -r ".seeds[$i].api" "$file"); valid_http_url "$api" "seeds[$i].api"; ((api_count+=1)); fi
  done
  (( api_count > 0 )) || die semantics seeds 'at least one seed must provide api'
  broker_count=$(jq '.brokers | length' "$file")
  for ((i=0; i<broker_count; i++)); do
    urls=$(jq -r ".brokers[$i].api_urls[]" "$file")
    [[ $(printf '%s\n' "$urls" | sort -u | wc -l) -eq $(printf '%s\n' "$urls" | wc -l) ]] || die semantics "brokers[$i].api_urls" 'contains duplicate endpoint'
    while IFS= read -r url; do [[ "$url" =~ ^https:// ]] || die semantics "brokers[$i].api_urls" 'must use https'; valid_http_url "$url" "brokers[$i].api_urls"; done <<<"$urls"
    if jq -e ".brokers[$i] | has(\"access_url\")" "$file" >/dev/null; then url=$(jq -r ".brokers[$i].access_url" "$file"); [[ "$url" =~ ^https:// ]] || die semantics "brokers[$i].access_url" 'must use https'; valid_http_url "$url" "brokers[$i].access_url"; fi
  done
}

render_env() {
  local file=$1 first_api rpc0 rpc1 p2p
  first_api=$(jq -r '[.seeds[] | select(has("api")) | .api][0]' "$file")
  rpc0=$(jq -r '[.seeds[].rpc] | unique | .[0]' "$file"); rpc1=$(jq -r '[.seeds[].rpc] | unique | .[1]' "$file")
  [[ -n "$rpc0" && -n "$rpc1" && "$rpc1" != null ]] || die env seeds 'two distinct RPC URLs required'
  p2p=$(jq -r '.seeds[0].p2p' "$file")
  printf "export SEED_API_URL=%q\nexport SEED_NODE_RPC_URL=%q\nexport SEED_NODE_P2P_URL=%q\nexport RPC_SERVER_URL_1=%q\nexport RPC_SERVER_URL_2=%q\n" "$first_api" "$rpc0" "$p2p" "$rpc0" "$rpc1"
}

download_genesis() {
  local file=$1 rpc=$2 output=$3 cli expected_sha expected_chain actual_sha actual_chain
  cli="${INFERENCED:-inferenced}"
  command -v "$cli" >/dev/null 2>&1 || die dependency inferenced 'a compatible inferenced CLI is required to download the exact Genesis'
  expected_sha=$(jq -r '.genesis.sha256' "$file"); expected_chain=$(jq -r '.chain_id' "$file")
  "$cli" download-genesis "$rpc" "$output" >/dev/null 2>&1 || return 1
  actual_sha=$(sha256sum "$output" | awk '{print $1}'); actual_chain=$(jq -r '.chain_id // empty' "$output" 2>/dev/null || true)
  [[ "$actual_sha" == "$expected_sha" && "$actual_chain" == "$expected_chain" ]]
}

stage() {
  local file=$1 destination=$2 temp rpc selected=''
  temp=$(mktemp -d); trap 'rm -rf -- "$temp"' RETURN
  while IFS= read -r rpc; do if download_genesis "$file" "$rpc" "$temp/genesis.json"; then selected=$rpc; break; fi; done < <(jq -r '.seeds[].rpc' "$file")
  [[ -n "$selected" ]] || die genesis seeds 'no RPC candidate produced matching Genesis'
  install -d -m 0700 "$destination"
  install -m 0600 "$temp/genesis.json" "$destination/genesis.json"
  render_env "$file" >"$destination/bootstrap.env"; chmod 0600 "$destination/bootstrap.env"
  jq -r '.seeds[] | "\(.node_id)@\(.p2p | sub("^tcp://"; ""))"' "$file" >"$destination/genesis-seeds.txt"; chmod 0600 "$destination/genesis-seeds.txt"
  printf 'PASS staged network bootstrap chain_id=%s selected_rpc=%s\n' "$(jq -r .chain_id "$file")" "$selected"
}

online() {
  local file=$1 seed_count broker_count i rpc node_id observed api p2p host port endpoint temporary
  seed_count=$(jq '.seeds | length' "$file")
  for ((i=0; i<seed_count; i++)); do
    rpc=$(jq -r ".seeds[$i].rpc" "$file"); node_id=$(jq -r ".seeds[$i].node_id" "$file")
    observed=$(curl -fsS --connect-timeout 10 --max-time 20 "${rpc%/}/status" | jq -r '.result.node_info.id // empty')
    [[ "$observed" == "$node_id" ]] || die online "$rpc" '/status node ID does not match descriptor'
    temporary=$(mktemp)
    if ! download_genesis "$file" "$rpc" "$temporary"; then
      rm -f -- "$temporary"
      die genesis "$rpc" 'official download-genesis did not match descriptor'
    fi
    rm -f -- "$temporary"
    if jq -e ".seeds[$i] | has(\"api\")" "$file" >/dev/null; then api=$(jq -r ".seeds[$i].api" "$file"); curl -fsS --connect-timeout 10 --max-time 20 "${api%/}/v1/participants" >/dev/null || die online "$api" 'participant API is unavailable'; fi
    p2p=$(jq -r ".seeds[$i].p2p" "$file"); host=${p2p#tcp://}; host=${host%:*}; port=${p2p##*:}
    timeout 10 bash -c ">/dev/tcp/$host/$port" 2>/dev/null || die online "$p2p" 'P2P endpoint is unavailable'
  done
  broker_count=$(jq '.brokers | length' "$file")
  for ((i=0; i<broker_count; i++)); do
    while IFS= read -r endpoint; do curl -fsS --connect-timeout 10 --max-time 20 "${endpoint%/}/v1/models" >/dev/null || die online "brokers[$i]" 'broker endpoint is unavailable'; done < <(jq -r ".brokers[$i].api_urls[]" "$file")
  done
  printf 'PASS online network bootstrap chain_id=%s seeds=%s\n' "$(jq -r .chain_id "$file")" "$seed_count"
}

command=${1:-}; shift || true
case "$command" in
  verify) [[ $# -eq 1 ]] || { usage; exit 2; }; validate "$1"; printf 'PASS offline network bootstrap file=%s chain_id=%s genesis_sha256=%s seeds=%s\n' "$1" "$(jq -r .chain_id "$1")" "$(jq -r .genesis.sha256 "$1")" "$(jq '.seeds | length' "$1")"; printf 'Repository attestation and live RPC checks were not run.\n' ;;
  env) [[ $# -eq 1 ]] || { usage; exit 2; }; validate "$1"; render_env "$1" ;;
  stage) [[ $# -eq 2 ]] || { usage; exit 2; }; validate "$1"; stage "$1" "$2" ;;
  online) [[ $# -eq 1 ]] || { usage; exit 2; }; validate "$1"; online "$1" ;;
  *) usage; exit 2 ;;
esac
