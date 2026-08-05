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

node4_address="$(getent ahostsv4 "$NODE4_PUBLIC_HOST" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
if [[ ! "$node4_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  node4_address="$(ssh -G gdc-node4 2>/dev/null | awk '$1 == "hostname" {print $2; exit}' || true)"
fi
[[ "$node4_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "cannot determine gdc-node4 public IPv4 from DNS or SSH config"
node4_ml_client_cidr="$node4_address/32"
node4_ml_address="$(getent ahostsv4 "$NODE4_ML_ENDPOINT" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
[[ "$node4_ml_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "cannot determine gdc-node4-ml IPv4"
node4_ml_callback_cidr="$node4_ml_address/32"

ready_hosts=(); reboot_hosts=(); skipped_hosts=(); failed_hosts=()
for host in gdc-node0 gdc-node1 gdc-node2 gdc-node3 gdc-node4 gdc-node4-ml; do
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
  role=network-gpu
  [[ "$host" == gdc-node4 ]] && role=network-only
  [[ "$host" == gdc-node4-ml ]] && role=ml-only
  index="${host#gdc-node}"
  [[ "$host" == gdc-node4-ml ]] && index=4
  data_root_var="GDC_NODE${index}_DATA_ROOT"
  storage_check='true'
  if [[ -n "${!data_root_var:-}" ]]; then
    [[ "${!data_root_var}" =~ ^/[-A-Za-z0-9_./]+$ ]] || die "$data_root_var must be an absolute safe path"
    storage_check='mountpoint -q /var/lib/docker && mountpoint -q /var/lib/containerd'
  fi
  callback_check='true'
  [[ "$host" == gdc-node4 ]] && callback_check="sudo grep -qx 'ML_CALLBACK_CIDR=$node4_ml_callback_cidr' /etc/gonka/host.env"
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
  if ssh "$host" "sudo test -s /etc/gonka/host.env && sudo grep -qx 'ROLE=$role' /etc/gonka/host.env && $callback_check && sudo /tmp/gdc-host-prep/verify-host.sh --role '$role' && sudo sh -c '$storage_check'" >/dev/null 2>&1; then
    echo "READY  $host"
    ready_hosts+=("$host")
    continue
  fi
  remote_env=()
  [[ "$role" == ml-only ]] && remote_env+=("ML_CLIENT_CIDR='$node4_ml_client_cidr'")
  [[ "$host" == gdc-node4 ]] && remote_env+=("ML_CALLBACK_CIDR='$node4_ml_callback_cidr'")
  if [[ -n "${!data_root_var:-}" ]]; then
    remote_env+=("GONKA_DATA_ROOT_BACKING='${!data_root_var}'")
  fi
  if ssh -T "$host" "sudo ${remote_env[*]} /tmp/gdc-host-prep/prepare-host.sh --role '$role' --monitoring-cidr '$MONITORING_CIDR' --meter-edge-cidr '$METER_EDGE_CIDR' --ssh-port '$ssh_port'"; then
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
