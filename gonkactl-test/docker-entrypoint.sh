#!/bin/sh
set -eu
dockerd-entrypoint.sh >/tmp/gonkactl-test-dockerd.log 2>&1 &
daemon_pid=$!
cleanup() {
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
ready=0
attempt=0
while [ "$attempt" -lt 60 ]; do
  if docker info >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
  attempt=$((attempt + 1))
done
if [ "$ready" -ne 1 ]; then
  cat /tmp/gonkactl-test-dockerd.log >&2
  echo 'Docker daemon did not become ready (is the container privileged?)' >&2
  exit 125
fi
if [ "${1#-}" != "$1" ]; then
  set -- gonkactl-test "$@"
fi
"$@"
