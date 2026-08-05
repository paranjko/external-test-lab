#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/profile.sh"
load_profiles
VERSION="${GDC_GATEWAY_VERSION:-$DEVSHARD_PROTOCOL_VERSION}"
[[ "$VERSION" =~ ^v[34]$ ]] || { echo 'GDC_GATEWAY_VERSION must be v3 or v4' >&2; exit 2; }
case "$VERSION" in
  v4)
    SOURCE_REF="${DEVSHARD_V4_SOURCE_REF:?DEVSHARD_V4_SOURCE_REF is required for v4}"
    ;;
  v3)
    # The v3 runtime is an independent governed binary, not the chain release.
    SOURCE_REF='release/v0.2.13-devshard-v3.0.0'
    ;;
esac
# Release profiles name the default v4 image; derive a distinct immutable
# local tag for the independently governed v3 runtime.
IMAGE="${LOCAL_GATEWAY_IMAGE%-v4}-$VERSION"
if ssh gdc-node0 docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "KEEP  $IMAGE already exists on gdc-node0"
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
docker save "$IMAGE" | ssh gdc-node0 docker load
printf '%s\n' "$IMAGE"
