#!/bin/sh
# Resolve immutable JOIN inputs from observed runtime identities. This local
# preflight deliberately does not select a release-profile catalogue entry.
set -eu

usage() { printf 'Usage: %s --observation FILE --output FILE\n' "$0" >&2; }
die() { printf 'runtime_%s: %s\n' "$1" "$2" >&2; exit 1; }

observation=''
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --observation|--output)
      option=$1
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      case "$option" in
        --observation) observation=$1 ;;
        --output) output=$1 ;;
      esac
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done
[ -r "$observation" ] && [ -n "$output" ] || { usage; exit 2; }

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"
sha256_text() { printf '%s\n' "$1" | gdc_sha256_stdin; }
gdc_require_jq || exit $?
command -v curl >/dev/null 2>&1 || die dependency_missing 'curl is required'
jq -e '.schema_version == 1 and .kind == "gdc-network-observation" and .result == {state:"ready",reason:"none"} and (.runtime.core.commit | test("^[a-f0-9]{40}$")) and (.runtime.dapi.commit | test("^[a-f0-9]{40}$"))' "$observation" >/dev/null \
  || die artifact_unavailable 'network observation is not ready'

tmp=$(gdc_mktemp_dir)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fetch_json() {
  curl -fsS --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 --retry-all-errors "$1" >"$2"
}

official_release_asset() {
  ora_component=$1
  ora_publisher=$2
  ora_version=$3
  ora_commit=$4
  ora_asset_name=$5
  ora_tag=release/v$ora_version
  ora_safe_publisher=$(printf '%s' "$ora_publisher" | tr / -)
  ora_release_file=$tmp/$ora_component-$ora_safe_publisher-release.json
  ora_refs_file=$tmp/$ora_component-refs.json
  ora_url_tag=$(printf '%s' "$ora_tag" | sed 's#/#%2F#g')
  fetch_json "https://api.github.com/repos/${ora_publisher}/releases/tags/${ora_url_tag}" "$ora_release_file" || return 1
  jq -e --arg tag "$ora_tag" --arg asset "$ora_asset_name" '
    .tag_name == $tag and
    ([.assets[] | select(.name == $asset and (.browser_download_url | type == "string" and startswith("https://github.com/")) and (.digest | type == "string" and test("^sha256:[a-f0-9]{64}$")))] | length == 1)
  ' "$ora_release_file" >/dev/null || return 2
  fetch_json "https://api.github.com/repos/gonka-ai/gonka/git/matching-refs/tags/${ora_tag}" "$ora_refs_file" || return 1
  ora_tag_commit=$(jq -er --arg ref "refs/tags/${ora_tag}" '[.[] | select(.ref == $ref and .object.type == "commit") | .object.sha] | if length == 1 then .[0] else empty end' "$ora_refs_file") || return 2
  [ "$ora_tag_commit" = "$ora_commit" ] || return 2
  ora_asset=$(jq -c --arg asset "$ora_asset_name" '[.assets[] | select(.name == $asset)] | .[0] | {name,browser_download_url,digest}' "$ora_release_file")
  jq -cn --arg component "$ora_component" --arg publisher "$ora_publisher" --arg tag "$ora_tag" --arg commit "$ora_tag_commit" --argjson asset "$ora_asset" \
    '{component:$component,provider:"github",repository:$publisher,tag_authority_repository:"gonka-ai/gonka",release_tag:$tag,commit:$commit,asset:$asset}' | jq -cS .
}

official_core_release() {
  if ocr_metadata=$(official_release_asset core gonka-ai/gonka "$core_version" "$core_commit" inferenced-linux-amd64.zip); then
    printf '%s\n' "$ocr_metadata"
    return 0
  else
    ocr_rc=$?
  fi
  [ "$ocr_rc" -eq 2 ] \
    && die artifact_unavailable "official Core release release/v${core_version} is malformed or does not bind the observed commit"
  die artifact_unavailable "official release metadata is unavailable for core release/v${core_version}"
}

official_dapi_release() {
  if odr_metadata=$(official_release_asset dapi gonka-ai/gonka "$dapi_version" "$dapi_commit" decentralized-api-amd64.zip); then
    printf '%s\n' "$odr_metadata"
    return 0
  else
    odr_rc=$?
  fi
  [ "$odr_rc" -eq 2 ] \
    && die artifact_unavailable "official DAPI release release/v${dapi_version} is malformed or does not bind the observed commit"
  if odr_metadata=$(official_release_asset dapi product-science/race-releases "$dapi_version" "$dapi_commit" decentralized-api-amd64.zip); then
    printf '%s\n' "$odr_metadata"
    return 0
  else
    odr_rc=$?
  fi
  [ "$odr_rc" -eq 2 ] \
    && die artifact_unavailable "official DAPI mirror release release/v${dapi_version} is malformed or does not bind the observed commit"
  die artifact_unavailable "official release metadata is unavailable for dapi release/v${dapi_version}"
}

registry_image() {
  ri_repository=$1
  ri_tag=$2
  ri_safe_repository=$(printf '%s' "$ri_repository" | tr / -)
  ri_token_file=$tmp/$ri_safe_repository-$ri_tag.token.json
  ri_headers=$tmp/$ri_safe_repository-$ri_tag.headers
  fetch_json "https://ghcr.io/token?service=ghcr.io&scope=repository:${ri_repository}:pull" "$ri_token_file" \
    || die artifact_unavailable "GHCR token endpoint is unavailable for ${ri_repository}:${ri_tag}"
  ri_token=$(jq -er '.token | select(type == "string" and length > 0)' "$ri_token_file") \
    || die artifact_unavailable "GHCR token response is invalid for ${ri_repository}:${ri_tag}"
  curl -fsSI --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 --retry-all-errors -D "$ri_headers" -o /dev/null \
    -H "Authorization: Bearer ${ri_token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${ri_repository}/manifests/${ri_tag}" \
    || die artifact_unavailable "GHCR manifest is unavailable for ${ri_repository}:${ri_tag}"
  ri_digest=$(tr -d '\r' <"$ri_headers" | awk 'tolower($1) == "docker-content-digest:" {print $2; exit}')
  printf '%s\n' "$ri_digest" | grep -Eq '^sha256:[a-f0-9]{64}$' \
    || die artifact_unavailable "GHCR manifest has no immutable digest for ${ri_repository}:${ri_tag}"
  printf 'ghcr.io/%s:%s@%s' "$ri_repository" "$ri_tag" "$ri_digest"
}

component() {
  c_runtime=$1
  c_image=$2
  c_mode=$3
  c_metadata=$4
  c_source_sha=$(sha256_text "$c_metadata")
  jq -cn --argjson observed "$c_runtime" --arg image "$c_image" --arg mode "$c_mode" --argjson metadata "$c_metadata" --arg sha "$c_source_sha" \
    '$image | capture("^(?<repository>.+)@(?<digest>sha256:[a-f0-9]{64})$") as $image | {observed:$observed,expected_runtime:$observed,installation:{mode:$mode,image:$image,binary:{url:$metadata.asset.browser_download_url,sha256:($metadata.asset.digest | ltrimstr("sha256:"))}},mapping_source:{kind:"official_artifact",id:("github-release/" + $metadata.repository + "/" + $metadata.release_tag + "/" + $metadata.asset.name),definition_sha256:$sha}}'
}

compose_service_image() {
  awk -v service="$2" '
    $0 == "  " service ":" { active=1; next }
    active && $0 ~ /^  [A-Za-z0-9_-]+:$/ { exit }
    active && $1 == "image:" { print $2; exit }
  ' "$1"
}

resolve_host_stack_images() {
  [ "$GDC_JOIN_HOST_STACK_REPOSITORY" = gonka-ai/gonka ] \
    && printf '%s\n' "$GDC_JOIN_HOST_STACK_COMMIT" | grep -Eq '^[a-f0-9]{40}$' \
    && printf '%s\n' "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" | grep -Eq '^[a-f0-9]{64}$' \
    || die artifact_unavailable 'Host template has an invalid official Host-stack source'
  rhs_compose=$tmp/host-stack-compose.yml
  fetch_json "https://raw.githubusercontent.com/${GDC_JOIN_HOST_STACK_REPOSITORY}/${GDC_JOIN_HOST_STACK_COMMIT}/deploy/join/docker-compose.yml" "$rhs_compose" \
    || die artifact_unavailable 'official Host-stack Compose is unavailable'
  rhs_sha=$(gdc_sha256 "$rhs_compose")
  [ "$rhs_sha" = "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" ] \
    || die artifact_unavailable 'official Host-stack Compose does not match the pinned template digest'
  rhs_node_image=$(compose_service_image "$rhs_compose" node)
  printf '%s\n' "$rhs_node_image" | grep -Eq '^ghcr.io/product-science/inferenced:[A-Za-z0-9._-]+$' \
    || die artifact_unavailable 'official Host-stack Core image is invalid'
  rhs_node_tag=${rhs_node_image#ghcr.io/product-science/inferenced:}
  [ "$rhs_node_tag" = "$core_version" ] \
    || die artifact_unavailable "official Host-stack Core tag ${rhs_node_tag} disagrees with observed Core ${core_version}"
  rhs_api_image=$(compose_service_image "$rhs_compose" api)
  printf '%s\n' "$rhs_api_image" | grep -Eq '^ghcr.io/product-science/api:[A-Za-z0-9._-]+$' \
    || die artifact_unavailable 'official Host-stack API image is invalid'
  rhs_api_tag=${rhs_api_image#ghcr.io/product-science/api:}
  host_stack_api_image=$(registry_image product-science/api "$rhs_api_tag")
}

core_runtime=$(jq -c .runtime.core "$observation")
dapi_runtime=$(jq -c .runtime.dapi "$observation")
core_version=$(jq -r .runtime.core.version "$observation")
core_commit=$(jq -r .runtime.core.commit "$observation")
dapi_version=$(jq -r .runtime.dapi.version "$observation")
dapi_commit=$(jq -r .runtime.dapi.commit "$observation")

# These local files are repository-owned, static POSIX assignments. They are
# Host-envelope defaults only; runtime versions/commits remain observations.
. "$ROOT/profiles/join-host-defaults.lock"
. "$ROOT/profiles/deployments/community-lab.lock"
. "$ROOT/profiles/models/qwen3-0.6b.lock"
. "$ROOT/profiles/operator-services/gdc-lab.lock"
[ -n "$GDC_JOIN_HOST_STACK_REPOSITORY" ] && [ -n "$GDC_JOIN_HOST_STACK_COMMIT" ] \
  && [ -n "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" ] && [ -n "$MLNODE_GENERIC_IMAGE" ] \
  && [ -n "$MLNODE_PROXY_IMAGE" ] && [ -n "$GDC_JOIN_EFFECTIVE_EPOCHS" ] \
  && [ -n "$GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS" ] && [ -n "$POSTGRES_IMAGE" ] \
  && [ -n "$EXPLORER_IMAGE" ] && [ -n "$CADDY_IMAGE" ] && [ -n "$GRAFANA_IMAGE" ] \
  && [ -n "$NODE_EXPORTER_IMAGE" ] && [ -n "$CADVISOR_IMAGE" ] \
  || die artifact_unavailable 'Host template lacks a required default'

core_metadata=$(official_core_release)
dapi_metadata=$(official_dapi_release)
core_image=$(registry_image product-science/inferenced "$core_version")
resolve_host_stack_images
dapi_image=$host_stack_api_image
tmkms_image=$(registry_image product-science/tmkms-softsign-with-keygen "$core_version")
edge_api_image=$(registry_image product-science/edge-api "$core_version")
versiond_image=$(registry_image product-science/versiond "$core_version")
proxy_image=$(registry_image product-science/proxy "$core_version")

template_sha=$(cat "$ROOT/profiles/join-host-defaults.lock" "$ROOT/profiles/deployments/community-lab.lock" "$ROOT/profiles/models/qwen3-0.6b.lock" "$ROOT/profiles/operator-services/gdc-lab.lock" | gdc_sha256_stdin)
host_basis=$(jq -cn --arg core_version "$core_version" --arg core_commit "$core_commit" --arg tmkms "$tmkms_image" --arg edge "$edge_api_image" --arg versiond "$versiond_image" --arg proxy "$proxy_image" --arg stack_repository "$GDC_JOIN_HOST_STACK_REPOSITORY" --arg stack_commit "$GDC_JOIN_HOST_STACK_COMMIT" --arg stack_compose_sha256 "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" --arg stack_api_image "$dapi_image" --arg defaults "$template_sha" '{core:{version:$core_version,commit:$core_commit},host_stack:{repository:$stack_repository,commit:$stack_commit,compose_sha256:$stack_compose_sha256,api_image:$stack_api_image},runtime_images:{tmkms:$tmkms,edge_api:$edge,versiond:$versiond,proxy:$proxy},template_sha256:$defaults}')
host_sha=$(sha256_text "$host_basis")
core=$(component "$core_runtime" "$core_image" image_plus_cosmovisor "$core_metadata")
dapi=$(component "$dapi_runtime" "$dapi_image" image_plus_cosmovisor "$dapi_metadata")
host_envelope=$(jq -cn --arg tmkms "$tmkms_image" --arg postgres "$POSTGRES_IMAGE" --arg edge "$edge_api_image" --arg versiond "$versiond_image" --arg proxy "$proxy_image" --arg explorer "$EXPLORER_IMAGE" --arg mlnode "$MLNODE_GENERIC_IMAGE" --arg mlnode_proxy "$MLNODE_PROXY_IMAGE" --arg caddy "$CADDY_IMAGE" --arg grafana "$GRAFANA_IMAGE" --arg node_exporter "$NODE_EXPORTER_IMAGE" --arg cadvisor "$CADVISOR_IMAGE" --arg stack_repository "$GDC_JOIN_HOST_STACK_REPOSITORY" --arg stack_commit "$GDC_JOIN_HOST_STACK_COMMIT" --arg stack_compose_sha256 "$GDC_JOIN_HOST_STACK_COMPOSE_SHA256" --arg stack_api_image "$dapi_image" --argjson dashboard "$DASHBOARD_PORT" --arg edge_profile edge-api --arg edge_service edge-api --arg model "$MODEL_ID" --arg model_revision "$MODEL_REVISION" --argjson context "$MLNODE_CONTEXT_LENGTH" --argjson seqs "$MLNODE_MAX_NUM_SEQS" --arg utilization "$MLNODE_GPU_MEMORY_UTILIZATION" --arg dtype "$MLNODE_DTYPE" --argjson parallel "$MLNODE_TENSOR_PARALLEL_SIZE" --argjson epochs "$GDC_JOIN_EFFECTIVE_EPOCHS" --argjson timeout "$GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS" --arg sha "$host_sha" '{tmkms_image:$tmkms,postgres_image:$postgres,edge_api_image:$edge,versiond_image:$versiond,proxy_image:$proxy,explorer_image:$explorer,mlnode_image:$mlnode,mlnode_proxy_image:$mlnode_proxy,caddy_image:$caddy,grafana_image:$grafana,node_exporter_image:$node_exporter,cadvisor_image:$cadvisor,host_stack:{repository:$stack_repository,commit:$stack_commit,compose_sha256:$stack_compose_sha256,api_image:$stack_api_image},dashboard_port:$dashboard,edge_api_compose_profile:$edge_profile,edge_api_service_name:$edge_service,model_id:$model,model_revision:$model_revision,mlnode_context_length:$context,mlnode_max_num_seqs:$seqs,mlnode_gpu_memory_utilization:$utilization,mlnode_dtype:$dtype,mlnode_tensor_parallel_size:$parallel,join_effective_epochs:$epochs,join_effective_timeout_seconds:$timeout,mapping_source:{kind:"official_artifact",id:"official-runtime-and-host-template/v1",definition_sha256:$sha}}')

output_dir=$(dirname "$output")
mkdir -p "$output_dir"
output_tmp=$(mktemp "$output_dir/.join-components.XXXXXX")
jq -cn --argjson core "$core" --argjson dapi "$dapi" --argjson host_envelope "$host_envelope" '{core:$core,dapi:$dapi,host_envelope:$host_envelope}' | jq -cS . >"$output_tmp"
chmod 0600 "$output_tmp"
mv -f "$output_tmp" "$output"
printf 'PASS resolved selected runtime from official artifacts output=%s\n' "$output"
