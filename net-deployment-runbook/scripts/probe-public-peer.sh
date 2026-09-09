#!/bin/sh
# Probe one gossip-discovered public peer exactly once. The caller supplies
# the active node identity and address observed by a Bootstrap seed through
# net_info. The public software response must come from that exact address.
set -eu

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"

usage() { echo "Usage: $0 --node-id ID --ip PUBLIC_IPV4 --chain-id ID --output FILE" >&2; }

NODE_ID=''
IP=''
CHAIN_ID=''
OUTPUT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --node-id) NODE_ID=${2:-}; shift 2 ;;
    --ip) IP=${2:-}; shift 2 ;;
    --chain-id) CHAIN_ID=${2:-}; shift 2 ;;
    --output) OUTPUT=${2:-}; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

die_result() {
  reported_ip=$IP
  gdc_is_public_ipv4 "$IP" || reported_ip=redacted
  jq -cn --arg node_id "$NODE_ID" --arg ip "$reported_ip" --arg status unavailable --arg reason "$1" --arg message "$2" \
    '{node_id:$node_id,remote_ip:$ip,status:$status,reason:$reason,message:$message}' >"$OUTPUT"
  exit 1
}

printf '%s\n' "$NODE_ID" | grep -Eq '^[a-f0-9]{40}$' \
  && printf '%s\n' "$CHAIN_ID" | grep -Eq '^[a-z0-9][a-z0-9-]{0,127}$' \
  && [ -n "$OUTPUT" ] || { usage; exit 2; }
gdc_is_public_ipv4 "$IP" || die_result non_public_peer 'gossip remote_ip is not a public IPv4 address'
command -v curl >/dev/null 2>&1 || die_result dependency_missing 'curl is required'
gdc_require_jq || die_result dependency_missing 'jq >= 1.6 is required'
mkdir -p "$(dirname "$OUTPUT")"
tmp=$(gdc_mktemp_dir)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
versions_file=$tmp/versions.json
chain_file=$tmp/chain-identity.json

FETCH_REMOTE_IP=''
fetch_exact_peer() {
  FETCH_COMBINED=$2.with-remote
  curl --noproxy '*' -fsS --connect-timeout 3 --max-time 10 \
    --write-out '\n__GDC_REMOTE_IP__=%{remote_ip}\n' "$1" >"$FETCH_COMBINED" 2>/dev/null || return 1
  FETCH_REMOTE_IP=$(sed -n 's/^__GDC_REMOTE_IP__=//p' "$FETCH_COMBINED" | tail -n 1)
  sed '/^__GDC_REMOTE_IP__=/d' "$FETCH_COMBINED" >"$2"
  gdc_is_public_ipv4 "$FETCH_REMOTE_IP" || return 2
  [ "$FETCH_REMOTE_IP" = "$IP" ] || return 3
}

chain_binding=''
if fetch_exact_peer "http://${IP}:8000/chain-rpc/status" "$chain_file"; then
  jq -e --arg chain "$CHAIN_ID" --arg node "$NODE_ID" '
    .result.node_info.network == $chain and .result.node_info.id == $node
  ' "$chain_file" >/dev/null || die_result chain_identity_mismatch 'peer chain RPC identity differs from the active net_info identity'
  chain_binding=chain_rpc
else
  chain_rpc_rc=$?
  [ "$chain_rpc_rc" -eq 1 ] || die_result chain_identity_address 'peer chain RPC did not answer from its active public address'
  if fetch_exact_peer "http://${IP}:8000/v1/epochs/current/participants" "$chain_file"; then
    :
  else
    epoch_rc=$?
    [ "$epoch_rc" -eq 1 ] || die_result chain_identity_address 'peer DAPI chain identity did not answer from its active public address'
    die_result chain_identity_unavailable 'peer exposes no address-bound chain identity route'
  fi
  jq -e --arg chain "$CHAIN_ID" '
    .block.header.chain_id == $chain and
    (.block.header.height | tostring | test("^[1-9][0-9]*$"))
  ' "$chain_file" >/dev/null || die_result chain_identity_mismatch 'peer DAPI block identity differs from the requested chain'
  chain_binding=epoch_block
fi

if fetch_exact_peer "http://${IP}:8000/v1/versions" "$versions_file"; then
  :
else
  versions_rc=$?
  case "$versions_rc" in
    1) die_result versions_unavailable 'peer /v1/versions request failed' ;;
    2) die_result versions_remote_address 'peer /v1/versions did not return from a public IPv4 address' ;;
    3) die_result versions_address_mismatch 'peer /v1/versions remote address differs from the active net_info address' ;;
    *) die_result versions_unavailable 'peer /v1/versions request failed unexpectedly' ;;
  esac
fi
jq -e '
  (.node_version.application_name | type == "string" and length > 0) and
  (.node_version.version | type == "string" and length > 0) and
  (.node_version.commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.api_version.application_name | type == "string" and length > 0) and
  (.api_version.version | type == "string" and length > 0) and
  (.api_version.commit | type == "string" and test("^[0-9a-f]{40}$"))
' "$versions_file" >/dev/null || die_result versions_invalid 'peer /v1/versions response is malformed'
jq -e '.node_version.application_name == "inference-chain" and .api_version.application_name == "decentralized-api"' "$versions_file" >/dev/null \
  || die_result application_mismatch 'peer /v1/versions reports an unexpected Core or DAPI application identity'
core_version=$(jq -r '.node_version.version | ltrimstr("v")' "$versions_file")
jq -cn --arg node_id "$NODE_ID" --arg ip "$IP" --arg chain_id "$CHAIN_ID" --arg chain_binding "$chain_binding" \
  --arg chain_response_sha "$(gdc_sha256 "$chain_file")" \
  --arg core_version "$core_version" --arg core_commit "$(jq -r .node_version.commit "$versions_file")" \
  --arg dapi_version "$(jq -r '.api_version.version | ltrimstr("v")' "$versions_file")" --arg dapi_commit "$(jq -r .api_version.commit "$versions_file")" \
  --arg response_sha "$(gdc_sha256 "$versions_file")" \
  '{seed_index:-1,expected_node_id:$node_id,node_id:$node_id,remote_ip:$ip,status:"usable",reason:"none",source:"discovered_peer",api_url:("http://" + $ip + ":8000"),api_source:"derived",observed_at:(now | strftime("%Y-%m-%dT%H:%M:%SZ")),chain_identity:{chain_id:$chain_id,binding:$chain_binding,response_sha256:$chain_response_sha},versions_response_sha256:$response_sha,core:{application_name:"inference-chain",version:$core_version,commit:$core_commit},dapi:{application_name:"decentralized-api",version:$dapi_version,commit:$dapi_commit}}' >"$OUTPUT"
printf 'PASS public peer node_id=%s remote_ip=%s\n' "$NODE_ID" "$IP"
