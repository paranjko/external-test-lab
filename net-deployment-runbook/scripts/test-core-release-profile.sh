#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/profile.sh"

# Exercise the actual loader, including inheritance, rather than matching text.
export GDC_RELEASE_PROFILE=v2026.08.06
load_profiles
base_signer="$TMKMS_IMAGE"
export GDC_RELEASE_PROFILE=v2026.10.06
load_profiles
[[ "$GONKA_RELEASE" == 0.2.16-post1 ]]
[[ "$GONKA_COMMIT" == 136041c81ea8ff38e7620d76af66a7c7fe7eec50 ]]
[[ "$DAPI_COMMIT" == "$GONKA_COMMIT" ]]
[[ "$UPGRADE_PLAN_NAME" == v0.2.16 ]]
[[ "$PROFILE_SCOPE" == existing-host-stack ]]
[[ "$TMKMS_IMAGE" == "$base_signer" ]]
[[ "$MLNODE_GENERIC_IMAGE" == ghcr.io/gonka-ai/mlnode:3.0.16@sha256:1b9b7ce55feecab837f1d7ce974fc5f377ae0a04a4fb403eeeb50130e7728ee1 ]]
[[ "$PROXY_IMAGE" == "$PROXY_ROUTER_IMAGE" ]]
for name in INFERENCED_IMAGE DAPI_IMAGE EDGE_API_IMAGE VERSIOND_IMAGE VERSIOND_ROUTER_IMAGE PROXY_IMAGE PROXY_POLICY_IMAGE MLNODE_GENERIC_IMAGE MLNODE_PROXY_IMAGE BRIDGE_IMAGE; do
  [[ "${!name}" =~ @sha256:[0-9a-f]{64}$ ]]
done
[[ "$INFERENCED_UPGRADE_SHA256" == d2ef13374fb15518a02ae5fac83d139d66fb79a8c93d97f4e78b43ce30e14f98 ]]
[[ "$DAPI_UPGRADE_SHA256" == f64b9433cd27d9ee433f1aede89d6be910f6deb8df644d55e2dfe30b8f873802 ]]
[[ "$(profile_hash)" =~ ^[0-9a-f]{64}$ ]]
bootstrap="$ROOT/../bootstrap/gonka-devnet-community.json"
while read -r role variable; do
  [[ "$(jq -er --arg role "$role" '.software.components[$role].image' "$bootstrap")" == "${!variable}" ]]
done <<'COMPONENTS'
node INFERENCED_IMAGE
api DAPI_IMAGE
tmkms TMKMS_IMAGE
mlnode MLNODE_GENERIC_IMAGE
payload-postgres POSTGRES_IMAGE
edge-api EDGE_API_IMAGE
versiond VERSIOND_IMAGE
versiond-router VERSIOND_ROUTER_IMAGE
proxy PROXY_ROUTER_IMAGE
proxy-policy PROXY_POLICY_IMAGE
explorer EXPLORER_IMAGE
inference-proxy MLNODE_PROXY_IMAGE
caddy CADDY_IMAGE
grafana GRAFANA_IMAGE
node-exporter NODE_EXPORTER_IMAGE
cadvisor CADVISOR_IMAGE
bridge BRIDGE_IMAGE
COMPONENTS
while read -r path variable; do
  [[ "$(jq -er "$path | tostring" "$bootstrap")" == "${!variable}" ]]
done <<'INPUTS'
.software.components.node.version GONKA_RELEASE
.software.components.api.version GONKA_RELEASE
.software.deployment.commit GONKA_COMMIT
.software.components.node.upgrade.artifact.url INFERENCED_UPGRADE_URL
.software.components.node.upgrade.artifact.sha256 INFERENCED_UPGRADE_SHA256
.software.components.api.upgrade.artifact.url DAPI_UPGRADE_URL
.software.components.api.upgrade.artifact.sha256 DAPI_UPGRADE_SHA256
.software.operator_cli.artifact.url INFERENCED_OPERATOR_URL_LINUX_AMD64
.software.operator_cli.artifact.sha256 INFERENCED_OPERATOR_SHA256_LINUX_AMD64
.software.model.id MODEL_ID
.software.model.revision MODEL_REVISION
.software.model.context_length MLNODE_CONTEXT_LENGTH
.software.model.max_num_seqs MLNODE_MAX_NUM_SEQS
.software.model.gpu_memory_utilization MLNODE_GPU_MEMORY_UTILIZATION
.software.model.dtype MLNODE_DTYPE
.software.model.tensor_parallel_size MLNODE_TENSOR_PARALLEL_SIZE
INPUTS
printf 'PASS explicit host release target and pinned component images\n'
