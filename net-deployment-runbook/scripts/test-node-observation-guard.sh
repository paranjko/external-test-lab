#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$root/ops/preview/node-observation-guard.mjs"

NODE_GUARD_NO_LISTEN=1 node --input-type=module -e '
  const { publicIpv4, validPath } = await import(process.argv[1]);
  const expected = [
    ["204.12.223.90", true], ["10.0.0.1", false], ["127.0.0.1", false],
    ["169.254.1.1", false], ["172.16.0.1", false], ["192.168.1.1", false],
    ["::1", false], ["224.0.0.1", false],
  ];
  for (const [address, allowed] of expected) {
    if (publicIpv4(address) !== allowed) throw new Error(`unexpected address policy ${address}`);
  }
  for (const value of ["https://node4.gonka-dev.net/chain-rpc/status", "https://node4.gonka-dev.net/chain-rpc/net_info", "https://node4.gonka-dev.net/chain-rpc/validators?per_page=100", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/participant?pagination.limit=100&pagination.count_total=true"]) {
    if (!validPath(new URL(value))) throw new Error(`allowed path rejected ${value}`);
  }
  for (const value of ["https://node4.gonka-dev.net/chain-rpc/status?x=1", "https://node4.gonka-dev.net/chain-rpc/validators?per_page=101", "https://node4.gonka-dev.net/chain-api/productscience/inference/inference/participant?pagination.count_total=true&pagination.limit=100", "https://node4.gonka-dev.net/metadata"]) {
    if (validPath(new URL(value))) throw new Error(`unsafe path accepted ${value}`);
  }
' "$guard"

grep -Fq 'autoSelectFamily: false' "$guard"
grep -Fq 'lookup(host, { all: true, family: 4, verbatim: true })' "$guard"
grep -Fq 'if (response.headersSent)' "$guard"
grep -Fq 'response.destroy();' "$guard"
grep -Fq 'upstreamResponse.on("error", () => response.destroy());' "$guard"

printf 'PASS node observation guard rejects unsafe IPs and paths\n'
