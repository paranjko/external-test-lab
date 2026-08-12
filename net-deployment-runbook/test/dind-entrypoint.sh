#!/bin/sh
set -eu

dockerd-entrypoint.sh dockerd >/var/log/gdc-bats-dockerd.log 2>&1 &
dockerd_pid=$!
trap 'kill "$dockerd_pid" 2>/dev/null || true' EXIT INT TERM

deadline=$(($(date +%s) + 30))
while ! docker info >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    cat /var/log/gdc-bats-dockerd.log >&2 || true
    exit 1
  fi
  sleep 1
done

exec bats "$@"
