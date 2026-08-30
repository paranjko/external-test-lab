#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/edge"
printf '%s\n' 'DEVSHARD_ADMIN_API_KEY=write-capable-secret' >"$tmp/edge/gateway-admission.env"
printf '%s\n' 'present' >"$tmp/container-present"
ln -s "$ROOT/test/fixtures/docker-admission-suspend.sh" "$tmp/bin/docker"

PATH="$tmp/bin:$PATH" \
GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
GDC_TEST_CONTAINER_PRESENT="$tmp/container-present" \
  "$ROOT/04-ops/edge-node/suspend-gateway-admission.sh" \
    --edge-root "$tmp/edge" >/dev/null

# Repeating the suspension is a clean no-op over an already scrubbed state.
PATH="$tmp/bin:$PATH" \
GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
GDC_TEST_CONTAINER_PRESENT="$tmp/container-present" \
  "$ROOT/04-ops/edge-node/suspend-gateway-admission.sh" \
    --edge-root "$tmp/edge" >/dev/null

[[ -f "$tmp/edge/gateway-admission.env" ]]
[[ ! -s "$tmp/edge/gateway-admission.env" ]]
[[ ! -e "$tmp/container-present" ]]
! grep -Fq 'write-capable-secret' "$tmp/edge/gateway-admission.env"
grep -Fq 'rm -f legacy-admission' "$tmp/docker.log"

printf '%s\n' 'DEVSHARD_ADMIN_API_KEY=must-remain-unmodified' >"$tmp/edge/gateway-admission.env"
if PATH="$tmp/bin:$PATH" \
  GDC_TEST_DOCKER_LOG="$tmp/docker.log" \
  GDC_TEST_CONTAINER_PRESENT="$tmp/container-present" \
  GDC_TEST_DOCKER_PS_FAIL=true \
    "$ROOT/04-ops/edge-node/suspend-gateway-admission.sh" \
      --edge-root "$tmp/edge" >"$tmp/failure.out" 2>"$tmp/failure.err"; then
  echo 'suspension unexpectedly succeeded without a Docker inventory' >&2
  exit 1
fi
grep -Fq 'ERROR cannot inventory public gateway admission containers' "$tmp/failure.err"
! grep -Fq 'READY' "$tmp/failure.out"
grep -Fq 'must-remain-unmodified' "$tmp/edge/gateway-admission.env"

printf 'PASS suspended admission removes legacy container metadata and scrubs its credential\n'
