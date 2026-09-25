#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/apt-cache" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == pkgnames ]]; then
  printf '%s\n' nvidia-driver-550 nvidia-driver-580-open nvidia-driver-595-open nvidia-driver-595-server-open
  exit 0
fi
if [[ "$1" == policy ]]; then
  case "$2" in
    nvidia-driver-580-open|nvidia-driver-595-open|nvidia-driver-595-server-open) printf '  Candidate: 1.0\n' ;;
    *) printf '  Candidate: (none)\n' ;;
  esac
fi
EOF
chmod +x "$tmp/apt-cache"

selected="$(GDC_APT_CACHE="$tmp/apt-cache" "$ROOT/00-host-prep/select-nvidia-driver.sh" 580)"
[[ "$selected" == nvidia-driver-595-server-open ]] || {
  echo "expected open NVIDIA package, got: $selected" >&2
  exit 1
}
if GDC_APT_CACHE="$tmp/apt-cache" "$ROOT/00-host-prep/select-nvidia-driver.sh" 610 >/dev/null; then
  echo 'accepted unavailable NVIDIA driver version' >&2
  exit 1
fi
printf 'PASS NVIDIA driver preflight accepts open packages before host preparation\n'
