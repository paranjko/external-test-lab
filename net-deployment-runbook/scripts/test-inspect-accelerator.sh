#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sys/bus/pci/devices/0000:01:00.0" "$tmp/dev/dri" "$tmp/bin"
printf '0x1002\n' >"$tmp/sys/bus/pci/devices/0000:01:00.0/vendor"
touch "$tmp/dev/kfd" "$tmp/dev/dri/renderD128"
cat >"$tmp/bin/rocminfo" <<'EOF'
#!/usr/bin/env bash
printf '  Name:                    gfx1201\n'
EOF
chmod +x "$tmp/bin/rocminfo"
cat >"$tmp/bin/find" <<'EOF'
#!/usr/bin/env bash
printf 'renderD128\n'
EOF
chmod +x "$tmp/bin/find"

output="$(PATH="$tmp/bin:$PATH" GDC_SYSFS_ROOT="$tmp/sys" GDC_DEV_ROOT="$tmp/dev" GDC_ROCMINFO="$tmp/bin/rocminfo" "$ROOT/00-host-prep/inspect-accelerator.sh")"
grep -Fxq 'vendor=amd' <<<"$output"
grep -Fxq 'architecture=gfx1201' <<<"$output"
grep -Fxq 'render_node=renderD128' <<<"$output"

rm -f "$tmp/dev/kfd"
if PATH="$tmp/bin:$PATH" GDC_SYSFS_ROOT="$tmp/sys" GDC_DEV_ROOT="$tmp/dev" GDC_ROCMINFO="$tmp/bin/rocminfo" "$ROOT/00-host-prep/inspect-accelerator.sh" >/dev/null 2>&1; then
  echo 'AMD inspection accepted a Host without /dev/kfd' >&2
  exit 1
fi

printf 'PASS AMD ROCm accelerator inspection is explicit and fail-closed\n'
