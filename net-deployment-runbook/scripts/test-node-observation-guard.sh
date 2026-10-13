#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$root/ops/preview/node-observation-guard.mjs"

NODE_GUARD_NO_LISTEN=1 node --input-type=module -e '
  const { publicIpv4, validPath, validBootstrapPath, validGeoPath } = await import(process.argv[1]);
  const expected = [
    ["204.12.223.90", true], ["10.0.0.1", false], ["127.0.0.1", false],
    ["169.254.1.1", false], ["172.16.0.1", false], ["192.168.1.1", false],
    ["100.64.0.1", false], ["192.0.0.1", false], ["192.0.2.1", false],
    ["192.2.0.1", true], ["198.18.0.1", false],
    ["198.51.100.1", false], ["203.0.113.1", false],
    ["::1", false], ["224.0.0.1", false],
  ];
  for (const [address, allowed] of expected) {
    if (publicIpv4(address) !== allowed) throw new Error(`unexpected address policy ${address}`);
  }
  for (const value of ["https://node4.gonka-dev.net/health", "https://node4.gonka-dev.net/v1/versions", "https://node4.gonka-dev.net/devshard/healthz", "https://node4.gonka-dev.net/devshard/stats/shards", "https://node4.gonka-dev.net/chain-rpc/status", "https://node4.gonka-dev.net/chain-rpc/net_info", "https://node4.gonka-dev.net/chain-rpc/block?height=657379", "https://node4.gonka-dev.net/chain-rpc/validators?per_page=100", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&page=1&per_page=100", "https://node4.gonka-dev.net/chain-rpc/validators?per_page=100&page=2&height=657379", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&page=100&per_page=100", "https://node4.gonka-dev.net/chain-api/cosmos/base/tendermint/v1beta1/node_info", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/params", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/hardware_nodes/gonka1p95sawnvspxeghe8eh7ll02nrw2jrqet039l4m", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/devshard_approved_versions", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/models_all", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/epoch_info", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/active_confirmation_poc_event", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/123", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/all_poc_v2_store_commits/123", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/poc_v2_validations_for_stage/123", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/confirmation_poc_events/123", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/participant?pagination.limit=100&pagination.count_total=true"]) {
    if (!validPath(new URL(value))) throw new Error(`allowed path rejected ${value}`);
  }
  for (const value of ["https://node4.gonka-dev.net/health?x=1", "https://node4.gonka-dev.net/v1/versions?x=1", "https://node4.gonka-dev.net/devshard/healthz?x=1", "https://node4.gonka-dev.net/chain-rpc/status?x=1", "https://node4.gonka-dev.net/chain-rpc/block?height=0", "https://node4.gonka-dev.net/chain-rpc/validators?per_page=101", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&per_page=100", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&page=0&per_page=100", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&page=101&per_page=100", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&page=2&per_page=50", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&page=2&per_page=100&extra=1", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&height=657380&page=1&per_page=100", "https://node4.gonka-dev.net/chain-rpc/validators?height=0&page=1&per_page=100", "https://node4.gonka-dev.net/chain-rpc/validators?height=657379&page=2&per_page=100&", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/params?x=1", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/hardware_nodes/gonka1invalid?x=1", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/participant?pagination.count_total=true&pagination.limit=100", "https://node4.gonka-dev.net/metadata", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/0", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/123?x=1"]) {
    if (validPath(new URL(value))) throw new Error(`unsafe path accepted ${value}`);
  }
  for (const value of ["/bootstrap/gonka-devnet-community/bootstrap.json", "/bootstrap/test_chain-1/bootstrap.json"]) {
    if (!validBootstrapPath(value)) throw new Error(`allowed bootstrap rejected ${value}`);
  }
  for (const value of ["/bootstrap/../bootstrap.json", "/bootstrap/gonka-devnet-community/bootstrap.json?x=1", "/bootstrap/bad%2fchain/bootstrap.json", "/bootstrap//bootstrap.json"]) {
    if (validBootstrapPath(value)) throw new Error(`unsafe bootstrap accepted ${value}`);
  }
  if (!validGeoPath("/geo/204.12.223.90")) throw new Error("public GeoIP path rejected");
  for (const value of ["/geo/127.0.0.1", "/geo/192.0.2.1", "/geo/204.12.223.90?x=1", "/geo/999.12.223.90"]) {
    if (validGeoPath(value)) throw new Error(`unsafe GeoIP path accepted ${value}`);
  }
' "$guard"

grep -Fq 'autoSelectFamily: false' "$guard"
grep -Fq 'lookup(host, { all: true, family: 4, verbatim: true })' "$guard"
grep -Fq 'if (response.headersSent)' "$guard"
grep -Fq 'response.destroy();' "$guard"
grep -Fq 'upstreamResponse.on("error", () => response.destroy());' "$guard"

printf 'PASS node observation guard rejects unsafe IPs and paths\n'
