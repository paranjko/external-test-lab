#!/usr/bin/env bash
# Resolve immutable JOIN inputs from the runtime observed on a Bootstrap seed.
# Runtime bytes never come from the local release-profile catalogue.
set -Eeuo pipefail

usage() { echo "Usage: $0 --observation FILE --output FILE" >&2; }
die() { printf 'runtime_%s: %s\n' "$1" "$2" >&2; exit 1; }
sha256_text() { printf '%s\n' "$1" | sha256sum | awk '{print $1}'; }

observation=''; output=''
while (($#)); do case "$1" in
  --observation) observation="${2:-}"; shift 2 ;;
  --output) output="${2:-}"; shift 2 ;;
  *) usage; exit 2 ;;
esac; done
[[ -r "$observation" && -n "$output" ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v curl >/dev/null || die dependency_missing 'curl is required'
command -v jq >/dev/null || die dependency_missing 'jq is required'
jq -e '.schema_version == 1 and .kind == "gdc-network-observation" and .result == {state:"ready",reason:"none"} and (.runtime.core.commit | test("^[a-f0-9]{40}$")) and (.runtime.dapi.commit | test("^[a-f0-9]{40}$"))' "$observation" >/dev/null || die artifact_unavailable 'network observation is not ready'

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fetch_json() {
  local url="$1" target="$2"
  curl -fsS --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 --retry-all-errors "$url" >"$target"
}

fetch_file() {
  local url="$1" target="$2"
  curl -fsS --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 --retry-all-errors "$url" >"$target"
}

official_release_asset() {
  local component="$1" publisher="$2" version="$3" commit="$4" asset_name="$5" release_tag release_file refs_file asset tag_commit
  release_tag="release/v${version}"
  release_file="$tmp/${component}-${publisher//\//-}-release.json"
  refs_file="$tmp/${component}-refs.json"
  fetch_json "https://api.github.com/repos/${publisher}/releases/tags/${release_tag//\//%2F}" "$release_file" || return 1
  jq -e --arg tag "$release_tag" --arg asset "$asset_name" '
    .tag_name == $tag and
    ([.assets[] | select(.name == $asset and (.browser_download_url | type == "string" and startswith("https://github.com/")) and (.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")))] | length == 1)
  ' "$release_file" >/dev/null || return 2
  fetch_json "https://api.github.com/repos/gonka-ai/gonka/git/matching-refs/tags/${release_tag}" "$refs_file" \
    || return 1
  tag_commit="$(jq -er --arg ref "refs/tags/${release_tag}" '
    [.[] | select(.ref == $ref and .object.type == "commit") | .object.sha] | if length == 1 then .[0] else empty end
  ' "$refs_file")" || return 2
  [[ "$tag_commit" == "$commit" ]] || return 2
  asset="$(jq -c --arg asset "$asset_name" '[.assets[] | select(.name == $asset)] | .[0] | {name,browser_download_url,digest}' "$release_file")"
  jq -cn --arg component "$component" --arg publisher "$publisher" --arg tag "$release_tag" --arg commit "$tag_commit" --argjson asset "$asset" \
    '{component:$component,provider:"github",repository:$publisher,tag_authority_repository:"gonka-ai/gonka",release_tag:$tag,commit:$commit,asset:$asset}' | jq -cS .
}

official_core_release() {
  local metadata rc
  # `inferenced-amd64.zip` is the Host runtime/Cosmovisor artifact. JOIN also
  # needs an executable operator CLI for preflight and signing, so resolve the
  # platform-specific official CLI asset instead.
  if metadata="$(official_release_asset core gonka-ai/gonka "$core_version" "$core_commit" inferenced-linux-amd64.zip)"; then
    printf '%s\n' "$metadata"
    return 0
  else
    rc=$?
  fi
  if (( rc == 2 )); then
    die artifact_unavailable "official Core release release/v${core_version} is malformed or does not bind the observed commit"
  fi
  die artifact_unavailable "official release metadata is unavailable for core release/v${core_version}"
}

official_dapi_release() {
  local metadata rc
  # The DAPI executable is a Cosmovisor payload, not the version of the
  # surrounding API image.  Prefer the Gonka release; a small number of
  # published DAPI payloads are hosted by the official race-releases mirror,
  # but their tag is still bound to the observed Gonka commit above.
  if metadata="$(official_release_asset dapi gonka-ai/gonka "$dapi_version" "$dapi_commit" decentralized-api-amd64.zip)"; then
    printf '%s\n' "$metadata"
    return 0
  else
    rc=$?
  fi
  if (( rc == 2 )); then
    die artifact_unavailable "official DAPI release release/v${dapi_version} is malformed or does not bind the observed commit"
  fi
  if metadata="$(official_release_asset dapi product-science/race-releases "$dapi_version" "$dapi_commit" decentralized-api-amd64.zip)"; then
    printf '%s\n' "$metadata"
    return 0
  else
    rc=$?
  fi
  if (( rc == 2 )); then
    die artifact_unavailable "official DAPI mirror release release/v${dapi_version} is malformed or does not bind the observed commit"
  fi
  die artifact_unavailable "official release metadata is unavailable for dapi release/v${dapi_version}"
}

registry_image() {
  local repository="$1" tag="$2" token_file headers token digest
  token_file="$tmp/${repository//\//-}-${tag}.token.json"
  headers="$tmp/${repository//\//-}-${tag}.headers"
  fetch_json "https://ghcr.io/token?service=ghcr.io&scope=repository:${repository}:pull" "$token_file" \
    || die artifact_unavailable "GHCR token endpoint is unavailable for ${repository}:${tag}"
  token="$(jq -er '.token | select(type == "string" and length > 0)' "$token_file")" \
    || die artifact_unavailable "GHCR token response is invalid for ${repository}:${tag}"
  curl -fsSI --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 --retry-all-errors -D "$headers" -o /dev/null \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${repository}/manifests/${tag}" \
    || die artifact_unavailable "GHCR manifest is unavailable for ${repository}:${tag}"
  digest="$(tr -d '\r' <"$headers" | awk 'tolower($1) == "docker-content-digest:" {print $2; exit}')"
  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die artifact_unavailable "GHCR manifest has no immutable digest for ${repository}:${tag}"
  printf '%s:%s@%s' "ghcr.io/${repository}" "$tag" "$digest"
}

component() {
  local runtime="$1" image="$2" mode="$3" metadata="$4" source_sha
  source_sha="$(sha256_text "$metadata")"
  jq -cn --argjson observed "$runtime" --arg image "$image" --arg mode "$mode" --argjson metadata "$metadata" --arg sha "$source_sha" \
    '$image | capture("^(?<repository>.+)@(?<digest>sha256:[a-f0-9]{64})$") as $image | {observed:$observed,expected_runtime:$observed,installation:{mode:$mode,image:$image,binary:{url:$metadata.asset.browser_download_url,sha256:($metadata.asset.digest | ltrimstr("sha256:"))}},mapping_source:{kind:"official_artifact",id:("github-release/" + $metadata.repository + "/" + $metadata.release_tag + "/" + $metadata.asset.name),definition_sha256:$sha}}'
}

component_host_template() {
  local runtime="$1" image="$2" mode="$3" source_sha source_id
  source_id="github-raw/${GDC_JOIN_HOST_STACK_REPOSITORY}/${GDC_JOIN_HOST_STACK_COMMIT}/deploy/join/docker-compose.yml#services.api"
  source_sha="$(sha256_text "${source_id}:${GDC_JOIN_HOST_STACK_COMPOSE_SHA256}:${image}")"
  jq -cn --argjson observed "$runtime" --arg image "$image" --arg mode "$mode" --arg id "$source_id" --arg sha "$source_sha" \
    '$image | capture("^(?<repository>.+)@(?<digest>sha256:[a-f0-9]{64})$") as $image | {observed:$observed,expected_runtime:$observed,installation:{mode:$mode,image:$image},mapping_source:{kind:"official_artifact",id:$id,definition_sha256:$sha}}'
}

compose_service_image() {
  local compose="$1" service="$2"
  awk -v service="$service" '
    $0 == "  " service ":" { active=1; next }
    active && $0 ~ /^  [A-Za-z0-9_-]+:$/ { exit }
    active && $1 == "image:" { print $2; exit }
  ' "$compose"
}

resolve_host_stack_images() {
  local compose node_image node_tag api_image api_tag actual_sha
  compose="$tmp/host-stack-compose.yml"
  [[ "$GDC_JOIN_HOST_STACK_REPOSITORY" == gonka-ai/gonka && "$GDC_JOIN_HOST_STACK_COMMIT" =~ ^[a-f0-9]{40}$ && "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" =~ ^[a-f0-9]{64}$ ]] \
    || die artifact_unavailable 'Host template has an invalid official Host-stack source'
  fetch_file "https://raw.githubusercontent.com/${GDC_JOIN_HOST_STACK_REPOSITORY}/${GDC_JOIN_HOST_STACK_COMMIT}/deploy/join/docker-compose.yml" "$compose" \
    || die artifact_unavailable 'official Host-stack Compose is unavailable'
  actual_sha="$(sha256sum "$compose" | awk '{print $1}')"
  [[ "$actual_sha" == "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" ]] \
    || die artifact_unavailable 'official Host-stack Compose does not match the pinned template digest'
  node_image="$(compose_service_image "$compose" node)"
  [[ "$node_image" =~ ^ghcr.io/product-science/inferenced:([A-Za-z0-9._-]+)$ ]] \
    || die artifact_unavailable 'official Host-stack Core image is invalid'
  node_tag="${BASH_REMATCH[1]}"
  [[ "$node_tag" == "$core_version" ]] \
    || die artifact_unavailable "official Host-stack Core tag ${node_tag} disagrees with observed Core ${core_version}"
  api_image="$(compose_service_image "$compose" api)"
  [[ "$api_image" =~ ^ghcr.io/product-science/api:([A-Za-z0-9._-]+)$ ]] \
    || die artifact_unavailable 'official Host-stack API image is invalid'
  api_tag="${BASH_REMATCH[1]}"
  # DAPI advances inside this base image through Cosmovisor.  Its externally
  # observed version is deliberately not treated as an OCI tag.
  host_stack_api_image="$(registry_image product-science/api "$api_tag")"
}

core_runtime="$(jq -c .runtime.core "$observation")"
dapi_runtime="$(jq -c .runtime.dapi "$observation")"
core_version="$(jq -r .runtime.core.version "$observation")"
core_commit="$(jq -r .runtime.core.commit "$observation")"
dapi_version="$(jq -r .runtime.dapi.version "$observation")"
dapi_commit="$(jq -r .runtime.dapi.commit "$observation")"

# Resolve each component independently. This preserves an observed mixed
# Core/DAPI tuple without selecting, ranking, or synthesising a release profile.
# shellcheck disable=SC1090
source "$ROOT/profiles/join-host-defaults.lock"
core_metadata="$(official_core_release)"
dapi_metadata="$(official_dapi_release)"
core_image="$(registry_image product-science/inferenced "$core_version")"
resolve_host_stack_images
dapi_image="$host_stack_api_image"
tmkms_image="$(registry_image product-science/tmkms-softsign-with-keygen "$core_version")"
edge_api_image="$(registry_image product-science/edge-api "$core_version")"
versiond_image="$(registry_image product-science/versiond "$core_version")"
proxy_image="$(registry_image product-science/proxy "$core_version")"

# These are runbook-owned hardware and operator defaults. They are a template,
# not a per-network or runtime release selector.
# shellcheck disable=SC1090
source "$ROOT/profiles/deployments/community-lab.lock"
# shellcheck disable=SC1090
source "$ROOT/profiles/models/qwen3-0.6b.lock"
# shellcheck disable=SC1090
source "$ROOT/profiles/operator-services/gdc-lab.lock"
for value in GDC_JOIN_HOST_STACK_REPOSITORY GDC_JOIN_HOST_STACK_COMMIT GDC_JOIN_HOST_STACK_COMPOSE_SHA256 MLNODE_GENERIC_IMAGE MLNODE_PROXY_IMAGE GDC_JOIN_EFFECTIVE_EPOCHS GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS POSTGRES_IMAGE EXPLORER_IMAGE CADDY_IMAGE GRAFANA_IMAGE NODE_EXPORTER_IMAGE CADVISOR_IMAGE; do
  [[ -n "${!value:-}" ]] || die artifact_unavailable "Host template lacks ${value}"
done
template_sha="$(cat "$ROOT/profiles/join-host-defaults.lock" "$ROOT/profiles/deployments/community-lab.lock" "$ROOT/profiles/models/qwen3-0.6b.lock" "$ROOT/profiles/operator-services/gdc-lab.lock" | sha256sum | awk '{print $1}')"
host_basis="$(jq -cn --arg core_version "$core_version" --arg core_commit "$core_commit" --arg tmkms "$tmkms_image" --arg edge "$edge_api_image" --arg versiond "$versiond_image" --arg proxy "$proxy_image" --arg stack_repository "$GDC_JOIN_HOST_STACK_REPOSITORY" --arg stack_commit "$GDC_JOIN_HOST_STACK_COMMIT" --arg stack_compose_sha256 "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" --arg stack_api_image "$dapi_image" --arg defaults "$template_sha" '{core:{version:$core_version,commit:$core_commit},host_stack:{repository:$stack_repository,commit:$stack_commit,compose_sha256:$stack_compose_sha256,api_image:$stack_api_image},runtime_images:{tmkms:$tmkms,edge_api:$edge,versiond:$versiond,proxy:$proxy},template_sha256:$defaults}')"
host_sha="$(sha256_text "$host_basis")"
core="$(component "$core_runtime" "$core_image" image_plus_cosmovisor "$core_metadata")"
# The API image is an immutable Host template, while the executable it starts
# is the exact observed DAPI release.  Keep both bindings: the former makes
# the service reproducible and the latter prevents Cosmovisor from silently
# retaining a stale binary from that base image.
dapi="$(component "$dapi_runtime" "$dapi_image" image_plus_cosmovisor "$dapi_metadata")"
host_envelope="$(jq -cn --arg tmkms "$tmkms_image" --arg postgres "$POSTGRES_IMAGE" --arg edge "$edge_api_image" --arg versiond "$versiond_image" --arg proxy "$proxy_image" --arg explorer "$EXPLORER_IMAGE" --arg mlnode "$MLNODE_GENERIC_IMAGE" --arg mlnode_proxy "$MLNODE_PROXY_IMAGE" --arg caddy "$CADDY_IMAGE" --arg grafana "$GRAFANA_IMAGE" --arg node_exporter "$NODE_EXPORTER_IMAGE" --arg cadvisor "$CADVISOR_IMAGE" --arg stack_repository "$GDC_JOIN_HOST_STACK_REPOSITORY" --arg stack_commit "$GDC_JOIN_HOST_STACK_COMMIT" --arg stack_compose_sha256 "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" --arg stack_api_image "$dapi_image" --argjson dashboard "$DASHBOARD_PORT" --arg edge_profile edge-api --arg edge_service edge-api --arg model "$MODEL_ID" --arg model_revision "$MODEL_REVISION" --argjson context "$MLNODE_CONTEXT_LENGTH" --argjson seqs "$MLNODE_MAX_NUM_SEQS" --arg utilization "$MLNODE_GPU_MEMORY_UTILIZATION" --arg dtype "$MLNODE_DTYPE" --argjson parallel "$MLNODE_TENSOR_PARALLEL_SIZE" --argjson epochs "$GDC_JOIN_EFFECTIVE_EPOCHS" --argjson timeout "$GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS" --arg sha "$host_sha" '{tmkms_image:$tmkms,postgres_image:$postgres,edge_api_image:$edge,versiond_image:$versiond,proxy_image:$proxy,explorer_image:$explorer,mlnode_image:$mlnode,mlnode_proxy_image:$mlnode_proxy,caddy_image:$caddy,grafana_image:$grafana,node_exporter_image:$node_exporter,cadvisor_image:$cadvisor,host_stack:{repository:$stack_repository,commit:$stack_commit,compose_sha256:$stack_compose_sha256,api_image:$stack_api_image},dashboard_port:$dashboard,edge_api_compose_profile:$edge_profile,edge_api_service_name:$edge_service,model_id:$model,model_revision:$model_revision,mlnode_context_length:$context,mlnode_max_num_seqs:$seqs,mlnode_gpu_memory_utilization:$utilization,mlnode_dtype:$dtype,mlnode_tensor_parallel_size:$parallel,join_effective_epochs:$epochs,join_effective_timeout_seconds:$timeout,mapping_source:{kind:"official_artifact",id:"official-runtime-and-host-template/v1",definition_sha256:$sha}}')"

mkdir -p "$(dirname "$output")"
output_tmp="$(mktemp "$(dirname "$output")/.join-components.XXXXXX")"
jq -cn --argjson core "$core" --argjson dapi "$dapi" --argjson host_envelope "$host_envelope" '{core:$core,dapi:$dapi,host_envelope:$host_envelope}' | jq -cS . >"$output_tmp"
chmod 0600 "$output_tmp"
mv -f "$output_tmp" "$output"
printf 'PASS resolved selected runtime from official artifacts output=%s\n' "$output"
