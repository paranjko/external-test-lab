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
  'if [[ "$*" == *"docker load"* ]]; then cat >/dev/null; exit 0; fi' \
  'if [[ "$*" == *"docker image inspect --format {{.Id}}"* ]]; then' \
  '  if [[ "$*" == *@sha256:* ]]; then printf "%s\n" "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; else printf "%s\n" "${TEST_LOADED_IMAGE_ID:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"; fi' \
  'fi' >"$temporary/bin/ssh"
chmod +x "$temporary/bin/curl" "$temporary/bin/ssh"

TEST_GATEWAY_ARCHIVE="$temporary/candidate.oci.tar.gz" \
TEST_GATEWAY_LOG="$temporary/ssh.log" \
PATH="$temporary/bin:$PATH" \
GDC_GATEWAY_VERSION=v5 \
DEVSHARD_PROTOCOL_VERSION=v5 \
LOCAL_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate \
DEVSHARD_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL=https://example.invalid/gateway.oci.tar.gz \
DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256="$archive_sha256" \
LAB_CANDIDATE=true \
GATEWAY_NODE=gateway.example \
  "$temporary/runbook/scripts/build-gateway-image.sh" >/dev/null

mapfile -t ssh_calls <"$temporary/ssh.log"
[[ "${#ssh_calls[@]}" == 4 ]]
[[ "${ssh_calls[0]}" == 'gateway.example docker load' ]]
[[ "${ssh_calls[1]}" == 'gateway.example docker image inspect --format {{.Id}} ghcr.io/paranjko/gdc-devshard-gateway:candidate' ]]
[[ "${ssh_calls[2]}" == 'gateway.example docker pull ghcr.io/paranjko/gdc-devshard-gateway:candidate@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]
[[ "${ssh_calls[3]}" == 'gateway.example docker image inspect --format {{.Id}} ghcr.io/paranjko/gdc-devshard-gateway:candidate@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]

: >"$temporary/ssh.log"
if TEST_LOADED_IMAGE_ID=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  TEST_GATEWAY_ARCHIVE="$temporary/candidate.oci.tar.gz" \
  TEST_GATEWAY_LOG="$temporary/ssh.log" \
  PATH="$temporary/bin:$PATH" \
  GDC_GATEWAY_VERSION=v5 \
  DEVSHARD_PROTOCOL_VERSION=v5 \
  LOCAL_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate \
  DEVSHARD_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL=https://example.invalid/gateway.oci.tar.gz \
  DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256="$archive_sha256" \
  LAB_CANDIDATE=true \
  GATEWAY_NODE=gateway.example \
    "$temporary/runbook/scripts/build-gateway-image.sh" >/dev/null 2>"$temporary/mismatch.stderr"; then
  echo 'candidate gateway accepted an archive image that differs from the immutable digest' >&2
  exit 1
fi
grep -Fq 'does not match the immutable composition digest' "$temporary/mismatch.stderr"

printf 'PASS verified candidate gateway image identity contract\n'
