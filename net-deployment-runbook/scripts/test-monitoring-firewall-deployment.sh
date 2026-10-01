#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
helper="$ROOT/00-host-prep/reconcile-monitoring-firewall.sh"
phase="$ROOT/scripts/phase-monitoring-firewall.sh"

bash -n "$helper"
bash -n "$phase"
grep -Fq 'monitoring CIDR changed after preview; refusing stale apply' "$helper"
grep -Fq 'systemctl restart gonka-firewall.service' "$helper"
grep -Fq 'iptables -w -t mangle -S GONKA_INGRESS' "$helper"
grep -Fq 'node_ml_host "$node"' "$phase"
grep -Fq 'ops monitoring-firewall preview or apply' "$phase"
grep -Fq -- '--expected-current-cidr' "$phase"
grep -Fq 'ops monitoring-firewall preview|apply' "$ROOT/gdc.sh"
grep -Fq 'ops-monitoring-firewall-$2' "$ROOT/gdc.sh"
printf 'PASS GDC monitoring firewall deployment contract\n'
