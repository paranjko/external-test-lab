#!/usr/bin/env bash
set -Eeuo pipefail

# Report the hardware execution backend only. This script intentionally does
# not install a driver: an arbitrary package repository is not a trustworthy
# source for a network-attached ML runtime.
SYSFS_ROOT="${GDC_SYSFS_ROOT:-/sys}"
DEV_ROOT="${GDC_DEV_ROOT:-/dev}"
ROCMINFO="${GDC_ROCMINFO:-rocminfo}"
OS_RELEASE="${GDC_OS_RELEASE:-/etc/os-release}"
UNAME="${GDC_UNAME:-uname}"
DPKG_QUERY="${GDC_DPKG_QUERY:-dpkg-query}"

has_vendor() {
  local vendor class
  for vendor in "$SYSFS_ROOT"/bus/pci/devices/*/vendor; do
    class="${vendor%/vendor}/class"
    [[ -r "$vendor" && -r "$class" && "$(<"$vendor")" == "$1" && "$(<"$class")" =~ ^0x03 ]] && return 0
  done
  return 1
}

amd_pci_device_id() {
  local vendor device class
  for vendor in "$SYSFS_ROOT"/bus/pci/devices/*/vendor; do
    [[ -r "$vendor" && "$(<"$vendor")" == 0x1002 ]] || continue
    device="${vendor%/vendor}/device"
    class="${vendor%/vendor}/class"
    [[ -r "$device" && -r "$class" && "$(<"$class")" =~ ^0x03 ]] || continue
    tr '[:upper:]' '[:lower:]' <"$device"
    return 0
  done
  return 1
}

package_field() {
  local package="$1" field="$2" value status
  if ! command -v "$DPKG_QUERY" >/dev/null 2>&1; then printf 'unreadable'; return; fi
  set +e
  value="$($DPKG_QUERY -W -f="\${$field}" "$package" 2>/dev/null)"; status=$?
  set -e
  if ((status == 1)) && [[ -z "$value" ]]; then value=absent
  elif ((status != 0)) || [[ -z "$value" ]]; then value=unreadable
  fi
  printf '%s' "$value"
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
amd_device_id="$(amd_pci_device_id || true)"
[[ "$amd_device_id" =~ ^0x[0-9a-f]{4}$ ]] || { echo 'AMD GPU is visible but its PCI device ID is unavailable' >&2; exit 1; }
os_id="$(awk -F= '$1 == "ID" {gsub(/^"|"$/, "", $2); print $2; exit}' "$OS_RELEASE" 2>/dev/null || true)"
os_version_id="$(awk -F= '$1 == "VERSION_ID" {gsub(/^"|"$/, "", $2); print $2; exit}' "$OS_RELEASE" 2>/dev/null || true)"
kernel_release="$($UNAME -r 2>/dev/null || true)"
amdrocm_status="$(package_field amdrocm Status)"
amdrocm_version="$(package_field amdrocm Version)"
rocm_core_status="$(package_field rocm-core Status)"
rocm_core_version="$(package_field rocm-core Version)"
amdgpu_install_status="$(package_field amdgpu-install Status)"
amdgpu_install_version="$(package_field amdgpu-install Version)"
printf 'vendor=amd\npci_device_id=%s\nos_id=%s\nos_version_id=%s\nkernel_release=%s\namdrocm_status=%s\namdrocm_version=%s\nrocm_core_status=%s\nrocm_core_version=%s\namdgpu_install_status=%s\namdgpu_install_version=%s\n' \
  "$amd_device_id" "$os_id" "$os_version_id" "$kernel_release" "$amdrocm_status" "$amdrocm_version" "$rocm_core_status" "$rocm_core_version" "$amdgpu_install_status" "$amdgpu_install_version"
if [[ ! -e "$DEV_ROOT/kfd" ]] || ! command -v "$ROCMINFO" >/dev/null 2>&1; then
  printf 'readiness=provisioning\n'
  exit 0
fi
render_node="$(find "$DEV_ROOT/dri" -maxdepth 1 -type c -name 'renderD*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort | head -n1 || true)"
[[ -n "$render_node" ]] || { echo 'AMD GPU is visible but no DRM render node is available' >&2; exit 1; }
rocm_info="$($ROCMINFO 2>/dev/null)" || { echo 'AMD GPU is visible but rocminfo cannot query it' >&2; exit 1; }
arch="$(awk '/^[[:space:]]*Name:[[:space:]]*gfx[[:alnum:]_]+[[:space:]]*$/ { print $2; exit }' <<<"$rocm_info")"
[[ -n "$arch" ]] || { echo 'AMD GPU is visible but rocminfo did not report a gfx target' >&2; exit 1; }
kfd_group_id="$(stat -c %g "$DEV_ROOT/kfd")"
render_group_id="$(stat -c %g "$DEV_ROOT/dri/$render_node")"
[[ "$kfd_group_id" =~ ^[0-9]+$ && "$render_group_id" =~ ^[0-9]+$ ]] || { echo 'AMD device group IDs are unavailable' >&2; exit 1; }
printf 'readiness=ready\narchitecture=%s\nrender_node=%s\nkfd_group_id=%s\nrender_group_id=%s\n' \
  "$arch" "$render_node" "$kfd_group_id" "$render_group_id"
