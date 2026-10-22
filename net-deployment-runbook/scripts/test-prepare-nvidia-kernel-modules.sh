#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
PREPARE="$ROOT/00-host-prep/prepare-host.sh"

# A NVIDIA driver installation binds modules to every installed kernel before
# the initramfs is rebuilt. AMD provisioning is a distinct branch and must not
# run this NVIDIA-only helper.
grep -Fq 'ensure_nvidia_modules_for_installed_kernels()' "$PREPARE"
[[ "$(grep -c '^  ensure_nvidia_modules_for_installed_kernels$' "$PREPARE")" == 1 ]]
grep -Fq 'prepare_nvidia_driver_stack()' "$PREPARE"
# A retained healthy driver returns before installing modules for dormant
# kernels; module repair stays in the selected-driver install/upgrade branch.
awk '/^prepare_nvidia_driver_stack\(\)/ {inside=1} inside && /if \[\[ -z "\$NVIDIA_DRIVER_CANDIDATE" \]\]; then/ {retained=NR} inside && /^    return 0$/ {retained_end=NR} inside && /^  ensure_nvidia_modules_for_installed_kernels$/ {install=NR} inside && /^}$/ {exit !(retained < retained_end && retained_end < install)}' "$PREPARE"
# The selected driver metapackage is installed first, then its modules are
# resolved for every installed kernel, and only then is the module map rebuilt.
awk '/^prepare_nvidia_driver_stack\(\)/ {inside=1} inside && index($0, "ensure_packages \"$NVIDIA_DRIVER_CANDIDATE\"") {u=NR} inside && /^  ensure_nvidia_modules_for_installed_kernels$/ && u && !e {e=NR} inside && /^  depmod -a$/ {d=NR} inside && /^}$/ {exit !(u && e && d && u < e && e < d)}' "$PREPARE"
! grep -Fq 'NVIDIA_UTILS_CANDIDATE' "$PREPARE"

# shellcheck source=/dev/null
source <(sed -n '/^ensure_nvidia_modules_for_installed_kernels()/,/^}/p' "$PREPARE")
# shellcheck source=/dev/null
source <(sed -n '/^prepare_nvidia_driver_stack()/,/^}/p' "$PREPARE")

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

# Exercise the actual retained-driver policy with a successful nvidia-smi
# result. The running 147 kernel already has a working loaded driver; apt can
# install the missing 146 package, but prepare must not touch it or request a
# reboot merely because that dormant kernel is still installed.
nvidia-smi() {
  [[ "$*" == '--query-gpu=driver_version --format=csv,noheader' ]] || return 2
  printf '615.71.09\n'
}
reset_case
INSTALLED=$'linux-modules-nvidia-615-server-open-generic\nlinux-modules-nvidia-615-server-open-6.8.0-147-generic\nlinux-image-6.8.0-146-generic\nlinux-image-6.8.0-147-generic'
AVAILABLE='linux-modules-nvidia-615-server-open-6.8.0-146-generic'
RUNNING=6.8.0-147-generic
NVIDIA_DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"
NVIDIA_DRIVER_MAJOR="${NVIDIA_DRIVER_VERSION%%.*}"
MIN_DRIVER=580
[[ "$NVIDIA_DRIVER_VERSION" == 615.71.09 && "$NVIDIA_DRIVER_MAJOR" -ge "$MIN_DRIVER" ]]
NVIDIA_DRIVER_CANDIDATE=''
ensure_packages() { printf '%s\n' "$*" >>"$tmp/ensure-packages.log"; }
dkms() { [[ "$1" == status ]] || return 1; }
depmod() { printf '%s\n' "$*" >>"$tmp/driver-tools.log"; }
update-initramfs() { printf '%s\n' "$*" >>"$tmp/driver-tools.log"; }
prepare_nvidia_driver_stack
grep -Fxq 'KEEP  NVIDIA driver 615.71.09' "$tmp/status.log"
[[ ! -s "$tmp/apt.log" && ! -s "$tmp/apt-update.log" \
  && ! -s "$tmp/ensure-packages.log" && ! -s "$tmp/driver-tools.log" \
  && "$DRIVER_CHANGED" == false ]]
REBOOT_PENDING=false; reboot_rc=0
if [[ "$DRIVER_CHANGED" == true || "$REBOOT_PENDING" == true ]]; then reboot_rc=194; fi
[[ "$reboot_rc" == 0 ]]

# Installing/upgrading a selected driver still repairs installed-kernel
# modules and marks the Host for reboot when package changes occur.
reset_case
INSTALLED=$'linux-modules-nvidia-615-server-open-generic\nlinux-image-6.8.0-146-generic\nlinux-image-6.8.0-147-generic'
AVAILABLE='linux-modules-nvidia-615-server-open-6.8.0-146-generic'
RUNNING=6.8.0-147-generic
NVIDIA_DRIVER_VERSION=''
# shellcheck disable=SC2034 # Consumed by the sourced prepare_nvidia_driver_stack function.
NVIDIA_DRIVER_CANDIDATE=nvidia-driver-615-server-open
prepare_nvidia_driver_stack
grep -Fxq 'nvidia-driver-615-server-open' "$tmp/ensure-packages.log"
grep -Fxq 'linux-modules-nvidia-615-server-open-6.8.0-146-generic' "$tmp/apt.log"
[[ "$DRIVER_CHANGED" == true ]]

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

# Installing modules can update matching NVIDIA user-space packages. The
# loaded module may then be stale even when the installed kernel is not running.
reset_case; INSTALLED="$base"; RUNNING=6.8.0-138-generic
ensure_nvidia_modules_for_installed_kernels
[[ "$(<"$tmp/apt.log")" == linux-modules-nvidia-595-server-open-6.8.0-139-generic ]]
[[ "$DRIVER_CHANGED" == true ]]

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

printf 'PASS retained healthy NVIDIA driver skips dormant-kernel installs; driver upgrades still prepare kernel modules\n'
