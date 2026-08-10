#!/usr/bin/env bash
set -Eeuo pipefail

required_commands=(
  bash
  curl
  docker
  flock
  getent
  git
  jq
  openssl
  rsync
  scp
  sha256sum
  ssh
  sudo
  unzip
)

missing=()
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done

[[ "$(command -v gdc)" == /home/operator/.local/bin/gdc ]] || {
  echo 'FAIL cleanroom gdc command is not installed' >&2
  exit 1
}

if (( ${#missing[@]} > 0 )); then
  printf 'FAIL missing cleanroom commands: %s\n' "${missing[*]}" >&2
  exit 1
fi

if (( EUID == 0 )); then
  echo 'FAIL the cleanroom terminal must use the non-root operator user' >&2
  exit 1
fi

if ! sudo -n true; then
  echo 'FAIL passwordless sudo is unavailable to the operator user' >&2
  exit 1
fi

for clean_root in /opt/runbook-source /workspace; do
  if [[ ! -f "${clean_root}/.env.example" ]]; then
    printf 'FAIL expected runbook snapshot is missing from %s\n' "${clean_root}" >&2
    exit 1
  fi

  for forbidden_path in \
    .env \
    VERSION.runtime.lock \
    artifacts \
    generated \
    inventory.env \
    lab \
    state \
    wireguard.env; do
    if [[ -e "${clean_root}/${forbidden_path}" ]]; then
      printf 'FAIL host runtime path leaked into cleanroom: %s/%s\n' \
        "${clean_root}" "${forbidden_path}" >&2
      exit 1
    fi
  done
done

expected_gdc_home=/workspaces/.data
actual_gdc_home="$(bash -c 'source scripts/lib.sh; printf "%s\n" "$GDC_HOME"')"
if [[ "$actual_gdc_home" != "$expected_gdc_home" ]]; then
  printf 'FAIL cleanroom GDC_HOME default is %s, expected %s\n' \
    "$actual_gdc_home" "$expected_gdc_home" >&2
  exit 1
fi
mkdir -p "$actual_gdc_home"
[[ -w "$actual_gdc_home" ]] || {
  printf 'FAIL cleanroom GDC_HOME is not writable: %s\n' "$actual_gdc_home" >&2
  exit 1
}

deadline=$((SECONDS + 60))
until docker info >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo 'FAIL the isolated Docker daemon did not become ready within 60 seconds' >&2
    exit 1
  fi
  sleep 1
done

printf 'PASS Gonka JOIN cleanroom is ready (user=%s, isolated_docker=true, isolated_workspace=true)\n' "$(id -un)"
