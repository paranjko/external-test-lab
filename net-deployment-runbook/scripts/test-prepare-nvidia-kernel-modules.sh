#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
PREPARE="$ROOT/00-host-prep/prepare-host.sh"

# Both driver branches bind modules to every installed kernel: a fresh install
# before the initramfs is rebuilt, and a kept driver so the next kernel boots
# with a module too.
grep -Fq 'ensure_nvidia_modules_for_installed_kernels()' "$PREPARE"
[[ "$(grep -c '^    ensure_nvidia_modules_for_installed_kernels$' "$PREPARE")" == 2 ]]
# The driver package is installed first, then its modules are resolved for
# every installed kernel, and only then is the module map rebuilt. Match the
# candidate install literally: a later ensure_packages call installs utilities.
awk 'index($0, "ensure_packages \"$driver_candidate\"") {u=NR} /^    ensure_nvidia_modules_for_installed_kernels$/ && u && !e {e=NR} /^    depmod -a$/ {d=NR} END {exit !(u && e && d && u < e && e < d)}' "$PREPARE"

# shellcheck source=/dev/null
source <(sed -n '/^ensure_nvidia_modules_for_installed_kernels()/,/^}/p' "$PREPARE")

INSTALLED=''; AVAILABLE=''; RUNNING=''
status() { printf '%s\n' "$*" >>"$tmp/status.log"; }
uname() { printf '%s\n' "$RUNNING"; }
is_installed() { grep -Fxq -- "$1" <<<"$INSTALLED"; }
dpkg-query() {
  local format='' pattern='' package found=1
  while (($#)); do
    case "$1" in
      -W) shift ;;
      -f=*) format="${1#-f=}"; shift ;;
      *) pattern="$1"; shift ;;
    esac
  done
  if [[ "$format" == *Package* ]]; then
    while IFS= read -r package; do
      [[ -n "$package" ]] || continue
      # shellcheck disable=SC2053 # the pattern is a dpkg glob on purpose
      if [[ "$package" == $pattern ]]; then printf '%s ii \n' "$package"; found=0; fi
    done <<<"$INSTALLED"
    return "$found"
  fi
  is_installed "$pattern" || return 1
  printf 'ii '
}
apt-cache() { [[ "$1" == show ]] && grep -Fxq -- "$2" <<<"$AVAILABLE"; }
apt-get() {
  [[ "$1" == install && "$2" == -y ]] || { echo "unexpected apt-get $*" >&2; return 1; }
  printf '%s\n' "$3" >>"$tmp/apt.log"
  INSTALLED+=$'\n'"$3"
}
reset_case() { : >"$tmp/status.log"; : >"$tmp/apt.log"; DRIVER_CHANGED=false; }

base=$'linux-modules-nvidia-595-server-open-generic\nlinux-modules-nvidia-595-server-open-6.8.0-138-generic\nlinux-image-6.8.0-138-generic\nlinux-image-6.8.0-139-generic\nlinux-image-generic'

# The Host booted a newer kernel than the one the modules were installed for:
# the missing modules are installed and the driver counts as changed.
reset_case; INSTALLED="$base"; RUNNING=6.8.0-139-generic
AVAILABLE='linux-modules-nvidia-595-server-open-6.8.0-139-generic'
ensure_nvidia_modules_for_installed_kernels
[[ "$(<"$tmp/apt.log")" == linux-modules-nvidia-595-server-open-6.8.0-139-generic ]]
grep -Fxq 'INSTALL  NVIDIA 595-server-open modules for kernel 6.8.0-139-generic' "$tmp/status.log"
[[ "$DRIVER_CHANGED" == true ]]

# A second pass finds every kernel covered and changes nothing.
reset_case
ensure_nvidia_modules_for_installed_kernels
[[ ! -s "$tmp/apt.log" && "$DRIVER_CHANGED" == false ]]

# Modules for a kernel that is installed but not running do not need a reboot.
reset_case; INSTALLED="$base"; RUNNING=6.8.0-138-generic
ensure_nvidia_modules_for_installed_kernels
[[ "$(<"$tmp/apt.log")" == linux-modules-nvidia-595-server-open-6.8.0-139-generic ]]
[[ "$DRIVER_CHANGED" == false ]]

# The archive may lag behind a new kernel: say so, install nothing.
reset_case; INSTALLED="$base"; RUNNING=6.8.0-139-generic; AVAILABLE=''
ensure_nvidia_modules_for_installed_kernels
[[ ! -s "$tmp/apt.log" && "$DRIVER_CHANGED" == false ]]
grep -Fxq 'SKIP  no NVIDIA 595-server-open modules packaged for kernel 6.8.0-139-generic' "$tmp/status.log"

# A DKMS or proprietary-only install has no prebuilt metapackage: no-op.
reset_case; INSTALLED=$'nvidia-dkms-595\nlinux-image-6.8.0-139-generic'; RUNNING=6.8.0-139-generic
AVAILABLE='linux-modules-nvidia-595-server-open-6.8.0-139-generic'
ensure_nvidia_modules_for_installed_kernels
[[ ! -s "$tmp/apt.log" && ! -s "$tmp/status.log" && "$DRIVER_CHANGED" == false ]]

printf 'PASS prepare installs NVIDIA modules for every installed kernel\n'
