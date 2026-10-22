#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { printf 'genesis_software_unsupported: %s\n' "$1" >&2; exit 1; }

[[ $# -eq 2 ]] || die 'usage: render-genesis-software.sh MODEL_PROFILE OUTPUT'
model_profile="$1"
output="$2"
[[ "$model_profile" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || die 'invalid model profile name'
release_lock="$ROOT/profiles/releases/v2026.10.06.lock"
model_lock="$ROOT/../model/$model_profile.lock"
[[ -r "$release_lock" && -r "$model_lock" ]] || die 'canonical release and model locks must be readable'

# Lock files are the only configuration inputs. Clear any matching inherited
# values first so an operator shell cannot silently override the declarations.
unset PROFILE_SCOPE GONKA_REPOSITORY GONKA_COMMIT GONKA_RELEASE DAPI_COMMIT
unset TMKMS_IMAGE INFERENCED_IMAGE DAPI_IMAGE EDGE_API_IMAGE EDGE_API_ENABLED
unset MLNODE_GENERIC_IMAGE MLNODE_PROXY_IMAGE VERSIOND_IMAGE VERSIOND_ROUTER_IMAGE
unset PROXY_IMAGE PROXY_ROUTER_IMAGE PROXY_POLICY_IMAGE BRIDGE_IMAGE POSTGRES_IMAGE
unset EXPLORER_IMAGE DASHBOARD_PORT CADDY_IMAGE PROMETHEUS_IMAGE GRAFANA_IMAGE
unset ALERTMANAGER_IMAGE BLACKBOX_IMAGE NODE_EXPORTER_IMAGE CADVISOR_IMAGE
unset INFERENCED_UPGRADE_URL INFERENCED_UPGRADE_SHA256 DAPI_UPGRADE_URL DAPI_UPGRADE_SHA256
unset INFERENCED_BINARY_SHA256 DAPI_BINARY_SHA256
unset INFERENCED_OPERATOR_URL_LINUX_AMD64 INFERENCED_OPERATOR_SHA256_LINUX_AMD64
unset MODEL_ID MODEL_REVISION MODEL_MIN_VRAM_MIB MLNODE_DTYPE MLNODE_CONTEXT_LENGTH
unset MLNODE_MAX_NUM_SEQS MLNODE_GPU_MEMORY_UTILIZATION MLNODE_TENSOR_PARALLEL_SIZE
unset MLNODE_VLLM_ARGS GDC_MODEL_PROFILE_SCOPE

# The adapter consumes only reviewed, repository-owned lock files.
# shellcheck disable=SC1090
source "$release_lock"
# shellcheck disable=SC1090
source "$ROOT/profiles/deployments/community-lab.lock"
# shellcheck disable=SC1090
source "$ROOT/profiles/operator-services/gdc-lab.lock"
# shellcheck disable=SC1090
source "$model_lock"

[[ "${PROFILE_SCOPE:-}" == existing-host-stack ]] || die 'release profile is not an existing-host-stack target'
[[ "${GONKA_RELEASE:-}" == 0.2.16-post1 && "${GONKA_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] \
  || die 'release version or commit does not match the supported official target'
[[ "${DAPI_COMMIT:-}" == "$GONKA_COMMIT" ]] || die 'Core and DAPI commits contradict'
[[ "${GONKA_REPOSITORY:-}" == https://github.com/gonka-ai/gonka.git ]] \
  || die 'unexpected official Gonka repository'
[[ "${GDC_MODEL_PROFILE_SCOPE:-network}" == network ]] \
  || die 'qualification-only model profiles cannot be used for Genesis'
[[ "${MODEL_ID:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
  && "${MODEL_REVISION:-}" =~ ^[0-9a-f]{40}$ ]] || die 'model ID or revision is not pinned'
[[ "${MLNODE_CONTEXT_LENGTH:-}" =~ ^[1-9][0-9]*$ \
  && "${MLNODE_MAX_NUM_SEQS:-}" =~ ^[1-9][0-9]*$ \
  && "${MLNODE_TENSOR_PARALLEL_SIZE:-}" =~ ^[1-9][0-9]*$ \
  && "${MLNODE_GPU_MEMORY_UTILIZATION:-}" =~ ^(0\.[0-9]+|1(\.0+)?)$ ]] \
  || die 'model runtime limits are incomplete or invalid'
[[ "${MLNODE_DTYPE:-}" =~ ^(auto|float16|bfloat16|float32)$ ]] || die 'unsupported model dtype'

for name in TMKMS_IMAGE INFERENCED_IMAGE DAPI_IMAGE EDGE_API_IMAGE MLNODE_GENERIC_IMAGE \
  MLNODE_PROXY_IMAGE VERSIOND_IMAGE VERSIOND_ROUTER_IMAGE PROXY_ROUTER_IMAGE \
  PROXY_POLICY_IMAGE BRIDGE_IMAGE POSTGRES_IMAGE EXPLORER_IMAGE CADDY_IMAGE \
  PROMETHEUS_IMAGE GRAFANA_IMAGE ALERTMANAGER_IMAGE BLACKBOX_IMAGE \
  NODE_EXPORTER_IMAGE CADVISOR_IMAGE; do
  value="${!name:-}"
  [[ "$value" =~ ^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$ ]] \
    || die "$name is missing an immutable digest"
done
[[ "${INFERENCED_UPGRADE_URL:-}" == https://* \
  && "${DAPI_UPGRADE_URL:-}" == https://* \
  && "${INFERENCED_OPERATOR_URL_LINUX_AMD64:-}" == https://* ]] \
  || die 'Core, DAPI, and operator artifacts must use pinned HTTPS URLs'
for name in INFERENCED_UPGRADE_SHA256 DAPI_UPGRADE_SHA256 INFERENCED_BINARY_SHA256 \
  DAPI_BINARY_SHA256 INFERENCED_OPERATOR_SHA256_LINUX_AMD64; do
  [[ "${!name:-}" =~ ^[0-9a-f]{64}$ ]] || die "$name is missing a valid SHA-256"
done
image_version() {
  local ref tag
  ref="${1%@*}"
  tag="${ref##*:}"
  [[ "$tag" != "$ref" && -n "$tag" ]] || return 1
  printf '%s\n' "$tag"
}
tmkms_version="$(image_version "$TMKMS_IMAGE")" || die 'TMKMS image has no explicit version tag'
mlnode_version="$(image_version "$MLNODE_GENERIC_IMAGE")" || die 'MLNode image has no explicit version tag'
release_sha="$(sha256sum "$release_lock" | awk '{print $1}')"
model_sha="$(sha256sum "$model_lock" | awk '{print $1}')"
compose_core_sha=6ec6da9a56c737ab8f49e66af2325220319f987134aba0eadc7b673d532bd51d
compose_join_sha=b8fcd8d3538b6c14f882d33aa8d82b835c91904b1894cb50a5346ded6e2e45bc

mkdir -p "$(dirname "$output")"
temporary="$(mktemp "$(dirname "$output")/.genesis-software.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
jq -n -S \
  --arg release_profile v2026.10.06 \
  --arg release_sha "$release_sha" \
  --arg model_profile "$model_profile" \
  --arg model_sha "$model_sha" \
  --arg repository "$GONKA_REPOSITORY" --arg commit "$GONKA_COMMIT" \
  --arg version "$GONKA_RELEASE" \
  --arg core_image "$INFERENCED_IMAGE" --arg dapi_image "$DAPI_IMAGE" \
  --arg tmkms_image "$TMKMS_IMAGE" --arg tmkms_version "$tmkms_version" \
  --arg mlnode_image "$MLNODE_GENERIC_IMAGE" --arg mlnode_version "$mlnode_version" \
  --arg core_url "$INFERENCED_UPGRADE_URL" --arg core_archive_sha "$INFERENCED_UPGRADE_SHA256" \
  --arg core_binary_sha "$INFERENCED_BINARY_SHA256" \
  --arg dapi_url "$DAPI_UPGRADE_URL" --arg dapi_archive_sha "$DAPI_UPGRADE_SHA256" \
  --arg dapi_binary_sha "$DAPI_BINARY_SHA256" \
  --arg operator_url "$INFERENCED_OPERATOR_URL_LINUX_AMD64" \
  --arg operator_sha "$INFERENCED_OPERATOR_SHA256_LINUX_AMD64" \
  --arg model_id "$MODEL_ID" --arg model_revision "$MODEL_REVISION" \
  --arg dtype "$MLNODE_DTYPE" --argjson context "$MLNODE_CONTEXT_LENGTH" \
  --argjson max_seqs "$MLNODE_MAX_NUM_SEQS" \
  --argjson gpu_util "$MLNODE_GPU_MEMORY_UTILIZATION" \
  --argjson tensor_parallel "$MLNODE_TENSOR_PARALLEL_SIZE" \
  --arg model_args "${MLNODE_VLLM_ARGS:-}" \
  --arg edge_api "$EDGE_API_IMAGE" --arg versiond "$VERSIOND_IMAGE" \
  --arg versiond_router "$VERSIOND_ROUTER_IMAGE" \
  --arg proxy "$PROXY_ROUTER_IMAGE" --arg proxy_policy "$PROXY_POLICY_IMAGE" \
  --arg bridge "$BRIDGE_IMAGE" --arg postgres "$POSTGRES_IMAGE" \
  --arg explorer "$EXPLORER_IMAGE" --arg ml_proxy "$MLNODE_PROXY_IMAGE" \
  --arg caddy "$CADDY_IMAGE" --arg prometheus "$PROMETHEUS_IMAGE" \
  --arg grafana "$GRAFANA_IMAGE" --arg alertmanager "$ALERTMANAGER_IMAGE" \
  --arg blackbox "$BLACKBOX_IMAGE" \
  --arg node_exporter "$NODE_EXPORTER_IMAGE" --arg cadvisor "$CADVISOR_IMAGE" \
  --arg compose_join_sha "$compose_join_sha" --arg compose_core_sha "$compose_core_sha" \
  '{schema_version:1,kind:"gdc-genesis-software-fragment",
    source:{release_profile:$release_profile,release_lock_sha256:$release_sha,
      model_profile:$model_profile,model_lock_sha256:$model_sha},
    spec:{deployment:{software:{schema_version:1,platform:"linux/amd64",accelerator:"cuda",
      deployment:{repository:$repository,commit:$commit,compose_files:[
        {path:"deploy/join/docker-compose.yml",sha256:$compose_join_sha},
        {path:"deploy/join/docker-compose.mlnode.yml",sha256:$compose_core_sha}]},
      components:{node:{version:$version,image:$core_image,commit:$commit,
          upgrade:{name:"v0.2.16",artifact:{url:$core_url,sha256:$core_archive_sha,format:"zip",executable:"inferenced"}}},
        api:{version:$version,image:$dapi_image,commit:$commit,
          upgrade:{name:"v0.2.16",artifact:{url:$dapi_url,sha256:$dapi_archive_sha,format:"zip",executable:"decentralized-api"}}},
        tmkms:{version:$tmkms_version,image:$tmkms_image},
        mlnode:{version:$mlnode_version,image:$mlnode_image}},
      operator_cli:{version:$version,artifact:{url:$operator_url,sha256:$operator_sha,format:"zip",executable:"inferenced"}},
      model:{id:$model_id,revision:$model_revision,context_length:$context,max_num_seqs:$max_seqs,
        gpu_memory_utilization:$gpu_util,dtype:$dtype,tensor_parallel_size:$tensor_parallel}}}},
    binary_sha256:{inferenced:$core_binary_sha,decentralized_api:$dapi_binary_sha},
    model_profile:{vllm_args:$model_args},
    container_images:{edge_api:$edge_api,versiond:$versiond,versiond_router:$versiond_router,
      proxy:$proxy,proxy_policy:$proxy_policy,bridge:$bridge,payload_postgres:$postgres,
      explorer:$explorer,inference_proxy:$ml_proxy,caddy:$caddy,prometheus:$prometheus,
      grafana:$grafana,alertmanager:$alertmanager,blackbox:$blackbox,
      node_exporter:$node_exporter,cadvisor:$cadvisor}}' >"$temporary"

if ! jq -e '{software:.spec.deployment.software}' "$temporary" \
  | jq -e -f "$ROOT/scripts/bootstrap-software.jq" >/dev/null; then
  die 'rendered software fragment does not satisfy the existing Bootstrap software v1 contract'
fi
chmod 0644 "$temporary"
mv -f -- "$temporary" "$output"
trap - EXIT
printf 'PASS rendered fresh-Genesis software fragment: %s\n' "$output"
