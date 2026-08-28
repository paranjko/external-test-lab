#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
adapter="$ROOT/scripts/phase-diagnostic-adapter.sh"

for pair in \
  'genesis-node:genesis:configuration' \
  'qualification-node:qualification:dependency' \
  'join-node:join:identity' \
  'confirmation-poc:poc:chain' \
  'gateway-observe:gateway:network' \
  'host-upgrade-watch:upgrade:chain' \
  'bridge-observer:bridge:dependency' \
  'observability-verify:observability:network'; do
  phase="${pair%%:*}"; remainder="${pair#*:}"; family="${remainder%%:*}"; category="${remainder##*:}"
  output="$tmp/$phase.json"
  "$adapter" "$output" "$phase" 7
  "$ROOT/scripts/diagnostic-envelope.sh" validate "$output"
  jq -e --arg family "$family" --arg category "$category" '
    .command_family == $family and .category == $category and
    .resume.decision == "manual_action_required" or
    (.command_family == "observability" and .resume.decision == "not_applicable")
  ' "$output" >/dev/null
done
printf 'PASS phase diagnostic adapters cover Genesis, qualification, JOIN, PoC, gateway, upgrade, bridge, and observability\n'
