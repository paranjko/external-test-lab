#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d /tmp/gdc-test-gateway-image.XXXXXX)"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

mkdir -p "$temporary/runbook/scripts" "$temporary/bin"
cp "$ROOT/scripts/build-gateway-image.sh" "$temporary/runbook/scripts/"
printf '%s\n' 'load_project() { :; }' >"$temporary/runbook/scripts/lib.sh"
printf '%s\n' \
  'load_profiles() { :; }' \
  'local_gateway_image_for_protocol() {' \
  '  local version="$1" image="${LOCAL_GATEWAY_IMAGE:?}"' \
  '  if [[ "${LAB_CANDIDATE:-false}" == true && "$version" == "${DEVSHARD_PROTOCOL_VERSION:-}" ]]; then' \
  '    printf "%s\\n" "$image"' \
  '  else' \
  '    printf "%s-%s\\n" "${image%-v[345]}" "$version"' \
  '  fi' \
  '}' >"$temporary/runbook/scripts/profile.sh"
printf '%s\n' 'immutable candidate gateway payload' | gzip -n >"$temporary/candidate.oci.tar.gz"
archive_sha256="$(sha256sum "$temporary/candidate.oci.tar.gz" | awk '{print $1}')"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'destination=' \
  'while (($#)); do' \
  '  if [[ "$1" == -o ]]; then destination="$2"; shift 2; else shift; fi' \
  'done' \
  'cp "$TEST_GATEWAY_ARCHIVE" "$destination"' >"$temporary/bin/curl"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'printf "%s\n" "$*" >>"$TEST_GATEWAY_LOG"' \
  'if [[ "$*" == *"docker load"* ]]; then cat >/dev/null; fi' >"$temporary/bin/ssh"
chmod +x "$temporary/bin/curl" "$temporary/bin/ssh"

TEST_GATEWAY_ARCHIVE="$temporary/candidate.oci.tar.gz" \
TEST_GATEWAY_LOG="$temporary/ssh.log" \
PATH="$temporary/bin:$PATH" \
GDC_GATEWAY_VERSION=v5 \
DEVSHARD_PROTOCOL_VERSION=v5 \
LOCAL_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate \
DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL=https://example.invalid/gateway.oci.tar.gz \
DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256="$archive_sha256" \
LAB_CANDIDATE=true \
GATEWAY_NODE=gateway.example \
  "$temporary/runbook/scripts/build-gateway-image.sh" >/dev/null

mapfile -t ssh_calls <"$temporary/ssh.log"
[[ "${#ssh_calls[@]}" == 2 ]]
[[ "${ssh_calls[0]}" == 'gateway.example docker load' ]]
[[ "${ssh_calls[1]}" == 'gateway.example docker image inspect ghcr.io/paranjko/gdc-devshard-gateway:candidate' ]]

printf 'PASS verified candidate gateway image reload contract\n'
