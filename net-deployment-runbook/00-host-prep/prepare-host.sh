#!/usr/bin/env bash
set -Eeuo pipefail
usage() {
  cat <<'EOF'
Usage: sudo ./prepare-host.sh --role ROLE --monitoring-cidr CIDR --ssh-port PORT

ROLE: network-gpu | network-only | ml-only
EOF
}
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
ROLE=""; MONITORING_CIDR=""; PUBLIC_EDGE_CIDR=""; SSH_PORT=""; DRIVER_CHANGED=false
OPERATOR_USER="${SUDO_USER:-}"; MIN_DRIVER=580; ML_CLIENT_CIDR="${ML_CLIENT_CIDR:-}"; ML_CALLBACK_CIDR="${ML_CALLBACK_CIDR:-}"
while (($#)); do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    --monitoring-cidr) MONITORING_CIDR="$2"; shift 2;;
    --public-edge-cidr) PUBLIC_EDGE_CIDR="$2"; shift 2;;
    --ssh-port) SSH_PORT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done
[[ "$ROLE" =~ ^(network-gpu|network-only|ml-only)$ ]] || { echo "Invalid --role" >&2; exit 2; }
[[ -n "$MONITORING_CIDR" && -n "$OPERATOR_USER" ]] || { usage; exit 2; }
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid SSH port" >&2; exit 2; }
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
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq git rsync unzip zip zstd openssl age locales \
  python3 python3-yaml python3-requests python3-venv chrony fail2ban unattended-upgrades \
  smartmontools nvme-cli pciutils lsof net-tools iptables conntrack socat \
  ubuntu-drivers-common mokutil
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
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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

GPU_ROLE=false
[[ "$ROLE" == network-gpu || "$ROLE" == ml-only ]] && GPU_ROLE=true
if [[ "$GPU_ROLE" == true ]]; then
  driver_version=""
  if command -v nvidia-smi >/dev/null 2>&1; then
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)
  fi
  driver_major=${driver_version%%.*}
  if [[ "$driver_major" =~ ^[0-9]+$ ]] && (( driver_major >= MIN_DRIVER )); then
    status "KEEP  NVIDIA driver $driver_version"
  else
    if [[ "$driver_version" =~ ^[0-9]+([.][0-9]+)+$ ]]; then
      status "INSTALL  NVIDIA driver: $driver_version -> recommended R580+"
    else
      status "INSTALL  recommended NVIDIA R580+ driver; current driver is unavailable"
    fi
    while IFS= read -r dkms_version; do
      dkms_major=${dkms_version%%.*}
      if [[ "$dkms_major" =~ ^[0-9]+$ ]] && (( dkms_major < MIN_DRIVER )); then
        status "REMOVE  stale NVIDIA DKMS $dkms_version"
        dkms remove -m nvidia -v "$dkms_version" --all
      fi
    done < <(dkms status -m nvidia 2>/dev/null | sed -n 's#^nvidia/\([^,]*\),.*#\1#p' | sort -u)
    ubuntu-drivers install --gpgpu
    depmod -a
    update-initramfs -u
    DRIVER_CHANGED=true
  fi
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
  /srv/dai /srv/dai/shared /srv/dai/hf-cache /srv/dai/backups
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
MONITORING_CIDR=$MONITORING_CIDR
PUBLIC_EDGE_CIDR=$PUBLIC_EDGE_CIDR
ML_CLIENT_CIDR=$ML_CLIENT_CIDR
ML_CALLBACK_CIDR=$ML_CALLBACK_CIDR
SSH_PORT=$SSH_PORT
MIN_DRIVER=$MIN_DRIVER
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
  status "REBOOT  $HOST_NAME to activate the NVIDIA driver, then rerun prepare"
  exit 194
fi
