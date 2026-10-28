#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
phase="$ROOT/scripts/phase-monitoring-agent.sh"

bash -n "$phase"
grep -Fq 'ops monitoring-agent expects a safe SSH alias' "$phase"
grep -Fq 'is not a deployed host and cadvisor monitoring target' "$phase"
grep -Fq 'start_stack "$NODE" /srv/dai/deploy/monitoring-agent node-exporter cadvisor' "$phase"
grep -Fq 'docker compose ps --status running -q "$service"' "$phase"
grep -Fq 'http://127.0.0.1:9101/metrics http://127.0.0.1:8088/metrics' "$phase"
grep -Fq 'Wait for Prometheus to scrape $NODE exporters' "$phase"
grep -Fq 'ops monitoring-agent <SSH_ALIAS>' "$ROOT/gdc.sh"
grep -Fq 'ops-monitoring-agent-$2' "$ROOT/gdc.sh"

printf 'PASS GDC monitoring-agent deployment contract\n'
