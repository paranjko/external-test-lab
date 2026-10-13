#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREPARE="$ROOT/00-host-prep/prepare-host.sh"
PROFILE="$ROOT/profiles/amd-mlnode/gfx1201.json"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

installer_url="$(jq -r '.host_provisioning.installer_url' "$PROFILE")"
installer_sha256="$(jq -r '.host_provisioning.installer_sha256' "$PROFILE")"
installer_package_version="$(jq -r '.host_provisioning.installer_package_version' "$PROFILE")"
usecase="$(jq -r '.host_provisioning.usecase' "$PROFILE")"

# Extract the provisioner as a unit: this keeps the test hermetic while
# asserting that the operator-facing host script and committed profile cannot
# silently drift apart.
sed -n '/^install_amd_rocm()/,/^}/p' "$PREPARE" >"$tmp/install_amd_rocm.sh"
grep -Fq "$installer_url" "$tmp/install_amd_rocm.sh"
grep -Fq "$installer_sha256" "$tmp/install_amd_rocm.sh"
grep -Fq "$installer_package_version" "$tmp/install_amd_rocm.sh"
grep -Fq -- "--usecase=$usecase" "$tmp/install_amd_rocm.sh"

mkdir -p "$tmp/bin"
log="$tmp/calls.log"
cat >"$tmp/bin/amdgpu-install" <<'EOF'
#!/usr/bin/env bash
printf 'amdgpu-install %s\n' "$*" >>"${GDC_TEST_LOG:?}"
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${GDC_TEST_LOG:?}"
touch "${@: -1}"
EOF
cat >"$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf 'sha256sum %s\n' "$*" >>"${GDC_TEST_LOG:?}"
EOF
cat >"$tmp/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"${GDC_TEST_LOG:?}"
EOF
cat >"$tmp/bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >>"${GDC_TEST_LOG:?}"
EOF
chmod +x "$tmp/bin"/*

run_case() {
  local existing="$1" installed_version="$2"
  : >"$log"
  PATH="$tmp/bin:$PATH" GDC_TEST_LOG="$log" EXISTING="$existing" INSTALLED_VERSION="$installed_version" bash -s "$tmp/install_amd_rocm.sh" <<'EOF'
set -Eeuo pipefail
ID=ubuntu
VERSION_ID=24.04
OPERATOR_USER=operator
DRIVER_CHANGED=false
status() { printf 'status %s\n' "$*" >>"${GDC_TEST_LOG:?}"; }
ensure_packages() { printf 'ensure_packages %s\n' "$*" >>"${GDC_TEST_LOG:?}"; }
dpkg-query() { [[ "$1" == -W && "$2" == -f='${Version}' && "$3" == amdgpu-install ]] || return 2; printf '%s\n' "$INSTALLED_VERSION"; }
command() {
  if [[ "$1" == -v && "$2" == amdgpu-install && "$EXISTING" != true ]]; then
    return 1
  fi
  builtin command "$@"
}
source "$1"
install_amd_rocm
[[ "$DRIVER_CHANGED" == true ]]
EOF
}

run_case false ''
grep -Fq "curl --fail --show-error --location --proto =https --tlsv1.2 $installer_url -o /tmp/gdc-amdgpu-install.deb" "$log"
grep -Fq "sha256sum -c -" "$log"
grep -Fq 'apt-get install -y /tmp/gdc-amdgpu-install.deb' "$log"
grep -Fq "amdgpu-install -y --usecase=$usecase" "$log"
grep -Fq 'usermod -aG render,video operator' "$log"

run_case true "$installer_package_version"
! grep -Fq 'curl ' "$log"
! grep -Fq 'apt-get install -y /tmp/gdc-amdgpu-install.deb' "$log"
grep -Fq "amdgpu-install -y --usecase=$usecase" "$log"

if run_case true 'old-version'; then
  echo 'mismatched amdgpu-install package version was accepted' >&2; exit 1
fi
grep -Fq "does not match pinned $installer_package_version" "$log"

# The AMD route must not inherit the NVIDIA installation branch.
awk '/if \[\[ "\$AMD_ACCELERATOR" == true/,/^fi$/ { print }' "$PREPARE" | grep -Fq 'install_amd_rocm'
! grep -Eq 'nvidia-|nvidia-ctk|select-nvidia-driver' "$tmp/install_amd_rocm.sh"

mkdir -p "$tmp/preflight"
sed -n '/^GPU_ROLE=false/,/^LOG=\/var\/log\/gdc-prepare.log/p' "$PREPARE" | sed '$d' >"$tmp/preflight/block.sh"
cat >"$tmp/preflight/inspect-accelerator.sh" <<'EOF'
#!/usr/bin/env bash
printf 'vendor=amd\npci_device_id=0x7550\narchitecture=gfx1201\nreadiness=%s\n' "${GDC_TEST_FRESH_READINESS:?}"
EOF
cat >"$tmp/preflight/select-nvidia-driver.sh" <<'EOF'
#!/usr/bin/env bash
printf 'selector called\n' >>"${GDC_TEST_LOG:?}"
printf 'nvidia-driver-580-server\n'
EOF
chmod +x "$tmp/preflight/inspect-accelerator.sh" "$tmp/preflight/select-nvidia-driver.sh"

run_preflight() {
  local supplied="$1" fresh="$2" os_version="$3"
  : >"$log"
  GDC_TEST_LOG="$log" GDC_TEST_FRESH_READINESS="$fresh" \
    GDC_ACCELERATOR_VENDOR=amd GDC_ACCELERATOR_ARCHITECTURE=gfx1201 GDC_ACCELERATOR_READINESS="$supplied" \
    bash -c 'set -Eeuo pipefail; ROLE=ml-only; MIN_DRIVER=580; ID=ubuntu; VERSION_ID="$2"; source "$1"' \
      "$tmp/preflight/prepare-host.sh" "$tmp/preflight/block.sh" "$os_version"
}

run_preflight ready ready 24.04
! grep -Fq 'selector called' "$log" || { echo 'AMD path called NVIDIA selector' >&2; exit 1; }
if run_preflight ready provisioning 24.04 2>"$tmp/stale.err"; then
  echo 'stale AMD ready receipt was accepted' >&2; exit 1
fi
grep -Fq 'readiness changed after profile selection' "$tmp/stale.err"
! grep -Fq 'selector called' "$log" || { echo 'stale receipt called NVIDIA selector' >&2; exit 1; }
if run_preflight provisioning provisioning 22.04 2>"$tmp/os.err"; then
  echo 'unsupported AMD provisioning OS was accepted' >&2; exit 1
fi
grep -Fq 'provisioning requires the approved Ubuntu 24.04' "$tmp/os.err"
! grep -Fq 'selector called' "$log" || { echo 'unsupported OS called NVIDIA selector' >&2; exit 1; }

mutation_line="$(grep -n '^LOG=/var/log/gdc-prepare.log' "$PREPARE" | cut -d: -f1)"
readiness_line="$(grep -n 'readiness changed after profile selection' "$PREPARE" | cut -d: -f1)"
os_line="$(grep -n 'provisioning requires the approved Ubuntu 24.04' "$PREPARE" | cut -d: -f1)"
(( readiness_line < mutation_line && os_line < mutation_line )) \
  || { echo 'AMD refusal guards follow the first mutation boundary' >&2; exit 1; }
printf 'PASS AMD gfx1201 provisioning is profile-pinned and never selects NVIDIA setup\n'
