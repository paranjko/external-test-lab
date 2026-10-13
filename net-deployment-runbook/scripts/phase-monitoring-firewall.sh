#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
[[ "$action" =~ ^(preview|apply)$ && $# -eq 1 ]] \
  || die 'expected: ops monitoring-firewall preview or apply'
run_id="${GDC_RUN_ID:-manual}"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
  || die 'GDC run id is unsafe for monitoring-firewall staging'
stage="/srv/dai/ops/gdc-monitoring-firewall-$run_id"
run="$GDC_HOME/runs/$run_id/monitoring-firewall-$action"
attempt="$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$run"

hosts=("${GDC_NODES[@]}")
for node in "${GDC_NODES[@]}"; do
  ml_host="$(node_ml_host "$node" || true)"
  [[ -z "$ml_host" ]] || hosts+=("$ml_host")
done

deploy_helper() {
  local host="$1"
  ssh -n "$host" "install -d -m 0700 '$stage/00-host-prep'"
  scp -q "$ROOT/00-host-prep/reconcile-monitoring-firewall.sh" \
    "$host:$stage/00-host-prep/" < /dev/null
  ssh -n "$host" "chmod 0700 '$stage/00-host-prep/reconcile-monitoring-firewall.sh'"
}

for host in "${hosts[@]}"; do
  deploy_helper "$host"
  preview="$(ssh -n "$host" "sudo '$stage/00-host-prep/reconcile-monitoring-firewall.sh' preview --monitoring-cidr '$MONITORING_CIDR'")" \
    || die "monitoring-firewall preview failed for $host"
  jq -e --arg host "$host" --arg cidr "$MONITORING_CIDR" '
    .schema == "gdc-monitoring-firewall/1" and .host != "" and .desired_monitoring_cidr == $cidr
    and (.current_monitoring_cidr | type == "string") and (.delta | type == "array") and .applied == false
  ' <<<"$preview" >/dev/null || die "monitoring-firewall preview receipt is invalid for $host"
  printf '%s\n' "$preview" >"$run/$host-preview-$attempt.json"
  current="$(jq -r '.current_monitoring_cidr' <<<"$preview")"
  delta_count="$(jq '.delta | length' <<<"$preview")"
  if [[ "$action" == preview || "$delta_count" == 0 ]]; then
    suffix=''
    [[ "$delta_count" != 0 ]] || suffix=' no-op'
    printf 'READY monitoring-firewall %s host=%s delta_fields=%s%s\n' "$action" "$host" "$delta_count" "$suffix"
    continue
  fi
  applied="$(ssh -n "$host" "sudo '$stage/00-host-prep/reconcile-monitoring-firewall.sh' apply --monitoring-cidr '$MONITORING_CIDR' --expected-current-cidr '$current'")" \
    || die "monitoring-firewall apply failed for $host"
  jq -e --arg host "$host" --arg cidr "$MONITORING_CIDR" '
    .schema == "gdc-monitoring-firewall/1" and .host != "" and .desired_monitoring_cidr == $cidr
    and .current_monitoring_cidr == $cidr and .applied == true and .outcome == "PASS" and (.delta | length) == 0
  ' <<<"$applied" >/dev/null || die "monitoring-firewall apply receipt is invalid for $host"
  printf '%s\n' "$applied" >"$run/$host-apply-$attempt.json"
  printf 'PASS monitoring-firewall apply host=%s\n' "$host"
done
