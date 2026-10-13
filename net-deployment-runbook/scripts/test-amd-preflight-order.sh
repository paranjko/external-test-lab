#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
prepare="$ROOT/00-host-prep/prepare-host.sh"
preflight_line="$(grep -n -m1 'accelerator_info=.*inspect-accelerator.sh' "$prepare" | cut -d: -f1)"
driver_preflight_line="$(grep -n -m1 'select-nvidia-driver.sh' "$prepare" | cut -d: -f1)"
log_line="$(grep -n -m1 '^LOG=/var/log/gdc-prepare.log' "$prepare" | cut -d: -f1)"
packages_line="$(grep -n -m1 '^ensure_packages' "$prepare" | cut -d: -f1)"
[[ "$preflight_line" =~ ^[0-9]+$ && "$driver_preflight_line" =~ ^[0-9]+$ && "$log_line" =~ ^[0-9]+$ && "$packages_line" =~ ^[0-9]+$ ]] || {
  echo 'accelerator preflight order anchors are missing' >&2
  exit 1
}
(( preflight_line < log_line && preflight_line < packages_line && driver_preflight_line < log_line && driver_preflight_line < packages_line )) || {
  echo 'accelerator preflight occurs after a Host mutation boundary' >&2
  exit 1
}
printf 'PASS accelerator release and driver preflight occur before Host preparation mutations\n'
