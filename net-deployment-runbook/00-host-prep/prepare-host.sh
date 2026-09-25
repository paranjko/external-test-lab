#!/usr/bin/env bash
set -Eeuo pipefail
usage() {
  cat <<'EOF'
Usage: sudo ./prepare-host.sh --role ROLE --monitoring-cidr CIDR --ssh-port PORT [--gateway-services true|false]

ROLE: network-gpu | network-only | ml-only
EOF
}
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
ROLE=""; MONITORING_CIDR=""; PUBLIC_EDGE_CIDR=""; SSH_PORT=""; GATEWAY_SERVICES=false; DRIVER_CHANGED=false
OPERATOR_USER="${SUDO_USER:-}"; MIN_DRIVER=580; ML_CLIENT_CIDR="${ML_CLIENT_CIDR:-}"; ML_CALLBACK_CIDR="${ML_CALLBACK_CIDR:-}"
while (($#)); do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --monitoring-cidr) MONITORING_CIDR="$2"; shift 2;;
    --public-edge-cidr) PUBLIC_EDGE_CIDR="$2"; shift 2;;
    --ssh-port) SSH_PORT="$2"; shift 2;;
    --gateway-services) GATEWAY_SERVICES="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done
[[ "$ROLE" =~ ^(network-gpu|network-only|ml-only)$ ]] || { echo "Invalid --role" >&2; exit 2; }
[[ -n "$MONITORING_CIDR" && -n "$OPERATOR_USER" ]] || { usage; exit 2; }
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid SSH port" >&2; exit 2; }
[[ "$GATEWAY_SERVICES" == true || "$GATEWAY_SERVICES" == false ]] || { echo "--gateway-services must be true or false" >&2; exit 2; }
# shellcheck source=/etc/os-release
source /etc/os-release
[[ "$ID" == ubuntu ]] || { echo "Ubuntu required" >&2; exit 1; }
case "$VERSION_ID" in 22.04|24.04|26.04) ;; *) echo "Supported: Ubuntu 22.04, 24.04, 26.04; got $VERSION_ID" >&2; exit 1;; esac
[[ "$(dpkg --print-architecture)" == amd64 ]] || { echo "amd64 required" >&2; exit 1; }
[[ "$MONITORING_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
  || { echo "Invalid IPv4 CIDR: $MONITORING_CIDR" >&2; exit 2; }
[[ -z "$PUBLIC_EDGE_CIDR" || "$PUBLIC_EDGE_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] \
  || { echo "Invalid public edge IPv4 CIDR: $PUBLIC_EDGE_CIDR" >&2; exit 2; }
[[ "$ROLE" != ml-only || "$ML_CLIENT_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] \
  || { echo 'ML client IPv4 CIDR was not derived' >&2; exit 2; }
[[ -z "$ML_CALLBACK_CIDR" || "$ML_CALLBACK_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] \
  || { echo 'ML callback IPv4 CIDR must be a /32' >&2; exit 2; }

GPU_ROLE=false
[[ "$ROLE" == network-gpu || "$ROLE" == ml-only ]] && GPU_ROLE=true
NVIDIA_DRIVER_VERSION=""; NVIDIA_DRIVER_MAJOR=""; NVIDIA_DRIVER_CANDIDATE=""
AMD_ACCELERATOR=false; AMD_NEEDS_PROVISIONING=false
if [[ "$GPU_ROLE" == true ]]; then
  accelerator_info="$("$(dirname "$0")/inspect-accelerator.sh")" || exit 1
  accelerator_vendor="$(awk -F= '$1 == "vendor" { print $2 }' <<<"$accelerator_info")"
  accelerator_readiness="$(awk -F= '$1 == "readiness" { print $2 }' <<<"$accelerator_info")"
  accelerator_pci_device_id="$(awk -F= '$1 == "pci_device_id" { print $2 }' <<<"$accelerator_info")"
  accelerator_architecture="$(awk -F= '$1 == "architecture" { print $2 }' <<<"$accelerator_info")"
  if [[ "$accelerator_vendor" == amd ]]; then
    [[ "${GDC_ACCELERATOR_VENDOR:-}" == amd && "${GDC_ACCELERATOR_ARCHITECTURE:-}" == gfx1201 ]] || {
      printf 'AMD GPU is visible but the generated JOIN profile does not select the supported gfx1201 host profile\n' >&2
      exit 1
    }
    [[ "$accelerator_pci_device_id" == 0x7550 ]] || {
      printf 'AMD GPU PCI identity changed after profile selection: expected=0x7550 current=%s; rerun JOIN inspection\n' \
        "${accelerator_pci_device_id:-unknown}" >&2
      exit 1
    }
    AMD_ACCELERATOR=true
    [[ "${GDC_ACCELERATOR_READINESS:-}" == provisioning || "${GDC_ACCELERATOR_READINESS:-}" == ready ]] || {
      printf 'AMD GPU profile has an invalid readiness state\n' >&2
      exit 1
    }
    [[ "$accelerator_readiness" != ready || "$accelerator_architecture" == "$GDC_ACCELERATOR_ARCHITECTURE" ]] || {
      printf 'AMD GPU architecture changed after profile selection: profile=%s current=%s; rerun JOIN inspection\n' \
        "$GDC_ACCELERATOR_ARCHITECTURE" "${accelerator_architecture:-unknown}" >&2
      exit 1
    }
    [[ "$accelerator_readiness" == "$GDC_ACCELERATOR_READINESS" ]] || {
      printf 'AMD GPU readiness changed after profile selection: profile=%s current=%s; rerun JOIN inspection\n' \
        "$GDC_ACCELERATOR_READINESS" "${accelerator_readiness:-unknown}" >&2
      exit 1
    }
    [[ "$GDC_ACCELERATOR_READINESS" != provisioning || "$VERSION_ID" == 24.04 ]] || {
      printf 'AMD gfx1201 provisioning requires the approved Ubuntu 24.04 ROCm profile; got %s %s\n' "$ID" "$VERSION_ID" >&2
      exit 1
    }
    [[ "${GDC_ACCELERATOR_READINESS:-}" == provisioning ]] && AMD_NEEDS_PROVISIONING=true
  elif command -v nvidia-smi >/dev/null 2>&1; then
    NVIDIA_DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)
  fi
  if [[ "$AMD_ACCELERATOR" == false ]]; then
    NVIDIA_DRIVER_MAJOR="${NVIDIA_DRIVER_VERSION%%.*}"
    if ! [[ "$NVIDIA_DRIVER_MAJOR" =~ ^[0-9]+$ ]] || (( NVIDIA_DRIVER_MAJOR < MIN_DRIVER )); then
      NVIDIA_DRIVER_CANDIDATE="$("$(dirname "$0")/select-nvidia-driver.sh" "$MIN_DRIVER")"
      [[ -n "$NVIDIA_DRIVER_CANDIDATE" ]] || exit 1
    fi
  fi
fi

LOG=/var/log/gdc-prepare.log
HOST_NAME="$(hostname)"
: >"$LOG"
exec 3>&1
status(){ printf '%s\n' "$*" >&3; }
on_error(){ local rc=$?; status "FAILED  $HOST_NAME at line $LINENO; details: $LOG"; exit "$rc"; }
trap on_error ERR
exec >>"$LOG" 2>&1
status "PREPARE  $HOST_NAME"
export DEBIAN_FRONTEND=noninteractive
ensure_packages() {
  local package missing=()
  for package in "$@"; do
    dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed \
      || missing+=("$package")
  done
  if (( ${#missing[@]} == 0 )); then
    status 'KEEP  required packages already installed'
    return 0
  fi
  apt-get update
  apt-get install -y --no-install-recommends "${missing[@]}"
}
ensure_packages \
  ca-certificates curl gnupg jq git rsync unzip zip zstd openssl age locales binutils \
  python3 python3-yaml python3-requests python3-venv chrony fail2ban unattended-upgrades \
  smartmontools nvme-cli pciutils lsof net-tools iptables conntrack socat \
  ubuntu-drivers-common mokutil

install_amd_rocm() {
  local installer=/tmp/gdc-amdgpu-install.deb
  local installer_url='https://repo.radeon.com/amdgpu-install/7.2.1/ubuntu/noble/amdgpu-install_7.2.1.70201-1_all.deb'
  local installer_sha256='4c0338a241c15b12c14eb3aeb4012ea0d55dba681737ea8482248041a16c2afa'
  local installer_package_version='30.30.1.0.30300100-2303411.24.04' installed_version=''
  [[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || {
    status "REFUSE  AMD gfx1201 requires the approved Ubuntu 24.04 ROCm profile; got $ID $VERSION_ID"
    return 1
  }
  ensure_packages python3-setuptools python3-wheel
  if command -v amdgpu-install >/dev/null 2>&1; then
    installed_version="$(dpkg-query -W -f='${Version}' amdgpu-install 2>/dev/null || true)"
    [[ "$installed_version" == "$installer_package_version" ]] || {
      status "REFUSE  installed amdgpu-install version ${installed_version:-unknown} does not match pinned $installer_package_version"
      return 1
    }
  else
    status 'INSTALL  pinned AMD ROCm installer 7.2.1'
    curl --fail --show-error --location --proto '=https' --tlsv1.2 "$installer_url" -o "$installer"
    printf '%s  %s\n' "$installer_sha256" "$installer" | sha256sum -c -
    apt-get install -y "$installer"
  fi
  status 'INSTALL  AMD graphics and ROCm usecase for gfx1201'
  amdgpu-install -y --usecase=graphics,rocm
  usermod -aG render,video "$OPERATOR_USER"
  DRIVER_CHANGED=true
}
install -d -m 0755 /etc/fail2ban/jail.d
cat >/etc/fail2ban/jail.d/gdc-sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = $SSH_PORT
banaction = iptables-multiport
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now chrony fail2ban
fail2ban-client -t
systemctl restart fail2ban
for _ in $(seq 1 30); do
  fail2ban-client ping >/dev/null 2>&1 && break
  sleep 1
done
fail2ban-client status sshd >/dev/null

locale-gen en_US.UTF-8 >/dev/null
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
if ! grep -Eq "^[^#]+[[:space:]]${HOSTNAME}([[:space:]]|$)" /etc/hosts; then
  printf '127.0.1.1 %s\n' "$HOSTNAME" >> /etc/hosts
fi

# Docker CE official repository.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
ensure_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
install -d -m 0755 /etc/docker
DAEMON_JSON=/etc/docker/daemon.json
DAEMON_TMP="$(mktemp)"
[[ -s "$DAEMON_JSON" ]] || echo '{}' >"$DAEMON_JSON"
jq '
  .["live-restore"] = true
  | .["log-driver"] = "local"
  | .["log-opts"] = {"max-size":"100m","max-file":"5"}
  | .["default-ulimits"].nofile = {
      "Name":"nofile",
      "Soft":1048576,
      "Hard":1048576
    }
' "$DAEMON_JSON" >"$DAEMON_TMP"
install -m 0644 "$DAEMON_TMP" "$DAEMON_JSON"
rm -f "$DAEMON_TMP"

# ubuntu-drivers binds the prebuilt NVIDIA modules to the kernel that runs at
# install time. A Host that already carries a newer kernel then boots without
# an NVIDIA module: nvidia-smi fails, every rerun reinstalls the same packages
# and asks for another reboot. Install the modules of the selected driver
# branch for every installed kernel that the archive serves.
ensure_nvidia_modules_for_installed_kernels() {
  local meta branch kernel package running refreshed=false
  meta="$(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-modules-nvidia-*' 2>/dev/null \
    | awk '$2 ~ /^ii/ && $1 ~ /^linux-modules-nvidia-[0-9]+(-server)?(-open)?-generic$/ {print $1; exit}' || true)"
  [[ -n "$meta" ]] || return 0
  branch="${meta#linux-modules-nvidia-}"; branch="${branch%-generic}"
  running="$(uname -r)"
  while IFS= read -r kernel; do
    [[ -n "$kernel" ]] || continue
    package="linux-modules-nvidia-${branch}-${kernel}"
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii'; then
      continue
    fi
    # This can be the first apt action of a run on an already prepared Host.
    if [[ "$refreshed" == false ]]; then
      apt-get update || status "WARN  package lists were not refreshed"
      refreshed=true
    fi
    if ! apt-cache show "$package" >/dev/null 2>&1; then
      status "SKIP  no NVIDIA $branch modules packaged for kernel $kernel"
      continue
    fi
    # The archive can pin the modules of an older kernel to a driver build
    # other than the installed one. Only that resolver refusal is skipped, and
    # only for a kernel the Host will not boot next; every other failure, and
    # any failure for the running or a newer kernel, still ends prepare.
    if [[ "$kernel" != "$running" ]] && dpkg --compare-versions "$kernel" lt "$running" \
      && ! apt-get install -s -o Debug::NoLocking=true "$package" >/dev/null 2>&1; then
      status "SKIP  NVIDIA $branch modules for older kernel $kernel do not resolve next to the installed driver"
      continue
    fi
    status "INSTALL  NVIDIA $branch modules for kernel $kernel"
    # Explicit, so the failure ends prepare in every calling context.
    apt-get install -y "$package" || return 1
    [[ "$kernel" != "$running" ]] || DRIVER_CHANGED=true
  done < <(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-[0-9]*-generic' 2>/dev/null \
    | awk '$2 ~ /^ii/ {sub(/^linux-image-/, "", $1); print $1}' || true)
}

if [[ "$AMD_ACCELERATOR" == true && "$AMD_NEEDS_PROVISIONING" == true ]]; then
  install_amd_rocm
elif [[ "$GPU_ROLE" == true && "$AMD_ACCELERATOR" == false ]]; then
  if [[ -z "$NVIDIA_DRIVER_CANDIDATE" ]]; then
    status "KEEP  NVIDIA driver $NVIDIA_DRIVER_VERSION"
    ensure_nvidia_modules_for_installed_kernels
  else
    if [[ "$NVIDIA_DRIVER_VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]]; then
      status "INSTALL  NVIDIA driver: $NVIDIA_DRIVER_VERSION -> $NVIDIA_DRIVER_CANDIDATE"
    else
      status "INSTALL  NVIDIA driver $NVIDIA_DRIVER_CANDIDATE; current driver is unavailable"
    fi
    while IFS= read -r dkms_version; do
      dkms_major=${dkms_version%%.*}
      if [[ "$dkms_major" =~ ^[0-9]+$ ]] && (( dkms_major < MIN_DRIVER )); then
        status "REMOVE  stale NVIDIA DKMS $dkms_version"
        dkms remove -m nvidia -v "$dkms_version" --all
      fi
    done < <((dkms status -m nvidia 2>/dev/null || true) | sed -n 's#^nvidia/\([^,]*\),.*#\1#p' | sort -u)
    ensure_packages "$NVIDIA_DRIVER_CANDIDATE"
    ensure_nvidia_modules_for_installed_kernels
    depmod -a
    update-initramfs -u
    DRIVER_CHANGED=true
  fi
  # The selected driver metapackage installs its matching utilities.
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
fi
systemctl enable --now containerd docker.socket
systemctl reset-failed docker.service || true
systemctl enable docker.service
systemctl restart docker.service

id "$OPERATOR_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$OPERATOR_USER"
usermod -aG docker "$OPERATOR_USER"
install -d -m 0750 -o "$OPERATOR_USER" -g "$OPERATOR_USER" \
  /srv/dai /srv/dai/shared /srv/dai/backups /srv/hf-cache
install -m 0644 "$(dirname "$0")/sysctl-gonka.conf" /etc/sysctl.d/99-gonka.conf
sysctl --system >/dev/null
cat >/etc/security/limits.d/90-gonka.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

install -d -m 0755 /etc/gonka
cat >/etc/gonka/host.env <<EOF
ROLE=$ROLE
GATEWAY_SERVICES=$GATEWAY_SERVICES
MONITORING_CIDR=$MONITORING_CIDR
PUBLIC_EDGE_CIDR=$PUBLIC_EDGE_CIDR
ML_CLIENT_CIDR=$ML_CLIENT_CIDR
ML_CALLBACK_CIDR=$ML_CALLBACK_CIDR
SSH_PORT=$SSH_PORT
MIN_DRIVER=$MIN_DRIVER
ACCELERATOR_VENDOR=${GDC_ACCELERATOR_VENDOR:-nvidia}
ACCELERATOR_ARCHITECTURE=${GDC_ACCELERATOR_ARCHITECTURE:-}
EOF
chmod 0600 /etc/gonka/host.env

# Filter before Docker DNAT. UFW is disabled because its INPUT rules do not
# reliably control ports published by Docker.
if command -v ufw >/dev/null 2>&1; then
  ufw --force disable
  systemctl disable ufw.service 2>/dev/null || true
fi
install -m 0755 "$(dirname "$0")/gonka-firewall.sh" /usr/local/sbin/gonka-firewall
install -m 0755 "$(dirname "$0")/gonka-firewall-rollback.sh" /usr/local/sbin/gonka-firewall-rollback
cat >/etc/systemd/system/gonka-firewall.service <<'EOF'
[Unit]
Description=GDC ingress firewall before Docker DNAT
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gonka-firewall
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl stop gonka-firewall-rollback.timer gonka-firewall-rollback.service 2>/dev/null || true
systemctl reset-failed gonka-firewall-rollback.service 2>/dev/null || true
systemd-run --unit=gonka-firewall-rollback --on-active=2m /usr/local/sbin/gonka-firewall-rollback
systemctl enable gonka-firewall.service
# The service is oneshot with RemainAfterExit. `enable --now` does not rerun it
# when host.env changes, leaving the live pre-DNAT rules stale.
systemctl restart gonka-firewall.service

status "PREPARED  $HOST_NAME"

if [[ "$DRIVER_CHANGED" == true ]]; then
  status "REBOOT  $HOST_NAME to activate the accelerator runtime, then rerun prepare"
  # 194 is an intentional operator action, not a failed preparation step.
  trap - ERR
  exit 194
fi
