#!/usr/bin/env bash
set -Eeuo pipefail

# Report the hardware execution backend only. This script intentionally does
# not install a driver: an arbitrary package repository is not a trustworthy
# source for a network-attached ML runtime.
SYSFS_ROOT="${GDC_SYSFS_ROOT:-/sys}"
DEV_ROOT="${GDC_DEV_ROOT:-/dev}"
ROCMINFO="${GDC_ROCMINFO:-rocminfo}"

has_vendor() {
  local vendor
  for vendor in "$SYSFS_ROOT"/bus/pci/devices/*/vendor; do
    [[ -r "$vendor" && "$(<"$vendor")" == "$1" ]] && return 0
  done
  return 1
}

nvidia=false; amd=false
has_vendor 0x10de && nvidia=true
has_vendor 0x1002 && amd=true
if [[ "$nvidia" == true && "$amd" == true ]]; then
  echo 'accelerator inspection refuses a Host with both NVIDIA and AMD PCI GPUs; select one backend explicitly' >&2
  exit 1
fi
if [[ "$nvidia" == true ]]; then
  printf 'vendor=nvidia\n'
  exit 0
fi
if [[ "$amd" != true ]]; then
  echo 'no supported accelerator PCI device is visible' >&2
  exit 1
fi
[[ -e "$DEV_ROOT/kfd" ]] || { echo 'AMD GPU is visible but /dev/kfd is unavailable' >&2; exit 1; }
render_node="$(find "$DEV_ROOT/dri" -maxdepth 1 -type c -name 'renderD*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort | head -n1 || true)"
[[ -n "$render_node" ]] || { echo 'AMD GPU is visible but no DRM render node is available' >&2; exit 1; }
command -v "$ROCMINFO" >/dev/null 2>&1 || { echo 'AMD GPU is visible but rocminfo is unavailable' >&2; exit 1; }
rocm_info="$($ROCMINFO 2>/dev/null)" || { echo 'AMD GPU is visible but rocminfo cannot query it' >&2; exit 1; }
arch="$(awk '/^[[:space:]]*Name:[[:space:]]*gfx[[:alnum:]_]+$/ { print $2; exit }' <<<"$rocm_info")"
[[ -n "$arch" ]] || { echo 'AMD GPU is visible but rocminfo did not report a gfx target' >&2; exit 1; }
printf 'vendor=amd\narchitecture=%s\nrender_node=%s\n' "$arch" "$render_node"
