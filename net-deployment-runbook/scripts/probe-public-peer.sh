#!/usr/bin/env bash
# Probe one gossip-discovered public peer exactly once. The caller supplies
# the active node identity and address observed by a Bootstrap seed through
# net_info. The public software response must come from that exact address.
set -Eeuo pipefail

usage() { echo "Usage: $0 --node-id ID --ip PUBLIC_IPV4 --chain-id ID --output FILE" >&2; }
die_result() {
  local reason="$1" message="$2"
  local reported_ip="$IP"
  is_public_ipv4 "$IP" || reported_ip=redacted
  jq -cn --arg node_id "$NODE_ID" --arg ip "$reported_ip" --arg status unavailable --arg reason "$reason" --arg message "$message" \
    '{node_id:$node_id,remote_ip:$ip,status:$status,reason:$reason,message:$message}' >"$OUTPUT"
  exit 1
}

NODE_ID=''; IP=''; CHAIN_ID=''; OUTPUT=''
while (($#)); do
  case "$1" in
    --node-id) NODE_ID="${2:-}"; shift 2 ;;
    --ip) IP="${2:-}"; shift 2 ;;
    --chain-id) CHAIN_ID="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$NODE_ID" =~ ^[a-f0-9]{40}$ && "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$CHAIN_ID" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && -n "$OUTPUT" ]] || { usage; exit 2; }
is_public_ipv4() {
  local ip="$1"
  awk -F. 'NF == 4 && $1 >= 1 && $1 <= 223 && $2 <= 255 && $3 <= 255 && $4 <= 255 && !($1 == 10 || $1 == 127 || ($1 == 100 && $2 >= 64 && $2 <= 127) || ($1 == 169 && $2 == 254) || ($1 == 192 && ($2 == 0 || $2 == 168)) || ($1 == 172 && $2 >= 16 && $2 <= 31) || ($1 == 198 && ($2 == 18 || $2 == 19 || $2 == 51)) || ($1 == 203 && $2 == 0)) {ok=1} END {exit !ok}' <<<"$ip"
}
is_public_ipv4 "$IP" || die_result non_public_peer 'gossip remote_ip is not a public IPv4 address'
command -v curl >/dev/null || die_result dependency_missing 'curl is required'
command -v jq >/dev/null || die_result dependency_missing 'jq is required'
mkdir -p "$(dirname "$OUTPUT")"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
versions_file="$tmp/versions.json"
chain_file="$tmp/chain-identity.json"

fetch_exact_peer() {
  local url="$1" output="$2" combined actual_ip
  combined="${output}.with-remote"
  curl --noproxy '*' -fsS --connect-timeout 3 --max-time 10 \
    --write-out '\n__GDC_REMOTE_IP__=%{remote_ip}\n' "$url" >"$combined" 2>/dev/null || return 1
  actual_ip="$(sed -n 's/^__GDC_REMOTE_IP__=//p' "$combined" | tail -n 1)"
  sed '/^__GDC_REMOTE_IP__=/d' "$combined" >"$output"
  is_public_ipv4 "$actual_ip" || return 2
  [[ "$actual_ip" == "$IP" ]] || return 3
}

# `net_info` binds the advertised node ID to this public address. Bind the
# HTTP software report to the same chain as well. Prefer the exact CometBFT
# identity when the peer exposes it; older Hosts may expose only the DAPI
# epoch proof, whose block header still carries the chain ID.
chain_binding=''
if fetch_exact_peer "http://${IP}:8000/chain-rpc/status" "$chain_file"; then
  jq -e --arg chain "$CHAIN_ID" --arg node "$NODE_ID" '
    .result.node_info.network == $chain and .result.node_info.id == $node
  ' "$chain_file" >/dev/null || die_result chain_identity_mismatch 'peer chain RPC identity differs from the active net_info identity'
  chain_binding=chain_rpc
else
  chain_rpc_rc=$?
  (( chain_rpc_rc == 1 )) || die_result chain_identity_address 'peer chain RPC did not answer from its active public address'
  if fetch_exact_peer "http://${IP}:8000/v1/epochs/current/participants" "$chain_file"; then
    :
  else
    epoch_rc=$?
    (( epoch_rc == 1 )) || die_result chain_identity_address 'peer DAPI chain identity did not answer from its active public address'
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
jq -e '
  .node_version.application_name == "inference-chain" and
  .api_version.application_name == "decentralized-api"
' "$versions_file" >/dev/null || die_result application_mismatch 'peer /v1/versions reports an unexpected Core or DAPI application identity'
core_version="$(jq -r '.node_version.version | ltrimstr("v")' "$versions_file")"
jq -cn --arg node_id "$NODE_ID" --arg ip "$IP" \
  --arg chain_id "$CHAIN_ID" --arg chain_binding "$chain_binding" \
  --arg chain_response_sha "$(sha256sum "$chain_file" | awk '{print $1}')" \
  --arg core_version "$core_version" --arg core_commit "$(jq -r .node_version.commit "$versions_file")" \
  --arg dapi_version "$(jq -r '.api_version.version | ltrimstr("v")' "$versions_file")" --arg dapi_commit "$(jq -r .api_version.commit "$versions_file")" \
  --arg response_sha "$(sha256sum "$versions_file" | awk '{print $1}')" \
  '{seed_index:-1,expected_node_id:$node_id,node_id:$node_id,remote_ip:$ip,status:"usable",reason:"none",source:"discovered_peer",api_url:("http://" + $ip + ":8000"),api_source:"derived",observed_at:(now | strftime("%Y-%m-%dT%H:%M:%SZ")),chain_identity:{chain_id:$chain_id,binding:$chain_binding,response_sha256:$chain_response_sha},versions_response_sha256:$response_sha,core:{application_name:"inference-chain",version:$core_version,commit:$core_commit},dapi:{application_name:"decentralized-api",version:$dapi_version,commit:$dapi_commit}}' >"$OUTPUT"
printf 'PASS public peer node_id=%s remote_ip=%s\n' "$NODE_ID" "$IP"
