#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/targets/static/host" "$tmp/targets/join/host" "$tmp/targets/join/gonka-node"
printf '%s\n' 'old-host' >"$tmp/retired"
for node in configured extra old-host; do
  jq -n --arg host "$node" '[{targets:["host:9101"],labels:{host:$host}}]' >"$tmp/targets/join/host/$node.json"
done
cp "$tmp/targets/join/host/configured.json" "$tmp/targets/static/host/configured.json"
cp "$tmp/targets/join/host/configured.json" "$tmp/targets/join/gonka-node/configured.json"
bash "$ROOT/04-ops/reconcile-monitoring-targets.sh" "$tmp/targets" "$tmp/retired"
[[ -f "$tmp/targets/join/host/extra.json" ]]
[[ ! -f "$tmp/targets/join/host/configured.json" && ! -f "$tmp/targets/join/gonka-node/configured.json" ]]
[[ ! -f "$tmp/targets/join/host/old-host.json" ]]
before="$(find "$tmp" -type f | sort)"
bash "$ROOT/04-ops/reconcile-monitoring-targets.sh" "$tmp/targets" "$tmp/retired"
[[ "$before" == "$(find "$tmp" -type f | sort)" ]]
printf '%s\n' configured >"$tmp/retired"
if bash "$ROOT/04-ops/reconcile-monitoring-targets.sh" "$tmp/targets" "$tmp/retired"; then exit 1; fi
printf 'PASS monitoring target ownership, retirement, preservation and idempotency\n'
