#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/monitoring-check"
mkdir -p "$RUN"
install_evidence_exit_trap 'Monitoring inventory check'
targets="$RUN/prometheus-active-targets.json"
receipt="$RUN/monitoring-inventory-drift.v1.json"

step 'Read deployed Prometheus target inventory without mutation'
ssh -T "$GATEWAY_NODE" \
  'curl -fsS --connect-timeout 5 --max-time 15 "http://127.0.0.1:9099/api/v1/targets?state=active"' \
  >"$targets"
chmod 600 "$targets"
"$ROOT/scripts/check-monitoring-inventory-drift.sh" \
  --inventory "$INVENTORY" --gdc-data-root "$GDC_DATA_ROOT" --targets "$targets" --output "$receipt"
printf 'PASS monitoring inventory check receipt=%s\n' "$receipt"
