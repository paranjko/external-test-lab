#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
step "Resolve immutable OCI references for $GDC_RELEASE_PROFILE"
resolved_lock="$ROOT/state/resolved-images/$GDC_RELEASE_PROFILE.lock"
GDC_RESOLVED_IMAGE_LOCK='' "$ROOT/scripts/resolve-images.sh" "$resolved_lock" >/dev/null
export GDC_RESOLVED_IMAGE_LOCK="$resolved_lock"
load_profiles
record_phase_profile prepare

ready_hosts=(); reboot_hosts=(); skipped_hosts=(); failed_hosts=()
hosts=("${GDC_NODES[@]}")
for node in "${GDC_NODES[@]}"; do
  ml_host="$(node_ml_host "$node" || true)"
  [[ -z "$ml_host" ]] || hosts+=("$ml_host")
done
for host in "${hosts[@]}"; do
  if host_is_skipped "$host"; then
    echo "SKIP  $host is excluded by GDC_SKIP_HOSTS"
    skipped_hosts+=("$host")
    continue
  fi
  if ! ssh_ready "$host"; then
    echo "SKIP  $host is unreachable"
    skipped_hosts+=("$host")
    continue
  fi
  network_node="$(node_for_ml_host "$host" || true)"
  role=network-gpu
  if [[ -n "$network_node" ]]; then
    role=ml-only
  elif [[ -n "$(node_ml_host "$host" || true)" ]]; then
    role=network-only
  fi
  callback_check='true'
  if [[ "$role" == network-only ]]; then
    ml_host="$(node_ml_host "$host")"
    ml_address="$(ssh -G "$ml_host" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
    [[ "$ml_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "cannot determine network GPU IPv4 for $host from SSH alias $ml_host"
    callback_check="sudo grep -qx 'ML_CALLBACK_CIDR=$ml_address/32' /etc/gonka/host.env"
  fi
  gateway_services=false
  [[ "$host" == "$GATEWAY_NODE" ]] && gateway_services=true
  ssh_port="$(ssh -G "$host" 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
  if [[ ! "$ssh_port" =~ ^[0-9]+$ ]]; then
    echo "FAILED  $host: cannot determine SSH port"
    failed_hosts+=("$host")
    continue
  fi
  step "Prepare $host"
  if ! tar -C "$ROOT/00-host-prep" -cf - . | ssh "$host" 'rm -rf /tmp/gdc-host-prep && mkdir -p /tmp/gdc-host-prep && tar -C /tmp/gdc-host-prep -xf -'; then
    echo "FAILED  $host: cannot transfer host-prep files"
    failed_hosts+=("$host")
    continue
  fi
  if ssh "$host" "sudo test -s /etc/gonka/host.env && sudo grep -qx 'ROLE=$role' /etc/gonka/host.env && sudo grep -qx 'GATEWAY_SERVICES=$gateway_services' /etc/gonka/host.env && $callback_check && sudo /tmp/gdc-host-prep/verify-host.sh --role '$role'" >/dev/null 2>&1; then
    echo "READY  $host"
    ready_hosts+=("$host")
    continue
  fi
  remote_env=()
  if [[ "$role" == ml-only ]]; then
    client_address="$(getent ahostsv4 "$(node_public_host "$network_node")" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    if [[ ! "$client_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      client_address="$(ssh -G "$network_node" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
    fi
    [[ "$client_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "cannot determine ML client IPv4 for $network_node"
    remote_env+=("ML_CLIENT_CIDR='$client_address/32'")
  fi
  if [[ "$role" == network-only ]]; then
    remote_env+=("ML_CALLBACK_CIDR='$ml_address/32'")
  fi
  if ssh -T "$host" "sudo ${remote_env[*]} /tmp/gdc-host-prep/prepare-host.sh --role '$role' --monitoring-cidr '$MONITORING_CIDR' --public-edge-cidr '$PUBLIC_EDGE_CIDR' --ssh-port '$ssh_port' --gateway-services '$gateway_services'"; then
    prepare_rc=0
  else
    prepare_rc=$?
  fi
  if (( prepare_rc == 194 )); then
    reboot_hosts+=("$host")
    continue
  fi
  if (( prepare_rc != 0 )); then
    echo "FAILED  $host: prepare exited $prepare_rc; details: /var/log/gdc-prepare.log"
    failed_hosts+=("$host")
    continue
  fi
  if ! verify_output=$(ssh -o ConnectTimeout=10 "$host" "sudo /tmp/gdc-host-prep/verify-host.sh --role '$role'" 2>&1); then
    printf 'FAILED  %s verification:\n%s\n' "$host" "$verify_output"
    failed_hosts+=("$host")
    continue
  fi
  if ! ssh -o ConnectTimeout=10 "$host" \
    "sudo systemctl stop gonka-firewall-rollback.timer && { sudo systemctl reset-failed gonka-firewall-rollback.service 2>/dev/null || true; }"; then
    echo "FAILED  $host: firewall rollback could not be cancelled"
    failed_hosts+=("$host")
    continue
  fi
  echo "READY  $host"
  ready_hosts+=("$host")
done

printf '\n== Host preparation summary ==\n'
printf 'READY   %s\n' "${ready_hosts[*]:-none}"
printf 'REBOOT  %s\n' "${reboot_hosts[*]:-none}"
printf 'SKIP    %s\n' "${skipped_hosts[*]:-none}"
printf 'FAILED  %s\n' "${failed_hosts[*]:-none}"
(( ${#failed_hosts[@]} == 0 )) || exit 1
(( ${#reboot_hosts[@]} == 0 )) || exit 194
