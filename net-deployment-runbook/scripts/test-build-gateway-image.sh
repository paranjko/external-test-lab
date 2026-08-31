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
printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'printf "fetch-upstream\\n" >>"$TEST_GATEWAY_LOG"' \
  >"$temporary/runbook/scripts/fetch-upstream.sh"
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
  'if [[ "$*" == *"docker image inspect"* ]]; then' \
  '  if [[ "${TEST_EMPTY_INSPECT:-false}" == true ]]; then printf "[]\n"; exit 0; fi' \
  '  if [[ "$*" == *@sha256:* ]]; then layer=a variant=v1 size=2; else layer="${TEST_LOADED_LAYER:-a}" variant="${TEST_LOADED_VARIANT:-v1}" size="${TEST_LOADED_SIZE:-1}"; fi' \
  '  printf "[{\"Architecture\":\"amd64\",\"Os\":\"linux\",\"Variant\":\"%s\",\"OsVersion\":\"\",\"Config\":{\"Entrypoint\":[\"devshardctl\"],\"Labels\":{\"org.opencontainers.image.revision\":\"%s\"}},\"RootFS\":{\"Type\":\"layers\",\"Layers\":[\"sha256:%064d\"]},\"Created\":\"2026-08-31T00:00:00Z\",\"Comment\":\"buildkit.dockerfile.v0\",\"Size\":%s}]\n" "$variant" "${TEST_IMAGE_REVISION:-}" "0x$layer" "$size"' \
  '  [[ "${TEST_EXTRA_INSPECT_RECORD:-false}" != true ]] || printf "[]\n"' \
  'fi' >"$temporary/bin/ssh"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'printf "git %s\\n" "$*" >>"$TEST_GATEWAY_LOG"' \
  'if [[ " $* " == *" rev-parse "* ]]; then' \
  '  printf "%s\\n" "${TEST_GIT_RESOLVED_COMMIT:?}"' \
  'fi' >"$temporary/bin/git"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'printf "docker %s\\n" "$*" >>"$TEST_GATEWAY_LOG"' \
  'if [[ "${1:-}" == save ]]; then printf "fixture image archive\\n"; fi' \
  >"$temporary/bin/docker"
chmod +x \
  "$temporary/runbook/scripts/fetch-upstream.sh" \
  "$temporary/bin/curl" \
  "$temporary/bin/docker" \
  "$temporary/bin/git" \
  "$temporary/bin/ssh"

v4_commit=3c034a72a80f82c33f71a73737c329f41c7ddf7b
: >"$temporary/ssh.log"
TEST_IMAGE_REVISION="$v4_commit" \
TEST_GATEWAY_LOG="$temporary/ssh.log" \
PATH="$temporary/bin:$PATH" \
GDC_GATEWAY_VERSION=v4 \
DEVSHARD_PROTOCOL_VERSION=v5 \
DEVSHARD_V4_SOURCE_REF=release/v0.2.15-devshard-v4.0.1 \
DEVSHARD_V4_SOURCE_COMMIT="$v4_commit" \
LOCAL_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate \
LAB_CANDIDATE=true \
GATEWAY_NODE=gateway.example \
  "$temporary/runbook/scripts/build-gateway-image.sh" >"$temporary/v4-keep.stdout"
grep -Fq "matches pinned v4 source commit $v4_commit" "$temporary/v4-keep.stdout"

: >"$temporary/ssh.log"
TEST_IMAGE_REVISION=1111111111111111111111111111111111111111 \
TEST_GIT_RESOLVED_COMMIT="$v4_commit" \
TEST_GATEWAY_LOG="$temporary/ssh.log" \
PATH="$temporary/bin:$PATH" \
GDC_GATEWAY_VERSION=v4 \
DEVSHARD_PROTOCOL_VERSION=v5 \
DEVSHARD_V4_SOURCE_REF=release/v0.2.15-devshard-v4.0.1 \
DEVSHARD_V4_SOURCE_COMMIT="$v4_commit" \
LOCAL_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate \
LAB_CANDIDATE=true \
GATEWAY_NODE=gateway.example \
  "$temporary/runbook/scripts/build-gateway-image.sh" >"$temporary/v4-rebuild.stdout"
grep -Fq "expected $v4_commit" "$temporary/v4-rebuild.stdout"
grep -Fqx 'fetch-upstream' "$temporary/ssh.log"
grep -Fq "git -C $temporary/runbook/vendor/gonka fetch --depth 1 origin refs/tags/release/v0.2.15-devshard-v4.0.1:refs/tags/release/v0.2.15-devshard-v4.0.1" "$temporary/ssh.log"
grep -Fq "git -C $temporary/runbook/vendor/gonka rev-parse release/v0.2.15-devshard-v4.0.1^{commit}" "$temporary/ssh.log"
grep -Fq "docker build --pull --target devshardctl-runtime --label org.opencontainers.image.revision=$v4_commit --label org.opencontainers.image.ref.name=release/v0.2.15-devshard-v4.0.1" "$temporary/ssh.log"
grep -Fq 'docker save ghcr.io/paranjko/gdc-devshard-gateway:candidate' "$temporary/ssh.log"
grep -Fq 'gateway.example docker load' "$temporary/ssh.log"

: >"$temporary/ssh.log"
if TEST_IMAGE_REVISION=1111111111111111111111111111111111111111 \
  TEST_GIT_RESOLVED_COMMIT=2222222222222222222222222222222222222222 \
  TEST_GATEWAY_LOG="$temporary/ssh.log" \
  PATH="$temporary/bin:$PATH" \
  GDC_GATEWAY_VERSION=v4 \
  DEVSHARD_PROTOCOL_VERSION=v5 \
  DEVSHARD_V4_SOURCE_REF=release/v0.2.15-devshard-v4.0.1 \
  DEVSHARD_V4_SOURCE_COMMIT="$v4_commit" \
  LOCAL_GATEWAY_IMAGE=ghcr.io/paranjko/gdc-devshard-gateway:candidate \
  LAB_CANDIDATE=true \
  GATEWAY_NODE=gateway.example \
    "$temporary/runbook/scripts/build-gateway-image.sh" >"$temporary/v4-source-mismatch.stdout" 2>"$temporary/v4-source-mismatch.stderr"; then
  echo 'v4 gateway accepted a source ref that differs from the pinned commit' >&2
  exit 1
fi
grep -Fq "does not resolve to pinned commit $v4_commit" "$temporary/v4-source-mismatch.stderr"
if grep -Eq '^(docker build|docker save|gateway\.example docker load)' "$temporary/ssh.log"; then
  echo 'v4 gateway built or loaded an image after source provenance mismatch' >&2
  exit 1
fi

: >"$temporary/ssh.log"

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
[[ "${ssh_calls[1]}" == 'gateway.example docker image inspect ghcr.io/paranjko/gdc-devshard-gateway:candidate' ]]
[[ "${ssh_calls[2]}" == 'gateway.example docker pull ghcr.io/paranjko/gdc-devshard-gateway:candidate@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]
[[ "${ssh_calls[3]}" == 'gateway.example docker image inspect ghcr.io/paranjko/gdc-devshard-gateway:candidate@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]

: >"$temporary/ssh.log"
if TEST_LOADED_LAYER=c \
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
grep -Fq 'runtime payload does not match the immutable composition image' "$temporary/mismatch.stderr"

if TEST_LOADED_VARIANT=v2 \
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
    "$temporary/runbook/scripts/build-gateway-image.sh" >/dev/null 2>"$temporary/platform-mismatch.stderr"; then
  echo 'candidate gateway accepted a different runtime platform' >&2
  exit 1
fi
grep -Fq 'runtime payload does not match the immutable composition image' \
  "$temporary/platform-mismatch.stderr"

if TEST_EMPTY_INSPECT=true \
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
    "$temporary/runbook/scripts/build-gateway-image.sh" >/dev/null 2>"$temporary/incomplete.stderr"; then
  echo 'candidate gateway accepted incomplete image inspection data' >&2
  exit 1
fi

if TEST_EXTRA_INSPECT_RECORD=true \
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
    "$temporary/runbook/scripts/build-gateway-image.sh" >/dev/null 2>"$temporary/multiple.stderr"; then
  echo 'candidate gateway accepted multiple image inspection records' >&2
  exit 1
fi

printf 'PASS verified candidate gateway image identity contract\n'
