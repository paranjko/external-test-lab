#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="$ROOT/scripts/probe-public-peer.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
id=0000000000000000000000000000000000000003

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "${!#}" >>"$CURL_SPY"
url="${!#}"
case "$url" in
  */chain-rpc/status)
    [[ "${CHAIN_RPC_ENABLED:-false}" == true ]] || exit 22
    printf '{"result":{"node_info":{"id":"%s","network":"%s"}}}\n' \
      "${CHAIN_NODE_ID:-0000000000000000000000000000000000000003}" "${OBSERVED_CHAIN:-gonka-fixture}"
    printf '\n__GDC_REMOTE_IP__=%s\n' "${CHAIN_REMOTE_IP:-8.8.8.3}"
    ;;
  */v1/epochs/current/participants)
    [[ "${CHAIN_EVIDENCE_DOWN:-false}" != true ]] || exit 22
    printf '{"block":{"header":{"chain_id":"%s","height":"123"}}}\n' "${OBSERVED_CHAIN:-gonka-fixture}"
    printf '\n__GDC_REMOTE_IP__=%s\n' "${CHAIN_REMOTE_IP:-8.8.8.3}"
    ;;
  */v1/versions)
    printf '{"node_version":{"application_name":"%s","version":"0.2.15","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"api_version":{"application_name":"%s","version":"0.2.15-post3","commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}\n' \
      "${NODE_APPLICATION:-inference-chain}" "${API_APPLICATION:-decentralized-api}"
    printf '\n__GDC_REMOTE_IP__=%s\n' "${VERSION_REMOTE_IP:-8.8.8.3}"
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"
: >"$tmp/spy"
if PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" "$PROBE" --node-id "$id" --ip 192.168.1.5 --chain-id gonka-fixture --output "$tmp/private.json"; then
  echo 'private peer unexpectedly probed' >&2; exit 1
fi
[[ ! -s "$tmp/spy" ]]
jq -e '.reason == "non_public_peer" and .status == "unavailable" and .remote_ip == "redacted"' "$tmp/private.json" >/dev/null

PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" "$PROBE" --node-id "$id" --ip 8.8.8.3 --chain-id gonka-fixture --output "$tmp/public.json" >/dev/null
jq -e '.status == "usable" and .node_id == "0000000000000000000000000000000000000003" and .seed_index == -1 and .source == "discovered_peer" and .chain_identity == {chain_id:"gonka-fixture",binding:"epoch_block",response_sha256:.chain_identity.response_sha256} and (.chain_identity.response_sha256 | test("^[0-9a-f]{64}$")) and .core.application_name == "inference-chain" and .dapi.application_name == "decentralized-api" and (has("cometbft") | not)' "$tmp/public.json" >/dev/null
[[ "$(wc -l <"$tmp/spy")" -eq 3 ]]
grep -Fq 'http://8.8.8.3:8000/chain-rpc/status' "$tmp/spy"
grep -Fq 'http://8.8.8.3:8000/v1/epochs/current/participants' "$tmp/spy"
grep -Fq 'http://8.8.8.3:8000/v1/versions' "$tmp/spy"
if PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" VERSION_REMOTE_IP=8.8.4.4 "$PROBE" --node-id "$id" --ip 8.8.8.3 --chain-id gonka-fixture --output "$tmp/mismatch.json"; then
  echo 'mismatched software-response address unexpectedly passed' >&2; exit 1
fi
jq -e '.status == "unavailable" and .reason == "versions_address_mismatch"' "$tmp/mismatch.json" >/dev/null
if PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" VERSION_REMOTE_IP=10.0.0.8 "$PROBE" --node-id "$id" --ip 8.8.8.3 --chain-id gonka-fixture --output "$tmp/private-remote.json"; then
  echo 'private software-response address unexpectedly passed' >&2; exit 1
fi
jq -e '.status == "unavailable" and .reason == "versions_remote_address"' "$tmp/private-remote.json" >/dev/null
if PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" API_APPLICATION=other-api "$PROBE" --node-id "$id" --ip 8.8.8.3 --chain-id gonka-fixture --output "$tmp/other-app.json"; then
  echo 'another application identity unexpectedly influenced selection' >&2; exit 1
fi
jq -e '.status == "unavailable" and .reason == "application_mismatch"' "$tmp/other-app.json" >/dev/null
if PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" NODE_APPLICATION=other-chain "$PROBE" --node-id "$id" --ip 8.8.8.3 --chain-id gonka-fixture --output "$tmp/other-core-app.json"; then
  echo 'another Core application identity unexpectedly influenced selection' >&2; exit 1
fi
jq -e '.status == "unavailable" and .reason == "application_mismatch"' "$tmp/other-core-app.json" >/dev/null
if PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" OBSERVED_CHAIN=gonka-other "$PROBE" --node-id "$id" --ip 8.8.8.3 --chain-id gonka-fixture --output "$tmp/other-chain.json"; then
  echo 'another chain identity unexpectedly influenced selection' >&2; exit 1
fi
jq -e '.status == "unavailable" and .reason == "chain_identity_mismatch"' "$tmp/other-chain.json" >/dev/null
if PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" CHAIN_EVIDENCE_DOWN=true "$PROBE" --node-id "$id" --ip 8.8.8.3 --chain-id gonka-fixture --output "$tmp/no-chain.json"; then
  echo 'peer without a chain identity route unexpectedly influenced selection' >&2; exit 1
fi
jq -e '.status == "unavailable" and .reason == "chain_identity_unavailable"' "$tmp/no-chain.json" >/dev/null
PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/spy" CHAIN_RPC_ENABLED=true "$PROBE" --node-id "$id" --ip 8.8.8.3 --chain-id gonka-fixture --output "$tmp/rpc.json" >/dev/null
jq -e '.status == "usable" and .chain_identity.binding == "chain_rpc" and .chain_identity.chain_id == "gonka-fixture"' "$tmp/rpc.json" >/dev/null
printf 'PASS public peer probe: public-address enforcement, chain and node identity binding, response-address binding, and application identity\n'
