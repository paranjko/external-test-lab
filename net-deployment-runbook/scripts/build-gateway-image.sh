#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_project
# shellcheck disable=SC1091
source "$ROOT/scripts/profile.sh"
load_profiles
VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
[[ "$VERSION" =~ ^v[345]$ ]] || { echo 'GDC_GATEWAY_VERSION must be v3, v4 or v5' >&2; exit 2; }
IMAGE="$(local_gateway_image_for_protocol "$VERSION")"
if [[ "$VERSION" == v5 ]]; then
  immutable_image="${DEVSHARD_GATEWAY_IMAGE:?candidate v5 immutable gateway image is required}"
  [[ "$immutable_image" =~ @sha256:[0-9a-f]{64}$ ]] \
    || { echo 'candidate v5 immutable gateway image must include a SHA-256 digest' >&2; exit 2; }
  archive_url="${DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL:?candidate v5 gateway image archive URL is required}"
  archive_sha256="${DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256:?candidate v5 gateway image archive SHA-256 is required}"
  [[ "${LAB_CANDIDATE:-false}" == true && "$archive_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || { echo 'DevShard v5 requires an immutable laboratory candidate image archive' >&2; exit 2; }
  archive="$(mktemp /tmp/gdc-devshard-gateway.XXXXXX.oci.tar.gz)"
  trap 'rm -f -- "$archive"' EXIT
  curl -fsSL "$archive_url" -o "$archive"
  printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum -c -
  # A mutable deployment tag is not identity evidence. Always reload it from
  # the checksum-bound archive before reuse, then verify that the expected tag
  # was materialized by docker load.
  gzip -dc "$archive" | ssh "$GATEWAY_NODE" docker load
  loaded_image_id="$(ssh "$GATEWAY_NODE" docker image inspect --format '{{.Id}}' "$IMAGE")"
  ssh "$GATEWAY_NODE" docker pull "$immutable_image" >/dev/null
  immutable_image_id="$(ssh "$GATEWAY_NODE" docker image inspect --format '{{.Id}}' "$immutable_image")"
  [[ "$loaded_image_id" =~ ^sha256:[0-9a-f]{64}$ && "$loaded_image_id" == "$immutable_image_id" ]] || {
    echo 'candidate v5 gateway archive image does not match the immutable composition digest' >&2
    exit 1
  }
  echo "READY $IMAGE loaded from its verified candidate archive on $GATEWAY_NODE"
  exit 0
fi
case "$VERSION" in
  v4)
    SOURCE_REF="${DEVSHARD_V4_SOURCE_REF:?DEVSHARD_V4_SOURCE_REF is required for v4}"
    ;;
  v3)
    # The v3 runtime is an independent governed binary, not the chain release.
    SOURCE_REF='release/v0.2.13-devshard-v3.0.0'
    ;;
esac
if ssh "$GATEWAY_NODE" docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "KEEP  $IMAGE already exists on $GATEWAY_NODE"
  exit 0
fi
"$ROOT/scripts/fetch-upstream.sh"
SRC="$ROOT/vendor/gonka"
BUILD_TREE="$(mktemp -d /tmp/gdc-devshard-source.XXXXXX)"
cleanup() { git -C "$SRC" worktree remove --force "$BUILD_TREE" >/dev/null 2>&1 || rm -rf "$BUILD_TREE"; }
trap cleanup EXIT
git -C "$SRC" fetch --depth 1 origin "refs/tags/$SOURCE_REF:refs/tags/$SOURCE_REF"
git -C "$SRC" worktree add --detach "$BUILD_TREE" "$SOURCE_REF" >/dev/null
# The v4 release Dockerfile copies inference-chain/, common/, and devshard/
# together, so its build context must be the repository root. SOURCE_REF
# chooses the matching source tree while DEVSHARD_VERSION below remains the
# protocol/state-root tag embedded in the binary.
build_target=()
build_context="$BUILD_TREE"
dockerfile="$BUILD_TREE/devshard/Dockerfile"
if [[ "$VERSION" == v4 ]]; then
  build_target=(--target devshardctl-runtime)
else
  # The historical v3 release Dockerfile is self-contained in devshard/.
  build_context="$BUILD_TREE/devshard"
  dockerfile="$build_context/Dockerfile"
fi
docker build --pull \
  "${build_target[@]}" \
  --build-arg DEVSHARD_VERSION="$VERSION" \
  --build-arg DEVSHARD_PROTOCOL_VERSION="$VERSION" \
  -f "$dockerfile" -t "$IMAGE" "$build_context"
docker save "$IMAGE" | ssh "$GATEWAY_NODE" docker load
printf '%s\n' "$IMAGE"
