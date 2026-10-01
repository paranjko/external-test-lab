#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }

if [[ -e /var/run/reboot-required ]]; then
  echo 'REBOOT_REQUIRED pending_host_package_updates'
  exit 194
fi

if [[ -n "$(dpkg --audit 2>&1 || true)" ]]; then
  echo 'OPERATOR_ACTION_REQUIRED package_manager_unresolved'
  exit 195
fi

if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker.service; then
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [[ -z "$docker_root" || ! -d "$docker_root" || ! -d "$docker_root/tmp" ]]; then
    echo 'OPERATOR_ACTION_REQUIRED docker_storage_unhealthy'
    exit 195
  fi
fi

echo 'READY Host readiness preflight'
