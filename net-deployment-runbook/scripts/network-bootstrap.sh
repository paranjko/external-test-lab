#!/bin/sh
# Validate and stage the public one-file network Bootstrap descriptor. This is
# local operator code, deliberately limited to POSIX sh and jq.
set -eu

MAX_DOCUMENT_BYTES=262144

die() { printf 'bootstrap validation failed stage=%s field=%s: %s\n' "$1" "$2" "$3" >&2; exit 1; }
usage() { echo "Usage: $0 verify|env|stage|online FILE [DESTINATION]" >&2; }

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"

require_jq() { gdc_require_jq || die dependency jq 'jq >= 1.6 is required by the operator runbook'; }

validate() {
  file=$1
  require_jq
  [ -r "$file" ] || die read "$file" 'cannot read document'
  size=$(wc -c <"$file")
  [ "$size" -le "$MAX_DOCUMENT_BYTES" ] || die size "$file" 'document exceeds limit'
  jq -e . "$file" >/dev/null 2>&1 || die parse "$file" 'invalid JSON'
  jq --stream -e -s '[.[] | select(length == 2) | .[0] | @json] | length == (unique | length)' "$file" >/dev/null 2>&1 || die parse "$file" 'duplicate key'
  jq -e '
    def port_number: "(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])";
    def port: "(?::" + port_number + ")?";
    def http_url: test("^(http|https)://[A-Za-z0-9.-]+" + port + "(/[A-Za-z0-9._~/%:-]*)?$");
    def p2p_url: test("^tcp://[A-Za-z0-9.-]+:" + port_number + "$");
    type == "object" and (keys | sort) == ["$schema","brokers","chain_id","genesis","seeds"] and
    .["$schema"] == "https://gonka-dev.net/v1.bootstrap.schema.json" and
    (.chain_id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.genesis | type == "object" and (keys | sort) == ["sha256"] and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    (.seeds | type == "array" and length >= 2) and
    (.brokers | type == "array") and
    (.seeds as $seeds | ([$seeds[].node_id] | unique | length) == ($seeds | length)) and
    (.seeds as $seeds | ([$seeds[].rpc] | unique | length) == ($seeds | length)) and
    (.seeds as $seeds | ([$seeds[].p2p] | unique | length) == ($seeds | length)) and
    all(.seeds[];
      type == "object" and ((keys | sort) == ["node_id","p2p","rpc"] or (keys | sort) == ["api","node_id","p2p","rpc"]) and
      (.node_id | type == "string" and test("^[0-9a-f]{40}$")) and
      (.rpc | type == "string" and http_url and test("^https?://[A-Za-z0-9.-]+" + port + "/chain-rpc/?$")) and
      (.p2p | type == "string" and p2p_url) and
      ((has("api") | not) or (.api | type == "string" and http_url))) and
    ([.seeds[] | select(has("api"))] | length > 0) and
    all(.brokers[];
      type == "object" and ((keys | sort) == ["api_urls"] or (keys | sort) == ["access_url","api_urls"]) and
      (.api_urls | type == "array" and length >= 1 and all(.[]; type == "string" and test("^https://[A-Za-z0-9.-]+" + port + "(/[A-Za-z0-9._~/%:-]*)?$"))) and
      (.api_urls as $urls | ($urls | unique | length) == ($urls | length)) and
      ((has("access_url") | not) or (.access_url | type == "string" and test("^https://[A-Za-z0-9.-]+" + port + "(/[A-Za-z0-9._~/%:-]*)?$"))))
  ' "$file" >/dev/null || die schema '$' 'does not match network bootstrap v1'
}

render_env() {
  file=$1
  first_api=$(jq -r '[.seeds[] | select(has("api")) | .api][0]' "$file")
  rpc0=$(jq -r '[.seeds[].rpc] | unique | .[0]' "$file")
  rpc1=$(jq -r '[.seeds[].rpc] | unique | .[1]' "$file")
  p2p=$(jq -r '.seeds[0].p2p' "$file")
  [ -n "$rpc0" ] && [ -n "$rpc1" ] && [ "$rpc1" != null ] || die env seeds 'two distinct RPC URLs required'
  # Validation restricts all projected values to shell-safe URL characters.
  printf 'export SEED_API_URL=%s\nexport SEED_NODE_RPC_URL=%s\nexport SEED_NODE_P2P_URL=%s\nexport RPC_SERVER_URL_1=%s\nexport RPC_SERVER_URL_2=%s\n' \
    "$first_api" "$rpc0" "$p2p" "$rpc0" "$rpc1"
}

download_genesis() {
  file=$1 rpc=$2 output=$3
  cli=${INFERENCED:-inferenced}
  command -v "$cli" >/dev/null 2>&1 || die dependency inferenced 'a compatible inferenced CLI is required to download the exact Genesis'
  expected_sha=$(jq -r '.genesis.sha256' "$file")
  expected_chain=$(jq -r '.chain_id' "$file")
  "$cli" download-genesis "$rpc" "$output" >/dev/null 2>&1 || return 1
  actual_sha=$(gdc_sha256 "$output")
  actual_chain=$(jq -r '.chain_id // empty' "$output" 2>/dev/null || true)
  [ "$actual_sha" = "$expected_sha" ] && [ "$actual_chain" = "$expected_chain" ]
}

stage() {
  file=$1 destination=$2
  temp=$(gdc_mktemp_dir)
  selected=''
  while IFS= read -r rpc; do
    if download_genesis "$file" "$rpc" "$temp/genesis.json"; then
      selected=$rpc
      break
    fi
  done <<EOF
$(jq -r '.seeds[].rpc' "$file")
EOF
  [ -n "$selected" ] || { rm -rf "$temp"; die genesis seeds 'no RPC candidate produced matching Genesis'; }
  (umask 077 && mkdir -p "$destination")
  install -m 0600 "$temp/genesis.json" "$destination/genesis.json"
  render_env "$file" >"$destination/bootstrap.env"
  chmod 0600 "$destination/bootstrap.env"
  jq -r '.seeds[] | "\(.node_id)@\(.p2p | sub("^tcp://"; ""))"' "$file" >"$destination/genesis-seeds.txt"
  chmod 0600 "$destination/genesis-seeds.txt"
  rm -rf "$temp"
  printf 'PASS staged network bootstrap chain_id=%s selected_rpc=%s\n' "$(jq -r .chain_id "$file")" "$selected"
}

online() {
  file=$1
  seed_count=$(jq '.seeds | length' "$file")
  i=0
  while [ "$i" -lt "$seed_count" ]; do
    rpc=$(jq -r ".seeds[$i].rpc" "$file")
    node_id=$(jq -r ".seeds[$i].node_id" "$file")
    observed=$(curl -fsS --connect-timeout 10 --max-time 20 "${rpc%/}/status" | jq -r '.result.node_info.id // empty')
    [ "$observed" = "$node_id" ] || die online "$rpc" '/status node ID does not match descriptor'
    temporary=$(mktemp)
    if ! download_genesis "$file" "$rpc" "$temporary"; then
      rm -f "$temporary"
      die genesis "$rpc" 'official download-genesis did not match descriptor'
    fi
    rm -f "$temporary"
    if jq -e ".seeds[$i] | has(\"api\")" "$file" >/dev/null; then
      api=$(jq -r ".seeds[$i].api" "$file")
      curl -fsS --connect-timeout 10 --max-time 20 "${api%/}/v1/participants" >/dev/null || die online "$api" 'participant API is unavailable'
    fi
    p2p=$(jq -r ".seeds[$i].p2p" "$file")
    host=${p2p#tcp://}; host=${host%:*}; port=${p2p##*:}
    curl -fsS --connect-timeout 10 --max-time 10 "telnet://${host}:${port}" >/dev/null || die online "$p2p" 'P2P endpoint is unavailable'
    i=$((i + 1))
  done
  broker_count=$(jq '.brokers | length' "$file")
  i=0
  while [ "$i" -lt "$broker_count" ]; do
    while IFS= read -r endpoint; do
      curl -fsS --connect-timeout 10 --max-time 20 "${endpoint%/}/v1/models" >/dev/null || die online "brokers[$i]" 'broker endpoint is unavailable'
    done <<EOF
$(jq -r ".brokers[$i].api_urls[]" "$file")
EOF
    i=$((i + 1))
  done
  printf 'PASS online network bootstrap chain_id=%s seeds=%s\n' "$(jq -r .chain_id "$file")" "$seed_count"
}

command=${1:-}
[ "$#" -gt 0 ] && shift || true
case "$command" in
  verify)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    validate "$1"
    printf 'PASS offline network bootstrap file=%s chain_id=%s genesis_sha256=%s seeds=%s\n' "$1" "$(jq -r .chain_id "$1")" "$(jq -r .genesis.sha256 "$1")" "$(jq '.seeds | length' "$1")"
    printf 'Repository attestation and live RPC checks were not run.\n'
    ;;
  env) [ "$#" -eq 1 ] || { usage; exit 2; }; validate "$1"; render_env "$1" ;;
  stage) [ "$#" -eq 2 ] || { usage; exit 2; }; validate "$1"; stage "$1" "$2" ;;
  online) [ "$#" -eq 1 ] || { usage; exit 2; }; validate "$1"; online "$1" ;;
  *) usage; exit 2 ;;
esac
