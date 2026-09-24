#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
if [[ -n "${GDC_JOIN_PROFILE:-}" ]]; then
  step 'Use immutable images bound by the generated Join Profile'
else
  step "Resolve immutable OCI references for $GDC_RELEASE_PROFILE"
  resolved_lock="$STATE/resolved-images/$GDC_RELEASE_PROFILE.lock"
  GDC_RESOLVED_IMAGE_LOCK='' "$ROOT/scripts/resolve-images.sh" "$resolved_lock" >/dev/null
  export GDC_RESOLVED_IMAGE_LOCK="$resolved_lock"
  load_profiles
fi
record_phase_profile prepare
# run_phase exports GDC_RUN_ID for managed invocations. load_project assigns
# the established timestamped manual run ID for direct phase execution.
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/prepare"
mkdir -p "$RUN"
chmod 0700 "$RUN"

ready_hosts=(); reboot_hosts=(); skipped_hosts=(); failed_hosts=()
append_accelerator_remote_env() {
  local role="$1"
  [[ -n "${GDC_JOIN_PROFILE:-}" && ( "$role" == network-gpu || "$role" == ml-only ) ]] || return 0
  remote_env+=("GDC_ACCELERATOR_VENDOR='$ACCELERATOR_VENDOR'" "GDC_ACCELERATOR_ARCHITECTURE='$ACCELERATOR_ARCHITECTURE'" "GDC_ACCELERATOR_READINESS='$ACCELERATOR_READINESS'")
}

revalidate_join_accelerator() {
  local host="$1" role="$2" expected_vendor evidence_dir inspection inspection_tmp receipt expected actual
  [[ -n "${GDC_JOIN_PROFILE:-}" && ( "$role" == network-gpu || "$role" == ml-only ) ]] || return 0
  if jq -e '.spec.target | has("accelerator")' "$GDC_JOIN_PROFILE" >/dev/null; then
    expected_vendor="$(jq -er '.spec.target.accelerator.vendor' "$GDC_JOIN_PROFILE")" || return 1
  else
    # join-profile validation admits this shape only for historical v1
    # recovery, and profile.sh maps that validated contract to NVIDIA.
    [[ "${ACCELERATOR_VENDOR:-}" == nvidia ]] || return 1
    return 0
  fi
  [[ "$expected_vendor" == amd ]] || return 0

  evidence_dir="$RUN/accelerator-revalidation/$host"
  mkdir -p "$evidence_dir"
  chmod 0700 "$evidence_dir"
  inspection="$evidence_dir/inspection.env"
  receipt="$evidence_dir/receipt.json"
  inspection_tmp="$(mktemp "$RUN/.accelerator-inspection.XXXXXX")"
  if ! ssh -T "$host" 'bash -s' <"$ROOT/00-host-prep/inspect-accelerator.sh" >"$inspection_tmp"; then
    rm -f "$inspection_tmp"
    printf 'FAILED  %s: fresh accelerator inspection failed before Host preparation\n' "$host"
    return 1
  fi
  if ! "$ROOT/scripts/select-accelerator-profile.sh" --inspection "$inspection_tmp" --output "$receipt"; then
    rm -f "$inspection_tmp" "$receipt"
    printf 'FAILED  %s: fresh accelerator inspection no longer selects the generated profile\n' "$host"
    return 1
  fi
  install -m 0600 "$inspection_tmp" "$inspection"
  rm -f "$inspection_tmp"
  chmod 0600 "$receipt"
  expected="$(jq -Sc '.spec.target.accelerator' "$GDC_JOIN_PROFILE")" || return 1
  actual="$(jq -Sc '.' "$receipt")" || return 1
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAILED  %s: accelerator receipt changed after JOIN profile generation; evidence: %s\n' \
      "$host" "$evidence_dir"
    return 1
  fi
  printf 'BOUND  %s accelerator receipt matches generated JOIN profile; evidence: %s\n' "$host" "$evidence_dir"
}

prepare_nodes=("${GDC_NODES[@]}")
explicit_hosts=false
if [[ -n "${GDC_PREPARE_HOSTS:-}" ]]; then
  explicit_hosts=true
  read -r -a prepare_nodes <<<"$GDC_PREPARE_HOSTS"
  for node in "${prepare_nodes[@]}"; do
    topology_contains_node "$node" || die "prepare expects an alias from GDC_NODE_ALIASES, got: $node"
  done
fi
hosts=("${prepare_nodes[@]}")
for node in "${prepare_nodes[@]}"; do
  ml_host="$(node_ml_host "$node" || true)"
  [[ -z "$ml_host" ]] || hosts+=("$ml_host")
done
for host in "${hosts[@]}"; do
  if ! ssh_ready "$host"; then
    if [[ "$explicit_hosts" == true ]]; then
      echo "FAILED  $host: SSH is unavailable; cannot prepare the requested Host"
      failed_hosts+=("$host")
      continue
    fi
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
  if ! revalidate_join_accelerator "$host" "$role"; then
    failed_hosts+=("$host")
    continue
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
  firewall_check='true'
  if [[ "$gateway_services" == true ]]; then
    firewall_check="sudo iptables -w -t mangle -S GONKA_INGRESS | grep -Fq -- '-s $PUBLIC_EDGE_CIDR -p tcp -m multiport --dports 8000,9099,18080,18085 -j ACCEPT' && ! sudo iptables -w -t mangle -S GONKA_INGRESS | grep -Fq -- '--dports 3000,8000,8081,8082'"
  fi
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
  # A declared portable runtime satisfies the ADX/BMI2 check. The chain images
  # are replaced only under a generated JOIN profile, and profile.sh refuses a
  # declaration of one image without the other.
  verify_host_args="--role '$role'"
  if [[ -n "${GDC_JOIN_PROFILE:-}" && -n "${GDC_PORTABLE_CORE_IMAGE:-}" && -n "${GDC_PORTABLE_DAPI_IMAGE:-}" ]]; then
    verify_host_args="$verify_host_args --portable-runtime"
  fi
  if ssh "$host" "sudo test -s /etc/gonka/host.env && sudo grep -qx 'ROLE=$role' /etc/gonka/host.env && sudo grep -qx 'GATEWAY_SERVICES=$gateway_services' /etc/gonka/host.env && $callback_check && $firewall_check && sudo /tmp/gdc-host-prep/verify-host.sh $verify_host_args" >/dev/null 2>&1; then
    echo "READY  $host"
    ready_hosts+=("$host")
    continue
  fi
  remote_env=()
  append_accelerator_remote_env "$role"
  if [[ "$role" == ml-only ]]; then
    # The ML host is contacted by the network Host, not by its public edge
    # hostname. Prefer the SSH endpoint and use public DNS only as a fallback.
    client_address="$(ssh -G "$network_node" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}' || true)"
    if [[ ! "$client_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      client_address="$(getent ahostsv4 "$(node_public_host "$network_node")" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
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
  if ! verify_output=$(ssh -o ConnectTimeout=10 "$host" "sudo /tmp/gdc-host-prep/verify-host.sh $verify_host_args" 2>&1); then
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
