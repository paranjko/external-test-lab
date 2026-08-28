#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${GDC_RUNNER_TEST_MODE:-}" == 1 ]]; then
  : "${GDC_RUNNER_TEST_ROOT:?set GDC_RUNNER_TEST_ROOT for test mode}"
  case "$GDC_RUNNER_TEST_ROOT" in /tmp/gdc-runner-test.*) ;; *) printf '%s\n' 'test runner root must be below /tmp/gdc-runner-test.*' >&2; exit 1 ;; esac
  readonly RUNNER_ROOT="$GDC_RUNNER_TEST_ROOT"
  RUNNER_USER="$(id -un)"
  readonly RUNNER_USER
  readonly SYSTEMD_UNIT_DIR="$GDC_RUNNER_TEST_ROOT/systemd"
else
  readonly RUNNER_ROOT=/srv/actions-runner/external-test-lab
  readonly RUNNER_USER=github-actions-runner
  readonly SYSTEMD_UNIT_DIR=/etc/systemd/system
fi
RUNNER_PARENT="$(dirname -- "$RUNNER_ROOT")"
readonly RUNNER_PARENT
export RUNNER_PARENT
readonly RUNNER_NAME=external-test-lab-gdc-node4
readonly RUNNER_LABEL=gdc-node4
readonly RUNNER_REPOSITORY=https://github.com/paranjko/external-test-lab
readonly UNIT_NAME=github-actions-runner-external-test-lab.service
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
export RUNNER_USER RUNNER_NAME RUNNER_LABEL RUNNER_REPOSITORY UNIT_NAME SCRIPT_DIR SYSTEMD_UNIT_DIR

load_manifest() {
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/runner-manifest.env"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${GDC_RUNNER_TEST_MODE:-}" == 1 ]] && return 0
  [[ "${EUID}" -eq 0 ]] || die 'run this operator command as root'
}

validate_target() {
  local candidate=${1:-}
  [[ "$candidate" == "$RUNNER_ROOT" ]] || die 'runner path must be /srv/actions-runner/external-test-lab'
  [[ ! -L "$RUNNER_PARENT" && ! -L "$RUNNER_ROOT" ]] || die 'runner path and parent must not be symlinks'
  [[ "$candidate" != / && "$candidate" != /srv && "$candidate" != /srv/dai ]] || die 'unsafe runner path'
}

require_runner_user() {
  getent passwd "$RUNNER_USER" >/dev/null || die 'dedicated runner account is missing'
  [[ "${GDC_RUNNER_TEST_MODE:-}" == 1 ]] && return 0
  id -nG "$RUNNER_USER" | tr ' ' '\n' | grep -Eq '^(sudo|wheel|docker|root)$' && die 'runner account has a privileged supplementary group'
}

assert_docker_denied() {
  if [[ -S /var/run/docker.sock ]] && runuser -u "$RUNNER_USER" -- sh -c 'test -r /var/run/docker.sock && test -w /var/run/docker.sock'; then
    die 'runner account can access the Docker socket'
  fi
}

download_verified() {
  local url=$1 expected=$2 destination=$3
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$destination" "$url"
  printf '%s  %s\n' "$expected" "$destination" | sha256sum --check --status
}
