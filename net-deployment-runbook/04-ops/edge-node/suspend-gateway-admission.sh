#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: sudo $0 [--edge-root DIR]" >&2
}

EDGE_ROOT=/srv/dai/edge
if (($#)); then
  [[ $# -eq 2 && $1 == --edge-root && $2 == /* && $2 != / ]] || {
    usage
    exit 2
  }
  EDGE_ROOT="$2"
fi

container_output=''
if ! container_output="$(docker ps -aq \
  --filter label=com.docker.compose.project=gdc-edge \
  --filter label=com.docker.compose.service=gateway-admission)"; then
  echo 'ERROR cannot inventory public gateway admission containers' >&2
  exit 1
fi
container_ids=()
if [[ -n "$container_output" ]]; then
  mapfile -t container_ids <<<"$container_output"
fi
if (( ${#container_ids[@]} > 0 )); then
  docker rm -f "${container_ids[@]}" >"${EDGE_ROOT%/*}/stop-gateway-admission.log" 2>&1
fi

install -d -m 0755 "$EDGE_ROOT"
owner=()
if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then
  owner=(-o "$SUDO_USER" -g "$(id -gn "$SUDO_USER")")
fi
install "${owner[@]}" -m 0600 /dev/null "$EDGE_ROOT/gateway-admission.env"

[[ ! -s "$EDGE_ROOT/gateway-admission.env" ]]
remaining_output=''
if ! remaining_output="$(docker ps -aq \
  --filter label=com.docker.compose.project=gdc-edge \
  --filter label=com.docker.compose.service=gateway-admission)"; then
  echo 'ERROR cannot verify public gateway admission removal' >&2
  exit 1
fi
[[ -z "$remaining_output" ]]

printf 'READY public gateway admission removed and retained credential scrubbed\n'
