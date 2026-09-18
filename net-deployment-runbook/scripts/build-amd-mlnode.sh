#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-$ROOT/profiles/amd-mlnode/gfx1201.json}"
MODE="${2:-}"
[[ -f "$PROFILE" ]] || { echo "AMD MLNode profile is missing: $PROFILE" >&2; exit 2; }
[[ -z "$MODE" || "$MODE" == --publish || "$MODE" == --ci-publish || "$MODE" == --plan ]] || { echo 'usage: build-amd-mlnode.sh [profile.json] [--publish|--ci-publish|--plan]' >&2; exit 2; }

for tool in jq git docker; do command -v "$tool" >/dev/null || { echo "required tool is missing: $tool" >&2; exit 2; }; done
jq -e '
  .schema_version == 1 and .kind == "external-test-lab-amd-mlnode-build" and .status == "experimental" and
  .platform == "linux/amd64" and .accelerator.vendor == "amd" and .accelerator.architecture == "gfx1201" and
  (.sources.gonka.repository | startswith("https://github.com/")) and (.sources.gonka.commit | test("^[0-9a-f]{40}$")) and
  .sources.gonka.submodules.gorilla.path == "mlnode/packages/train/third_party/gorilla" and
  (.sources.gonka.submodules.gorilla.commit | test("^[0-9a-f]{40}$")) and
  (.sources.vllm.repository | startswith("https://github.com/")) and (.sources.vllm.commit | test("^[0-9a-f]{40}$")) and
  (.base_image | test("@sha256:[0-9a-f]{64}$")) and
  (.output_image | test("^ghcr.io/paranjko/gdc-mlnode:[A-Za-z0-9._-]+$")) and
  (.published_image | test("^ghcr.io/paranjko/gdc-mlnode:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$"))
' "$PROFILE" >/dev/null || { echo 'AMD MLNode profile is invalid' >&2; exit 2; }

gonka_repository="$(jq -r .sources.gonka.repository "$PROFILE")"
gonka_commit="$(jq -r .sources.gonka.commit "$PROFILE")"
gonka_gorilla_path="$(jq -r .sources.gonka.submodules.gorilla.path "$PROFILE")"
gonka_gorilla_commit="$(jq -r .sources.gonka.submodules.gorilla.commit "$PROFILE")"
vllm_repository="$(jq -r .sources.vllm.repository "$PROFILE")"
vllm_commit="$(jq -r .sources.vllm.commit "$PROFILE")"
artifact_repository="https://github.com/paranjko/external-test-lab"
base_image="$(jq -r .base_image "$PROFILE")"
output_image="$(jq -r .output_image "$PROFILE")"
published_image="$(jq -r .published_image "$PROFILE")"
vllm_image="gdc-amd-vllm:${vllm_commit:0:12}-gfx1201"

if [[ "$MODE" == --plan ]]; then
  printf 'PLAN source.gonka=%s@%s\n' "$gonka_repository" "$gonka_commit"
  printf 'PLAN source.gonka.submodule=%s@%s\n' "$gonka_gorilla_path" "$gonka_gorilla_commit"
  printf 'PLAN source.vllm=%s@%s\n' "$vllm_repository" "$vllm_commit"
  printf 'PLAN base=%s\nPLAN output=%s\nPLAN published=%s\n' "$base_image" "$output_image" "$published_image"
  exit 0
fi

build_root="$(mktemp -d /tmp/gdc-amd-mlnode.XXXXXX)"
cleanup() { rm -rf -- "$build_root"; }
trap cleanup EXIT
checkout_exact() {
  local repository="$1" commit="$2" destination="$3"
  git init -q "$destination"
  git -C "$destination" remote add origin "$repository"
  git -C "$destination" fetch -q --depth 1 origin "$commit"
  git -C "$destination" checkout -q --detach FETCH_HEAD
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] || { echo "source identity mismatch: $repository" >&2; exit 1; }
}
checkout_exact "$gonka_repository" "$gonka_commit" "$build_root/gonka"
checkout_exact "$vllm_repository" "$vllm_commit" "$build_root/vllm"
git -C "$build_root/gonka" submodule update --init --recursive --depth 1 -- "$gonka_gorilla_path"
[[ "$(git -C "$build_root/gonka/$gonka_gorilla_path" rev-parse HEAD)" == "$gonka_gorilla_commit" ]] || {
  echo "Gonka Gorilla submodule identity mismatch: $gonka_gorilla_path" >&2
  exit 1
}
[[ -f "$build_root/gonka/$gonka_gorilla_path/berkeley-function-call-leaderboard/pyproject.toml" ]] || {
  echo "Gonka Gorilla submodule is incomplete: $gonka_gorilla_path" >&2
  exit 1
}

docker buildx build --load --platform linux/amd64 --target final \
  --build-arg REMOTE_VLLM=0 \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg ARG_PYTORCH_ROCM_ARCH=gfx1201 \
  --label "org.opencontainers.image.revision=$vllm_commit" \
  --label "org.opencontainers.image.source=$vllm_repository" \
  --tag "$vllm_image" \
  --file "$build_root/vllm/docker/Dockerfile.rocm" "$build_root/vllm"

docker buildx build --load --platform linux/amd64 \
  --build-arg "VLLM_BASE_IMAGE=$vllm_image" \
  --build-arg MLNODE_RELEASE_VERSION="3.0.14-rocm-gfx1201" \
  --label "org.opencontainers.image.revision=$gonka_commit" \
  --label "org.opencontainers.image.source=$artifact_repository" \
  --label "io.gonka.upstream.source=$gonka_repository" \
  --label "io.gonka.upstream.revision=$gonka_commit" \
  --label "org.opencontainers.image.vllm.revision=$vllm_commit" \
  --tag "$output_image" \
  --file "$ROOT/images/Dockerfile.mlnode-rocm" "$build_root/gonka/mlnode"

# Hosted CI publishes a source-bound image but cannot qualify an AMD device.
# GDC will qualify the published digest on the actual AMD Host before it can
# deploy an MLNode.
if [[ "$MODE" == --ci-publish ]]; then
  [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo '--ci-publish is reserved for GitHub Actions' >&2; exit 2; }
  docker push "$output_image"
  digest="$(docker buildx imagetools inspect "$output_image" | awk '$1 == "Digest:" {print $2}')"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'published AMD MLNode digest is unavailable' >&2; exit 1; }
  printf 'PUBLISHED %s@%s\n' "$output_image" "$digest"
  exit 0
fi

render_node="$(basename "$(readlink -f /sys/class/drm/renderD128 2>/dev/null || true)")"
[[ "$render_node" == renderD* ]] || { echo 'AMD renderD128 device is required for qualification' >&2; exit 1; }
kfd_gid="$(stat -c '%g' /dev/kfd)"
render_gid="$(stat -c '%g' "/dev/dri/$render_node")"
docker run --rm --device /dev/kfd --device "/dev/dri/$render_node" --group-add "$kfd_gid" --group-add "$render_gid" \
  --entrypoint python3 "$output_image" -c 'import torch; assert torch.version.hip; assert torch.cuda.is_available(); import vllm; print(torch.version.hip)'
docker run --rm --entrypoint /app/packages/api/.venv/bin/python "$output_image" -c 'import api.app; import vllm; print("MLNode API import passed")'
docker image inspect "$output_image" >/dev/null
printf 'PASS AMD MLNode artifact qualified locally: %s\n' "$output_image"

if [[ "$MODE" == --publish ]]; then
  docker push "$output_image"
  digest="$(docker buildx imagetools inspect "$output_image" | awk '$1 == "Digest:" {print $2}')"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'published AMD MLNode digest is unavailable' >&2; exit 1; }
  printf 'PUBLISHED %s@%s\n' "$output_image" "$digest"
fi
