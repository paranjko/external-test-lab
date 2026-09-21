#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --inspection FILE --output FILE" >&2; }
die() { printf 'accelerator_profile_%s: %s\n' "$1" "$2" >&2; exit 1; }

inspection=''; output=''
while (($#)); do
  case "$1" in
    --inspection) inspection="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$inspection" && -n "$output" ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$(awk -F= '$1 == "vendor" {print $2}' "$inspection")"
[[ "$(grep -c '^vendor=' "$inspection")" == 1 ]] || die inspection 'inspection must contain exactly one vendor'

case "$vendor" in
  nvidia)
    [[ "$(wc -l <"$inspection" | tr -d ' ')" == 1 ]] || die inspection 'NVIDIA inspection contains unexpected fields'
    receipt='{"schema_version":1,"vendor":"nvidia","compose_variant":"nvidia","qualification_backend":"cuda"}'
    ;;
  amd)
    pci_device_id="$(awk -F= '$1 == "pci_device_id" {print $2}' "$inspection")"
    readiness="$(awk -F= '$1 == "readiness" {print $2}' "$inspection")"
    [[ "$pci_device_id" =~ ^0x[0-9a-f]{4}$ ]] || die inspection 'AMD PCI device ID is missing or invalid'
    [[ "$readiness" =~ ^(provisioning|ready)$ ]] || die inspection 'AMD readiness is missing or invalid'
    profile="$ROOT/profiles/amd-mlnode/gfx1201.json"
    [[ -r "$profile" ]] || die unsupported 'no pinned AMD MLNode profile for gfx1201'
    jq -e --arg pci "$pci_device_id" '
      .schema_version == 1 and .kind == "external-test-lab-amd-mlnode-build" and
      .accelerator.vendor == "amd" and .accelerator.architecture == "gfx1201" and
      (.accelerator.pci_device_ids | type == "array" and index($pci) != null) and
      .host_provisioning.ubuntu_version_id == "24.04" and
      (.host_provisioning.installer_url | test("^https://repo\\.radeon\\.com/")) and
      (.host_provisioning.installer_sha256 | test("^[a-f0-9]{64}$")) and
      (.host_provisioning.installer_package_version | test("^[0-9][A-Za-z0-9.+:~-]*$")) and
      .host_provisioning.usecase == "graphics,rocm" and
      (.experimental_preinstalled_runtime == {
        status:"candidate",ubuntu_version_id:"26.04",kernel_release:"7.0.0-31-generic",
        requires_mlnode_qualification:true,
        packages:{amdrocm:{status:"install ok installed",version:"7.14.0~pre3-29052710811"},
          "rocm-core":{status:"absent",version:"absent"},
          "amdgpu-install":{status:"install ok installed",version:"31.40.1.26130000-2383377.26.04"}}
      }) and
      (.published_image | test("@sha256:[a-f0-9]{64}$"))
    ' "$profile" >/dev/null || die profile 'pinned AMD MLNode profile is invalid or does not match the PCI device'
    profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
    provision="$(jq -c .host_provisioning "$profile")"
    os_id="$(awk -F= '$1 == "os_id" {print $2}' "$inspection")"
    os_version_id="$(awk -F= '$1 == "os_version_id" {print $2}' "$inspection")"
    kernel_release="$(awk -F= '$1 == "kernel_release" {print $2}' "$inspection")"
    amdrocm_status="$(awk -F= '$1 == "amdrocm_status" {print substr($0,index($0,"=")+1)}' "$inspection")"
    amdrocm_version="$(awk -F= '$1 == "amdrocm_version" {print substr($0,index($0,"=")+1)}' "$inspection")"
    rocm_core_status="$(awk -F= '$1 == "rocm_core_status" {print substr($0,index($0,"=")+1)}' "$inspection")"
    rocm_core_version="$(awk -F= '$1 == "rocm_core_version" {print substr($0,index($0,"=")+1)}' "$inspection")"
    amdgpu_install_status="$(awk -F= '$1 == "amdgpu_install_status" {print substr($0,index($0,"=")+1)}' "$inspection")"
    amdgpu_install_version="$(awk -F= '$1 == "amdgpu_install_version" {print substr($0,index($0,"=")+1)}' "$inspection")"
    [[ "$os_id" == ubuntu && "$os_version_id" =~ ^[0-9]{2}\.04$ && "$kernel_release" =~ ^[A-Za-z0-9._+-]+$ ]] || die inspection 'AMD Ubuntu OS or kernel readback is missing or invalid'
    [[ "$amdrocm_status" =~ ^(absent|install\ ok\ installed)$ && "$amdgpu_install_status" =~ ^(absent|install\ ok\ installed)$ ]] || die inspection 'AMD package status is missing or invalid'
    [[ "$amdrocm_version" == absent || "$amdrocm_version" =~ ^[0-9][A-Za-z0-9.+:~-]*$ ]] || die inspection 'amdrocm package version is invalid'
    [[ "$rocm_core_status" =~ ^(absent|install\ ok\ installed)$ ]] || die inspection 'rocm-core package status is missing or invalid'
    [[ "$rocm_core_version" == absent || "$rocm_core_version" =~ ^[0-9][A-Za-z0-9.+:~-]*$ ]] || die inspection 'rocm-core package version is invalid'
    [[ "$amdgpu_install_version" == absent || "$amdgpu_install_version" =~ ^[0-9][A-Za-z0-9.+:~-]*$ ]] || die inspection 'amdgpu-install package version is invalid'
    if [[ "$readiness" == provisioning ]]; then
      [[ "$(wc -l <"$inspection" | tr -d ' ')" == 12 ]] || die inspection 'AMD provisioning inspection contains unexpected fields'
      [[ "$os_version_id" == "$(jq -r .ubuntu_version_id <<<"$provision")" ]] || die unsupported "AMD provisioning is unavailable on Ubuntu $os_version_id"
      [[ "$amdgpu_install_status" == absent && "$amdgpu_install_version" == absent || "$amdgpu_install_status" == 'install ok installed' && "$amdgpu_install_version" == "$(jq -r .installer_package_version <<<"$provision")" ]] \
        || die unsupported 'installed amdgpu-install package does not match the pinned provisioning contract'
      receipt="$(jq -cn --arg pci "$pci_device_id" --arg profile_sha256 "$profile_sha256" --argjson provisioning "$provision" --arg os "$os_version_id" --arg kernel "$kernel_release" \
        '{schema_version:1,vendor:"amd",architecture:"gfx1201",pci_device_id:$pci,readiness:"provisioning",compose_variant:"amd",qualification_backend:"rocm",host_provisioning:$provisioning,profile_sha256:$profile_sha256}')"
    else
    architecture="$(awk -F= '$1 == "architecture" {print $2}' "$inspection")"
    render_node="$(awk -F= '$1 == "render_node" {print $2}' "$inspection")"
    kfd_group_id="$(awk -F= '$1 == "kfd_group_id" {print $2}' "$inspection")"
    render_group_id="$(awk -F= '$1 == "render_group_id" {print $2}' "$inspection")"
    [[ "$architecture" == gfx1201 ]] || die unsupported "unsupported AMD architecture: ${architecture:-missing}"
    [[ "$render_node" =~ ^renderD[0-9]+$ ]] || die inspection 'AMD render node is missing or invalid'
    [[ "$kfd_group_id" =~ ^[0-9]+$ && "$render_group_id" =~ ^[0-9]+$ ]] || die inspection 'AMD device group IDs are missing or invalid'
      runtime_kind=''
      if [[ "$os_version_id" == "$(jq -r .ubuntu_version_id <<<"$provision")" && "$amdgpu_install_status" == 'install ok installed' && "$amdgpu_install_version" == "$(jq -r .installer_package_version <<<"$provision")" ]]; then
        runtime_kind=profile_provisioned
      elif jq -e --arg os "$os_version_id" --arg kernel "$kernel_release" --arg ars "$amdrocm_status" --arg arv "$amdrocm_version" --arg rcs "$rocm_core_status" --arg rcv "$rocm_core_version" --arg ais "$amdgpu_install_status" --arg aiv "$amdgpu_install_version" '
        .experimental_preinstalled_runtime | .ubuntu_version_id == $os and .kernel_release == $kernel and
        .packages.amdrocm == {status:$ars,version:$arv} and .packages["rocm-core"] == {status:$rcs,version:$rcv} and .packages["amdgpu-install"] == {status:$ais,version:$aiv}
      ' "$profile" >/dev/null; then
        runtime_kind=experimental_preinstalled
      else
        die unsupported 'installed AMD runtime does not match the provisioned or experimental candidate tuple'
      fi
      installed_runtime="$(jq -cn --arg kind "$runtime_kind" --arg os_id "$os_id" --arg os "$os_version_id" --arg kernel "$kernel_release" --arg ars "$amdrocm_status" --arg arv "$amdrocm_version" --arg rcs "$rocm_core_status" --arg rcv "$rocm_core_version" --arg ais "$amdgpu_install_status" --arg aiv "$amdgpu_install_version" \
        '{admission_route:$kind,os_id:$os_id,ubuntu_version_id:$os,kernel_release:$kernel,packages:{amdrocm:{status:$ars,version:$arv},"rocm-core":{status:$rcs,version:$rcv},"amdgpu-install":{status:$ais,version:$aiv}},requires_mlnode_qualification:true}')"
      receipt="$(jq -cn --arg architecture "$architecture" --arg render "/dev/dri/$render_node" \
      --argjson kfd_gid "$kfd_group_id" --argjson render_gid "$render_group_id" \
      --arg image "$(jq -r .published_image "$profile")" --arg profile_sha256 "$profile_sha256" --arg pci "$pci_device_id" --argjson provisioning "$provision" --argjson runtime "$installed_runtime" \
      '{schema_version:1,vendor:"amd",architecture:$architecture,pci_device_id:$pci,readiness:"ready",compose_variant:"amd",qualification_backend:"rocm",devices:{kfd:"/dev/kfd",render:$render},group_ids:{kfd:$kfd_gid,render:$render_gid},mlnode_image:$image,host_provisioning:$provisioning,installed_runtime:$runtime,profile_sha256:$profile_sha256}')"
    fi
    ;;
  *) die unsupported "unsupported accelerator vendor: ${vendor:-missing}" ;;
esac

mkdir -p "$(dirname "$output")"
tmp="$(mktemp "$(dirname "$output")/.accelerator-profile.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
jq -cS . <<<"$receipt" >"$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$output"
