#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/amd.env" <<'EOF'
vendor=amd
pci_device_id=0x7550
os_id=ubuntu
os_version_id=26.04
kernel_release=7.0.0-31-generic
amdrocm_status=install ok installed
amdrocm_version=7.14.0~pre3-29052710811
rocm_core_status=absent
rocm_core_version=absent
amdgpu_install_status=install ok installed
amdgpu_install_version=31.40.1.26130000-2383377.26.04
readiness=ready
architecture=gfx1201
render_node=renderD129
kfd_group_id=44
render_group_id=109
EOF
"$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/amd.env" --output "$tmp/amd.json"
jq -e '
  .vendor == "amd" and .architecture == "gfx1201" and .compose_variant == "amd" and
  .qualification_backend == "rocm" and .devices == {kfd:"/dev/kfd",render:"/dev/dri/renderD129"} and
  .group_ids == {kfd:44,render:109} and (.mlnode_image | test("@sha256:[a-f0-9]{64}$")) and
  .installed_runtime.admission_route == "experimental_preinstalled" and
  .installed_runtime.requires_mlnode_qualification == true and
  (.host_provisioning.installer_package_version | test("^[0-9]")) and
  (.profile_sha256 | test("^[a-f0-9]{64}$"))
' "$tmp/amd.json" >/dev/null

sed 's/7.0.0-31-generic/7.0.0-32-generic/' "$tmp/amd.env" >"$tmp/drift.env"
if "$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/drift.env" --output "$tmp/drift.json" 2>"$tmp/drift.err"; then
  echo 'drifted experimental AMD runtime was accepted' >&2; exit 1
fi
grep -Fq 'accelerator_profile_unsupported:' "$tmp/drift.err"

printf 'vendor=nvidia\n' >"$tmp/nvidia.env"
"$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/nvidia.env" --output "$tmp/nvidia.json"
jq -e '. == {compose_variant:"nvidia",qualification_backend:"cuda",schema_version:1,vendor:"nvidia"}' "$tmp/nvidia.json" >/dev/null

sed 's/gfx1201/gfx9999/' "$tmp/amd.env" >"$tmp/unknown.env"
if "$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/unknown.env" --output "$tmp/unknown.json" 2>"$tmp/unknown.err"; then
  echo 'unsupported AMD architecture was accepted' >&2; exit 1
fi
grep -Fq 'accelerator_profile_unsupported:' "$tmp/unknown.err"

cat >"$tmp/provisioning.env" <<'EOF'
vendor=amd
pci_device_id=0x7550
os_id=ubuntu
os_version_id=24.04
kernel_release=6.8.0-79-generic
amdrocm_status=absent
amdrocm_version=absent
rocm_core_status=absent
rocm_core_version=absent
amdgpu_install_status=absent
amdgpu_install_version=absent
readiness=provisioning
EOF
"$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/provisioning.env" --output "$tmp/provisioning.json"
jq -e '
  .vendor == "amd" and .architecture == "gfx1201" and .readiness == "provisioning" and
  .pci_device_id == "0x7550" and .host_provisioning.ubuntu_version_id == "24.04" and
  (.host_provisioning.installer_package_version | test("^[0-9]")) and
  (.host_provisioning.installer_sha256 | test("^[a-f0-9]{64}$")) and
  (has("devices") | not) and (has("group_ids") | not) and (has("mlnode_image") | not)
' "$tmp/provisioning.json" >/dev/null

sed 's/amdgpu_install_status=absent/amdgpu_install_status=install ok installed/; s/amdgpu_install_version=absent/amdgpu_install_version=0.0.0/' \
  "$tmp/provisioning.env" >"$tmp/wrong-installer.env"
if "$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/wrong-installer.env" --output "$tmp/wrong-installer.json" 2>"$tmp/wrong-installer.err"; then
  echo 'mismatched installed AMD provisioning package was accepted' >&2; exit 1
fi
grep -Fq 'accelerator_profile_unsupported:' "$tmp/wrong-installer.err"

cat >"$tmp/mixed.env" <<'EOF'
vendor=nvidia
vendor=amd
EOF
if "$ROOT/scripts/select-accelerator-profile.sh" --inspection "$tmp/mixed.env" --output "$tmp/mixed.json" 2>"$tmp/mixed.err"; then
  echo 'mixed accelerator inspection was accepted' >&2; exit 1
fi
grep -Fq 'accelerator_profile_inspection:' "$tmp/mixed.err"

grep -Fq '${AMD_KFD_DEVICE:?AMD_KFD_DEVICE is required}' "$ROOT/02-node/compose.ml-amd.yaml"
grep -Fq '${AMD_RENDER_DEVICE:?AMD_RENDER_DEVICE is required}' "$ROOT/02-node/compose.ml-amd.yaml"
! grep -Fq 'nvidia' "$ROOT/02-node/compose.ml-amd.yaml"
cat >"$tmp/compose.env" <<'EOF'
MLNODE_IMAGE=ghcr.io/paranjko/gdc-mlnode@sha256:280792cadc335eed35c0958a2f82e5e756ad437201ce5f2d1ffc379b30648e08
MLNODE_PROXY_IMAGE=nginx@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HF_HOME=/tmp/gdc-hf
AMD_KFD_DEVICE=/dev/kfd
AMD_RENDER_DEVICE=/dev/dri/renderD129
AMD_KFD_GROUP_ID=44
AMD_RENDER_GROUP_ID=109
EOF
docker compose --env-file "$tmp/compose.env" -f "$ROOT/02-node/compose.ml-amd.yaml" config --format json >"$tmp/compose.json"
jq -e '
  (.services.mlnode.image | endswith("@sha256:280792cadc335eed35c0958a2f82e5e756ad437201ce5f2d1ffc379b30648e08")) and
  .services.mlnode.devices == [
    {source:"/dev/kfd",target:"/dev/kfd",permissions:"rwm"},
    {source:"/dev/dri/renderD129",target:"/dev/dri/renderD129",permissions:"rwm"}
  ] and
  .services.mlnode.group_add == ["44","109"]
' "$tmp/compose.json" >/dev/null
sed 's/AMD_RENDER_GROUP_ID=109/AMD_RENDER_GROUP_ID=44/' "$tmp/compose.env" >"$tmp/single-group.env"
docker compose --env-file "$tmp/single-group.env" -f "$ROOT/02-node/compose.ml-amd-single-group.yaml" config --format json >"$tmp/single-group.json"
jq -e '.services.mlnode.group_add == ["44"]' "$tmp/single-group.json" >/dev/null
grep -Fq 'if [[ "$BACKEND" == cuda ]]' "$ROOT/scripts/qualify-ml-remote.sh"
grep -Fq 'rocminfo >"$WORK/rocm-info.txt"' "$ROOT/scripts/qualify-ml-remote.sh"
grep -Fq 'AMD admission is' "$ROOT/ROLE-JOIN.md"
grep -Fq 'limited to `gfx1201` with PCI device `0x7550`' "$ROOT/ROLE-JOIN.md"
grep -Fq 'an experimental preinstalled candidate, not a general vendor-support claim' "$ROOT/ROLE-JOIN.md"
grep -Fq 'installs an accelerator runtime, reboot the named Host' "$ROOT/README.md"
printf 'PASS accelerator profile selection, AMD Compose binding, and qualification backend dispatch\n'
