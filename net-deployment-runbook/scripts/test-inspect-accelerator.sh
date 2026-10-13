#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sys/bus/pci/devices/0000:01:00.0" "$tmp/sys/bus/pci/devices/0000:01:00.1" "$tmp/dev/dri" "$tmp/bin"
printf '0x1002\n' >"$tmp/sys/bus/pci/devices/0000:01:00.0/vendor"
printf '0x7550\n' >"$tmp/sys/bus/pci/devices/0000:01:00.0/device"
printf '0x030000\n' >"$tmp/sys/bus/pci/devices/0000:01:00.0/class"
printf '0x1002\n' >"$tmp/sys/bus/pci/devices/0000:01:00.1/vendor"
printf '0x1478\n' >"$tmp/sys/bus/pci/devices/0000:01:00.1/device"
printf '0x040300\n' >"$tmp/sys/bus/pci/devices/0000:01:00.1/class"
touch "$tmp/dev/kfd" "$tmp/dev/dri/renderD128"
cat >"$tmp/bin/rocminfo" <<'EOF'
#!/usr/bin/env bash
printf '  Name:                    gfx1201                            \n'
EOF
chmod +x "$tmp/bin/rocminfo"
cat >"$tmp/bin/find" <<'EOF'
#!/usr/bin/env bash
printf 'renderD128\n'
EOF
chmod +x "$tmp/bin/find"
printf 'ID=ubuntu\nVERSION_ID="26.04"\n' >"$tmp/os-release"
cat >"$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -r ]] && printf '7.0.0-31-generic\n'
EOF
cat >"$tmp/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  amdrocm) [[ "$3" == *Status* ]] && printf 'install ok installed' || printf '7.14.0~pre3-29052710811' ;;
  rocm-core) exit 1 ;;
  amdgpu-install) [[ "$3" == *Status* ]] && printf 'install ok installed' || printf '31.40.1.26130000-2383377.26.04' ;;
esac
EOF
chmod +x "$tmp/bin/uname" "$tmp/bin/dpkg-query"

inspect_env=(env PATH="$tmp/bin:$PATH" GDC_SYSFS_ROOT="$tmp/sys" GDC_DEV_ROOT="$tmp/dev" GDC_ROCMINFO="$tmp/bin/rocminfo" GDC_OS_RELEASE="$tmp/os-release" GDC_UNAME="$tmp/bin/uname" GDC_DPKG_QUERY="$tmp/bin/dpkg-query")
output="$("${inspect_env[@]}" "$ROOT/00-host-prep/inspect-accelerator.sh")"
grep -Fxq 'vendor=amd' <<<"$output"
grep -Fxq 'pci_device_id=0x7550' <<<"$output"
grep -Fxq 'readiness=ready' <<<"$output"
grep -Fxq 'architecture=gfx1201' <<<"$output"
grep -Fxq 'os_version_id=26.04' <<<"$output"
grep -Fxq 'amdrocm_version=7.14.0~pre3-29052710811' <<<"$output"
grep -Fxq 'render_node=renderD128' <<<"$output"
grep -Eq '^kfd_group_id=[0-9]+$' <<<"$output"
grep -Eq '^render_group_id=[0-9]+$' <<<"$output"

rm -f "$tmp/dev/kfd"
output="$("${inspect_env[@]}" "$ROOT/00-host-prep/inspect-accelerator.sh")"
grep -Fxq 'vendor=amd' <<<"$output"
grep -Fxq 'pci_device_id=0x7550' <<<"$output"
grep -Fxq 'readiness=provisioning' <<<"$output"
[[ "$(wc -l <<<"$output" | tr -d ' ')" == 12 ]]

printf 'PASS AMD ROCm accelerator inspection is explicit and fail-closed\n'
