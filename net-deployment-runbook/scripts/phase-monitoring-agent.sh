#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

NODE="${1:-}"
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "ops monitoring-agent expects a safe SSH alias, got: $NODE"

step "Authorize retained monitoring target $NODE"
ssh -T "$GATEWAY_NODE" "curl -fsS --connect-timeout 5 --max-time 15 'http://127.0.0.1:9099/api/v1/targets?state=active' | jq -e --arg host '$NODE' '[.data.activeTargets[] | select(.labels.host == \$host and (.labels.job == \"host\" or .labels.job == \"cadvisor\"))] | ([.[].labels.job] | unique | sort) == [\"cadvisor\", \"host\"]' >/dev/null" \
  || die "$NODE is not a deployed host and cadvisor monitoring target"

step "Start monitoring exporters on $NODE"
start_stack "$NODE" /srv/dai/deploy/monitoring-agent node-exporter cadvisor

step "Verify monitoring exporters on $NODE"
ssh -T "$NODE" 'set -Eeuo pipefail
  cd /srv/dai/deploy/monitoring-agent
  for service in node-exporter cadvisor; do
    docker compose ps --status running -q "$service" | grep -q .
  done
  for endpoint in http://127.0.0.1:9101/metrics http://127.0.0.1:8088/metrics; do
    curl -fsS --connect-timeout 5 --max-time 15 "$endpoint" >/dev/null
  done'

step "Wait for Prometheus to scrape $NODE exporters"
ssh -T "$GATEWAY_NODE" "set -Eeuo pipefail
  for attempt in \$(seq 1 12); do
    if curl -fsS --connect-timeout 5 --max-time 15 'http://127.0.0.1:9099/api/v1/targets?state=active' | jq -e --arg host '$NODE' '[.data.activeTargets[] | select(.labels.host == \$host and (.labels.job == \"host\" or .labels.job == \"cadvisor\"))] | ([.[] | select(.health == \"up\") | .labels.job] | unique | sort) == [\"cadvisor\", \"host\"]' >/dev/null; then
      exit 0
    fi
    sleep 5
  done
  exit 1" || die "Prometheus did not scrape both monitoring exporters for $NODE"

printf 'PASS monitoring-agent reconciled node=%s services=node-exporter,cadvisor\n' "$NODE"
