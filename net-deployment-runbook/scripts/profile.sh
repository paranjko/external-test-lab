#!/usr/bin/env bash
# Upstream network release, lab deployment, model and operator-service
# profiles are separate inputs. Operator observability changes must not alter
# the identity of the Gonka release under test.

profile_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

load_profiles() {
  local root release deployment model operator comp_target comp_env
  root="$(profile_root)"
  release="${GDC_RELEASE_PROFILE:-v2026.07.23}"
  deployment="${GDC_DEPLOYMENT_PROFILE:-community-lab}"
  model="${GDC_MODEL_PROFILE:-qwen3-0.6b}"
  operator="${GDC_OPERATOR_SERVICES_PROFILE:-gdc-lab}"

  comp_target="${GDC_COMPOSITION:-}"
  if [[ -z "$comp_target" && -f "$root/profiles/compositions/$release.json" ]]; then
    comp_target="$release"
  fi

  if [[ -n "$comp_target" ]]; then
    comp_env="$(python3 "$root/scripts/release-candidate.py" composition export-env "$comp_target")" || {
      echo "invalid or unverified composition: $comp_target" >&2
      return 2
    }
    eval "$comp_env"
    release="$GDC_RELEASE_PROFILE"
  fi

  [[ "$release" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "invalid release profile: $release" >&2; return 2; }
  [[ "$deployment" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "invalid deployment profile: $deployment" >&2; return 2; }
  [[ "$model" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "invalid model profile: $model" >&2; return 2; }
  [[ "$operator" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "invalid operator-services profile: $operator" >&2; return 2; }
  [[ -r "$root/profiles/releases/$release.lock" ]] || { echo "unknown release profile: $release" >&2; return 2; }
  [[ -r "$root/profiles/deployments/$deployment.lock" ]] || { echo "unknown deployment profile: $deployment" >&2; return 2; }
  [[ -r "$root/profiles/models/$model.lock" ]] || { echo "unknown model profile: $model" >&2; return 2; }
  [[ -r "$root/profiles/operator-services/$operator.lock" ]] || { echo "unknown operator-services profile: $operator" >&2; return 2; }
  unset GONKA_HOST_STACK_COMMIT GONKA_HOST_STACK_DOC_SHA256 GONKA_HOST_STACK_COMPOSE_SHA256
  unset DAPI_SOURCE_REF DAPI_COMMIT
  unset LAB_CANDIDATE UPGRADE_FROM_PROFILE GONKA_UPGRADE_METADATA_URL
  unset CANDIDATE_DEFINITION_SHA256 CANDIDATE_BUILD_MANIFEST_SHA256
  unset CANDIDATE_DEVSHARD_SOURCE_REF CANDIDATE_DEVSHARD_COMMIT
  unset CANDIDATE_DEVSHARD_PROTOCOL_VERSION CANDIDATE_DEVSHARD_SUPPORTED_PROTOCOLS
  unset CANDIDATE_LOCAL_GATEWAY_IMAGE CANDIDATE_POSTGRES_IMAGE
  unset DEVSHARD_V5_URL DEVSHARD_V5_SHA256 DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL
  unset DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256 CANDIDATE_LAYER CANDIDATE_COMPOSITION
  # If split devshard lock, load base release lock first for core variables
  if grep -Eq '^CANDIDATE_LAYER=(core|devshard)$' "$root/profiles/releases/$release.lock" 2>/dev/null; then
    local base_profile
    base_profile="$(awk -F= '$1 == "UPGRADE_FROM_PROFILE" {print $2; exit}' "$root/profiles/releases/$release.lock")"
    base_profile="${base_profile:-v2026.08.06}"
    # shellcheck disable=SC1090
    source "$root/profiles/releases/$base_profile.lock"
  fi
  # shellcheck disable=SC1090
  source "$root/profiles/releases/$release.lock"
  # v0.2.14 predates edge-api. These are runtime wiring defaults, not release
  # inputs, so the immutable release lock does not carry blank assignments.
  if [[ "$EDGE_API_ENABLED" == false ]]; then
    EDGE_API_COMPOSE_PROFILE=''
    EDGE_API_SERVICE_NAME=''
  fi
  # shellcheck disable=SC1090
  source "$root/profiles/deployments/$deployment.lock"
  # shellcheck disable=SC1090
  source "$root/profiles/models/$model.lock"
  # shellcheck disable=SC1090
  source "$root/profiles/operator-services/$operator.lock"
  if [[ "${LAB_CANDIDATE:-false}" == true ]]; then
    DEVSHARD_SOURCE_REF="${CANDIDATE_DEVSHARD_SOURCE_REF:-${DEVSHARD_SOURCE_REF:-${DEVSHARD_V4_SOURCE_REF:-refs/heads/main}}}"
    DEVSHARD_COMMIT="${CANDIDATE_DEVSHARD_COMMIT:-${DEVSHARD_COMMIT:-}}"
    DEVSHARD_PROTOCOL_VERSION="${CANDIDATE_DEVSHARD_PROTOCOL_VERSION:-${DEVSHARD_PROTOCOL_VERSION:-v3}}"
    DEVSHARD_SUPPORTED_PROTOCOLS="${CANDIDATE_DEVSHARD_SUPPORTED_PROTOCOLS:-${DEVSHARD_SUPPORTED_PROTOCOLS:-v3}}"
    LOCAL_GATEWAY_IMAGE="${CANDIDATE_LOCAL_GATEWAY_IMAGE:-${LOCAL_GATEWAY_IMAGE:-}}"
    POSTGRES_IMAGE="${CANDIDATE_POSTGRES_IMAGE:-${POSTGRES_IMAGE:-}}"
    MLNODE_BLACKWELL_IMAGE="$MLNODE_GENERIC_IMAGE"
    export DEVSHARD_SOURCE_REF DEVSHARD_COMMIT DEVSHARD_PROTOCOL_VERSION
    export DEVSHARD_SUPPORTED_PROTOCOLS LOCAL_GATEWAY_IMAGE POSTGRES_IMAGE MLNODE_BLACKWELL_IMAGE
  fi
  if [[ -n "${comp_env:-}" ]]; then
    eval "$comp_env"
  fi
  if [[ -n "${DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL:-}" ]]; then
    export DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256
  fi
  if [[ -n "${GDC_COMPOSITION_HASH:-}" ]]; then
    export GDC_COMPOSITION_HASH
  fi
  if [[ -n "${GDC_RESOLVED_IMAGE_LOCK:-}" ]]; then
    [[ -r "$GDC_RESOLVED_IMAGE_LOCK" ]] || { echo "resolved image lock is unreadable: $GDC_RESOLVED_IMAGE_LOCK" >&2; return 2; }
    # shellcheck disable=SC1090
    source "$GDC_RESOLVED_IMAGE_LOCK"
  fi
  export GDC_RELEASE_PROFILE="$release" GDC_DEPLOYMENT_PROFILE="$deployment"
  export GDC_MODEL_PROFILE="$model" GDC_OPERATOR_SERVICES_PROFILE="$operator"
  export GONKA_REPOSITORY GONKA_SOURCE_REF GONKA_COMMIT MODEL_ID MODEL_REVISION
  [[ "${JOIN_BOOTSTRAP_FORMAT:-}" =~ ^[1-9][0-9]*$ ]] || { echo 'release profile has an invalid JOIN bootstrap format' >&2; return 2; }
  export JOIN_BOOTSTRAP_FORMAT
  export EDGE_API_COMPOSE_PROFILE EDGE_API_SERVICE_NAME
}

profile_summary() {
  if [[ -n "${GDC_COMPOSITION:-}" ]]; then
    printf 'composition=%s\ncomposition_hash=%s\n' "$GDC_COMPOSITION" "${GDC_COMPOSITION_HASH:-}"
  fi
  printf 'release_profile=%s\ndeployment_profile=%s\nmodel_profile=%s\noperator_services_profile=%s\n' \
    "$GDC_RELEASE_PROFILE" "$GDC_DEPLOYMENT_PROFILE" "$GDC_MODEL_PROFILE" "$GDC_OPERATOR_SERVICES_PROFILE"
  printf 'gonka_source_ref=%s\ngonka_commit=%s\nmodel=%s@%s\n' \
    "$GONKA_SOURCE_REF" "$GONKA_COMMIT" "$MODEL_ID" "$MODEL_REVISION"
  printf 'join_bootstrap_format=%s\n' "$JOIN_BOOTSTRAP_FORMAT"
  if [[ -n "${GONKA_HOST_STACK_COMMIT:-}" ]]; then
    printf 'gonka_host_stack_commit=%s\ngonka_host_stack_doc_sha256=%s\ngonka_host_stack_compose_sha256=%s\n' \
      "$GONKA_HOST_STACK_COMMIT" "$GONKA_HOST_STACK_DOC_SHA256" "$GONKA_HOST_STACK_COMPOSE_SHA256"
    printf 'dapi_source_ref=%s\ndapi_commit=%s\n' "$DAPI_SOURCE_REF" "$DAPI_COMMIT"
  fi
  printf 'network_profile_hash=%s\noperator_services_profile_hash=%s\n' \
    "$(profile_hash)" "$(operator_profile_hash)"
  printf 'tmkms_image=%s\ninferenced_image=%s\ndapi_image=%s\nedge_api_image=%s\n' \
    "$TMKMS_IMAGE" "$INFERENCED_IMAGE" "$DAPI_IMAGE" "$EDGE_API_IMAGE"
  printf 'versiond_image=%s\nproxy_image=%s\npostgres_image=%s\n' \
    "$VERSIOND_IMAGE" "$PROXY_IMAGE" "$POSTGRES_IMAGE"
  printf 'mlnode_generic_image=%s\nmlnode_blackwell_image=%s\nmlnode_proxy_image=%s\n' \
    "$MLNODE_GENERIC_IMAGE" "$MLNODE_BLACKWELL_IMAGE" "$MLNODE_PROXY_IMAGE"
  printf 'bridge_image=%s\n' "$BRIDGE_IMAGE"
  printf 'operator_explorer_image=%s\noperator_caddy_image=%s\noperator_prometheus_image=%s\noperator_grafana_image=%s\n' \
    "$EXPLORER_IMAGE" "$CADDY_IMAGE" "$PROMETHEUS_IMAGE" "$GRAFANA_IMAGE"
  printf 'operator_alertmanager_image=%s\noperator_blackbox_image=%s\noperator_node_exporter_image=%s\noperator_cadvisor_image=%s\n' \
    "$ALERTMANAGER_IMAGE" "$BLACKBOX_IMAGE" "$NODE_EXPORTER_IMAGE" "$CADVISOR_IMAGE"
}

profile_hash() {
  local root
  root="$(profile_root)"
  if [[ -n "${GDC_COMPOSITION_HASH:-}" ]]; then
    {
      printf '%s\n' "$GDC_COMPOSITION_HASH"
      sha256sum "$root/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" \
        "$root/profiles/models/$GDC_MODEL_PROFILE.lock" | awk '{print $1}'
    } | sha256sum | awk '{print $1}'
    return
  fi
  sha256sum "$root/profiles/releases/$GDC_RELEASE_PROFILE.lock" \
    "$root/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" \
    "$root/profiles/models/$GDC_MODEL_PROFILE.lock" | awk '{print $1}' | sha256sum | awk '{print $1}'
}

operator_profile_hash() {
  local root
  root="$(profile_root)"
  sha256sum "$root/profiles/operator-services/$GDC_OPERATOR_SERVICES_PROFILE.lock" \
    | awk '{print $1}' | sha256sum | awk '{print $1}'
}
