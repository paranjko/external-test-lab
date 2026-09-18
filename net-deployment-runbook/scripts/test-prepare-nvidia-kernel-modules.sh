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
awk '/ubuntu-drivers install --gpgpu/ {u=NR} /^    ensure_nvidia_modules_for_installed_kernels$/ && u && !e {e=NR} /^    depmod -a$/ {d=NR} END {exit !(u && e && d && u < e && e < d)}' "$PREPARE"

# shellcheck source=/dev/null
source <(sed -n '/^ensure_nvidia_modules_for_installed_kernels()/,/^}/p' "$PREPARE")

INSTALLED=''; AVAILABLE=''; RUNNING=''; UNRESOLVABLE=''; BROKEN=''; UPDATE_RC=0
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
  if [[ "$1" == update ]]; then printf 'update\n' >>"$tmp/apt-update.log"; return "$UPDATE_RC"; fi
  # The resolver-only probe: the archive can pin a kernel's modules to another
  # driver build, which apt refuses before it touches dpkg.
  if [[ "$1" == install && "$2" == -s ]]; then
    printf '%s\n' "${!#}" >>"$tmp/apt-probe.log"
    ! grep -Fxq -- "${!#}" <<<"$UNRESOLVABLE"
    return
  fi
  [[ "$1" == install && "$2" == -y ]] || { echo "unexpected apt-get $*" >&2; return 1; }
  if printf '%s\n%s\n' "$UNRESOLVABLE" "$BROKEN" | grep -Fxq -- "$3"; then echo 'E: install failed' >&2; return 100; fi
  printf '%s\n' "$3" >>"$tmp/apt.log"
  INSTALLED+=$'\n'"$3"
}
# Alpine has no dpkg; kernel ABI numbers compare like versions.
dpkg() {
  [[ "$1" == --compare-versions && "$3" == lt ]] || { echo "unexpected dpkg $*" >&2; return 2; }
  [[ "$2" != "$4" && "$(printf '%s\n%s\n' "$2" "$4" | sort -V | head -n1)" == "$2" ]]
}
reset_case() { : >"$tmp/status.log"; : >"$tmp/apt.log"; : >"$tmp/apt-update.log"; : >"$tmp/apt-probe.log"; DRIVER_CHANGED=false; UNRESOLVABLE=''; BROKEN=''; UPDATE_RC=0; }

base=$'linux-modules-nvidia-595-server-open-generic\nlinux-modules-nvidia-595-server-open-6.8.0-138-generic\nlinux-image-6.8.0-138-generic\nlinux-image-6.8.0-139-generic\nlinux-image-generic'

# The Host booted a newer kernel than the one the modules were installed for:
# the missing modules are installed and the driver counts as changed.
reset_case; INSTALLED="$base"; RUNNING=6.8.0-139-generic
AVAILABLE='linux-modules-nvidia-595-server-open-6.8.0-139-generic'
ensure_nvidia_modules_for_installed_kernels
[[ "$(<"$tmp/apt.log")" == linux-modules-nvidia-595-server-open-6.8.0-139-generic ]]
grep -Fxq 'INSTALL  NVIDIA 595-server-open modules for kernel 6.8.0-139-generic' "$tmp/status.log"
[[ "$DRIVER_CHANGED" == true ]]
# On a prepared Host this is the first apt action: the lists are refreshed once.
[[ "$(wc -l <"$tmp/apt-update.log")" -eq 1 ]]

# A second pass finds every kernel covered and changes nothing.
reset_case
ensure_nvidia_modules_for_installed_kernels
[[ ! -s "$tmp/apt.log" && ! -s "$tmp/apt-update.log" && "$DRIVER_CHANGED" == false ]]

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

# An older installed kernel whose modules the archive pins to another driver
# build: the running kernel is covered, the Host will not boot the older one
# next, so prepare goes on. Nothing is installed for it.
older=$'linux-modules-nvidia-595-server-open-generic\nlinux-modules-nvidia-595-server-open-7.0.0-31-generic\nlinux-image-7.0.0-28-generic\nlinux-image-7.0.0-31-generic'
reset_case; INSTALLED="$older"; RUNNING=7.0.0-31-generic
AVAILABLE='linux-modules-nvidia-595-server-open-7.0.0-28-generic'
UNRESOLVABLE='linux-modules-nvidia-595-server-open-7.0.0-28-generic'
ensure_nvidia_modules_for_installed_kernels
[[ ! -s "$tmp/apt.log" && "$DRIVER_CHANGED" == false ]]
grep -Fxq 'SKIP  NVIDIA 595-server-open modules for older kernel 7.0.0-28-generic do not resolve next to the installed driver' "$tmp/status.log"

# The skipped older kernel does not end the loop: the running kernel behind it
# still gets its modules, and the lists were refreshed once for both.
reset_case; INSTALLED=$'linux-modules-nvidia-595-server-open-generic\nlinux-image-7.0.0-28-generic\nlinux-image-7.0.0-31-generic'; RUNNING=7.0.0-31-generic
AVAILABLE=$'linux-modules-nvidia-595-server-open-7.0.0-28-generic\nlinux-modules-nvidia-595-server-open-7.0.0-31-generic'
UNRESOLVABLE='linux-modules-nvidia-595-server-open-7.0.0-28-generic'
ensure_nvidia_modules_for_installed_kernels
[[ "$(<"$tmp/apt.log")" == linux-modules-nvidia-595-server-open-7.0.0-31-generic && "$DRIVER_CHANGED" == true ]]
[[ "$(wc -l <"$tmp/apt-update.log")" -eq 1 ]]

# A newer kernel is what the Host boots next: modules that do not resolve for
# it end prepare instead of leaving the next boot without a GPU.
reset_case; INSTALLED=$'linux-modules-nvidia-595-server-open-generic\nlinux-modules-nvidia-595-server-open-7.0.0-28-generic\nlinux-image-7.0.0-28-generic\nlinux-image-7.0.0-31-generic'; RUNNING=7.0.0-28-generic
AVAILABLE='linux-modules-nvidia-595-server-open-7.0.0-31-generic'
UNRESOLVABLE='linux-modules-nvidia-595-server-open-7.0.0-31-generic'
if ensure_nvidia_modules_for_installed_kernels 2>/dev/null; then
  echo 'unresolvable modules for a newer kernel did not stop prepare' >&2; exit 1
fi
[[ ! -s "$tmp/apt-probe.log" ]]

# The same for the running kernel, and for an older kernel whose install fails
# for any other reason than the resolver: neither is skipped.
reset_case; INSTALLED=$'linux-modules-nvidia-595-server-open-generic\nlinux-image-7.0.0-31-generic'; RUNNING=7.0.0-31-generic
AVAILABLE='linux-modules-nvidia-595-server-open-7.0.0-31-generic'
UNRESOLVABLE='linux-modules-nvidia-595-server-open-7.0.0-31-generic'
if ensure_nvidia_modules_for_installed_kernels 2>/dev/null; then
  echo 'unresolvable modules for the running kernel did not stop prepare' >&2; exit 1
fi
reset_case; INSTALLED="$older"; RUNNING=7.0.0-31-generic
AVAILABLE='linux-modules-nvidia-595-server-open-7.0.0-28-generic'
BROKEN='linux-modules-nvidia-595-server-open-7.0.0-28-generic'
if ensure_nvidia_modules_for_installed_kernels 2>/dev/null; then
  echo 'a failed install that resolves was skipped' >&2; exit 1
fi
! grep -q '^SKIP' "$tmp/status.log" || { echo 'a failed install that resolves was reported as a skip' >&2; exit 1; }

# A failed refresh is reported and the install still happens.
reset_case; INSTALLED="$base"; RUNNING=6.8.0-139-generic; UPDATE_RC=100
AVAILABLE='linux-modules-nvidia-595-server-open-6.8.0-139-generic'
ensure_nvidia_modules_for_installed_kernels
grep -Fxq 'WARN  package lists were not refreshed' "$tmp/status.log"
[[ "$(<"$tmp/apt.log")" == linux-modules-nvidia-595-server-open-6.8.0-139-generic ]]

printf 'PASS prepare installs NVIDIA modules for every installed kernel and skips only an older kernel whose modules do not resolve\n'
