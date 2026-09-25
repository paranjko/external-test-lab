#!/usr/bin/env bash
set -Eeuo pipefail

# Provision the account that owns the isolated PR-preview Docker daemon. Run
# this script on the preview host as root. The trusted root-owned prerequisite
# helper reconciles the required packages first, so a clean Host needs no
# manual uidmap or rootless-Docker preparation.

PREVIEW_USER="${PREVIEW_USER:-preview}"
PREVIEW_ROOT="${PREVIEW_ROOT:-/srv/preview}"
PREVIEW_RANGE_SIZE=65536
ROOTLESS_PREREQUISITES_HELPER="${ROOTLESS_PREREQUISITES_HELPER:-/usr/local/lib/gdc-preview/install-rootless-prerequisites.sh}"
action="${1:-provision}"
if [[ $# -gt 1 ]]; then
  echo 'usage: user-preview.sh [provision|verify]' >&2
  exit 2
fi
[[ "$action" =~ ^(provision|verify)$ ]] || {
  echo 'usage: user-preview.sh [provision|verify]' >&2
  exit 2
}

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || die 'run as root'
[[ "$PREVIEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'PREVIEW_USER is invalid'
[[ "$PREVIEW_ROOT" = /* && "$PREVIEW_ROOT" != / && "$PREVIEW_ROOT" != *..* ]] \
  || die 'PREVIEW_ROOT must be an absolute non-root path without ..'

validate_key() {
  local key="$1"
  [[ -n "$key" ]] || die 'set PREVIEW_AUTHORIZED_KEY to one SSH public key'
  [[ "$key" != *$'\n'* && "$key" != *$'\r'* ]] \
    || die 'PREVIEW_AUTHORIZED_KEY must contain exactly one line'
  [[ "$key" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] \
    || die 'PREVIEW_AUTHORIZED_KEY is not an accepted SSH public key'
}

require_rootless_prerequisites() {
  [[ -x "$ROOTLESS_PREREQUISITES_HELPER" && ! -L "$ROOTLESS_PREREQUISITES_HELPER" ]] \
    || die 'trusted rootless prerequisite helper is unavailable'
  "$ROOTLESS_PREREQUISITES_HELPER"
  command -v dockerd-rootless-setuptool.sh >/dev/null \
    || die 'Docker rootless extras are unavailable after prerequisite reconciliation'
  command -v newuidmap >/dev/null \
    || die 'uidmap newuidmap is unavailable after prerequisite reconciliation'
  command -v newgidmap >/dev/null \
    || die 'uidmap newgidmap is unavailable after prerequisite reconciliation'
  [[ "$(stat -fc %T /sys/fs/cgroup)" == cgroup2fs ]] \
    || die 'rootless preview requires cgroup v2 for enforceable resource limits'
  command -v loginctl >/dev/null || die 'systemd-logind is required for a persistent rootless Docker service'
  command -v systemctl >/dev/null || die 'systemctl is required for a persistent rootless Docker service'
}

ensure_user_systemd_manager() {
  local uid="$1" bus
  bus="/run/user/$uid/bus"
  systemctl start "user@$uid.service"
  for _ in {1..10}; do
    [[ -S "$bus" ]] && return 0
    sleep 1
  done
  die "preview user systemd manager did not expose its bus: $bus"
}

next_subid_start() {
  local file="$1" maximum=99999 start count end
  while IFS=: read -r _ start count; do
    [[ "$start" =~ ^[0-9]+$ && "$count" =~ ^[0-9]+$ ]] || continue
    end=$((start + count - 1))
    (( end > maximum )) && maximum=$end
  done <"$file"
  printf '%s\n' "$((maximum + 1))"
}

ensure_subordinate_range() {
  local file="$1" start
  grep -Eq "^${PREVIEW_USER}:[0-9]+:[0-9]+$" "$file" && return 0
  start="$(next_subid_start "$file")"
  printf '%s:%s:%s\n' "$PREVIEW_USER" "$start" "$PREVIEW_RANGE_SIZE" >>"$file"
}

install_key() {
  local key="$1" destination="/home/$PREVIEW_USER/.ssh/authorized_keys"
  install -d -o "$PREVIEW_USER" -g "$PREVIEW_USER" -m 0700 "/home/$PREVIEW_USER/.ssh"
  if [[ -e "$destination" ]]; then
    [[ ! -L "$destination" ]] || die 'preview authorized_keys must not be a symbolic link'
    if grep -Fxq "$key" "$destination"; then
      return 0
    fi
  else
    install -o "$PREVIEW_USER" -g "$PREVIEW_USER" -m 0600 /dev/null "$destination"
  fi
  printf '%s\n' "$key" >>"$destination"
  chown "$PREVIEW_USER:$PREVIEW_USER" "$destination"
}

verify() {
  local uid runtime docker_socket controllers
  getent passwd "$PREVIEW_USER" >/dev/null || die "user $PREVIEW_USER is absent"
  id -nG "$PREVIEW_USER" | tr ' ' '\n' | grep -Fx docker >/dev/null \
    && die 'preview user must not belong to the privileged docker group'
  grep -Eq "^${PREVIEW_USER}:[0-9]+:[1-9][0-9]*$" /etc/subuid \
    || die 'preview user has no subordinate UID range'
  grep -Eq "^${PREVIEW_USER}:[0-9]+:[1-9][0-9]*$" /etc/subgid \
    || die 'preview user has no subordinate GID range'
  uid="$(id -u "$PREVIEW_USER")"
  runtime="/run/user/$uid"
  docker_socket="$runtime/docker.sock"
  [[ -S "$docker_socket" ]] || die "rootless Docker socket is absent: $docker_socket"
  controllers="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
  [[ -r "$controllers" ]] || die 'preview user has no delegated cgroup controllers'
  if ! grep -qw memory "$controllers" || ! grep -qw pids "$controllers"; then
    die 'preview user needs delegated memory and pids cgroup controllers'
  fi
  for path in "$PREVIEW_ROOT" "$PREVIEW_ROOT/releases" "$PREVIEW_ROOT/control" "$PREVIEW_ROOT/cache"; do
    [[ -d "$path" && ! -L "$path" ]] || die "required preview directory is absent or unsafe: $path"
    [[ "$(stat -c %U "$path")" == "$PREVIEW_USER" ]] || die "preview directory has an unexpected owner: $path"
  done
  runuser -u "$PREVIEW_USER" -- env DOCKER_HOST="unix://$docker_socket" docker info \
    --format '{{.CgroupDriver}} {{range .SecurityOptions}}{{.}} {{end}}' | \
    grep -Eq '^systemd .*name=rootless' \
    || die 'preview Docker daemon is not rootless with the systemd cgroup driver'
  printf 'READY preview_user=%s preview_root=%s docker_socket=%s\n' \
    "$PREVIEW_USER" "$PREVIEW_ROOT" "$docker_socket"
}

if [[ "$action" == verify ]]; then
  verify
  exit 0
fi

validate_key "${PREVIEW_AUTHORIZED_KEY:-}"
require_rootless_prerequisites

if ! getent passwd "$PREVIEW_USER" >/dev/null; then
  useradd --create-home --user-group --shell /bin/bash "$PREVIEW_USER"
fi
ensure_subordinate_range /etc/subuid
ensure_subordinate_range /etc/subgid
install_key "$PREVIEW_AUTHORIZED_KEY"

uid="$(id -u "$PREVIEW_USER")"
loginctl enable-linger "$PREVIEW_USER"
ensure_user_systemd_manager "$uid"
install -d -o "$PREVIEW_USER" -g "$PREVIEW_USER" -m 0750 \
  "$PREVIEW_ROOT" "$PREVIEW_ROOT/releases" "$PREVIEW_ROOT/cache" "$PREVIEW_ROOT/control"
install -d -o "$PREVIEW_USER" -g "$PREVIEW_USER" -m 0700 \
  "$PREVIEW_ROOT/control/runtime" "$PREVIEW_ROOT/control/registry" "$PREVIEW_ROOT/control/staging"

if [[ ! -S "/run/user/$uid/docker.sock" ]]; then
  runuser -u "$PREVIEW_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    dockerd-rootless-setuptool.sh install
fi
runuser -u "$PREVIEW_USER" -- env \
  XDG_RUNTIME_DIR="/run/user/$uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
  systemctl --user enable --now docker

verify
