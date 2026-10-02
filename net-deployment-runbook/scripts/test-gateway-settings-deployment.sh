#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
phase="$ROOT/scripts/phase-gateway-settings.sh"

bash -n "$phase"
grep -Fq 'GDC_GATEWAY_SETTINGS_TARGETS must be a non-empty unique A/B target JSON array' "$phase"
grep -Fq 'topology_contains_node "$node"' "$phase"
grep -Fq 'ssh -n "$node"' "$phase"
grep -Fq '"$node:$stage/04-ops/" < /dev/null' "$phase"
grep -Fq 'attempt="$(date -u +%Y%m%dT%H%M%SZ)-$$"' "$phase"
grep -Fq -- '--expected-sha256' "$phase"
grep -Fq 'delta_fields=%s%s' "$phase"
grep -Fq 'ops gateway-settings preview|apply' "$ROOT/gdc.sh"
grep -Fq 'ops-gateway-settings-$2' "$ROOT/gdc.sh"
grep -Fq "GDC_GATEWAY_SETTINGS_TARGETS='[]'" "$ROOT/.env.example"
printf 'PASS GDC A/B gateway-settings deployment contract\n'
