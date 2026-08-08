#!/usr/bin/env bash
# Upstream network release, lab deployment, model and operator-service
# profiles are separate inputs. Operator observability changes must not alter
# the identity of the Gonka release under test.

profile_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

load_profiles() {
  local root release deployment model operator
  root="$(profile_root)"
  release="${GDC_RELEASE_PROFILE:-testnet-0.2.14}"
  deployment="${GDC_DEPLOYMENT_PROFILE:-community-lab}"
  model="${GDC_MODEL_PROFILE:-qwen3-0.6b}"
  operator="${GDC_OPERATOR_SERVICES_PROFILE:-gdc-lab}"
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
  # shellcheck disable=SC1090
  source "$root/profiles/releases/$release.lock"
  # shellcheck disable=SC1090
  source "$root/profiles/deployments/$deployment.lock"
  # shellcheck disable=SC1090
  source "$root/profiles/models/$model.lock"
  # shellcheck disable=SC1090
  source "$root/profiles/operator-services/$operator.lock"
  if [[ -n "${GDC_RESOLVED_IMAGE_LOCK:-}" ]]; then
    [[ -r "$GDC_RESOLVED_IMAGE_LOCK" ]] || { echo "resolved image lock is unreadable: $GDC_RESOLVED_IMAGE_LOCK" >&2; return 2; }
    # shellcheck disable=SC1090
    source "$GDC_RESOLVED_IMAGE_LOCK"
  fi
  # The operator CLI uses the exact inferenced release image. It consumes the
  # network profile and is not a separately versioned release input.
  GDC_INFERENCED_TOOL_IMAGE="$INFERENCED_IMAGE"
  export GDC_RELEASE_PROFILE="$release" GDC_DEPLOYMENT_PROFILE="$deployment"
  export GDC_MODEL_PROFILE="$model" GDC_OPERATOR_SERVICES_PROFILE="$operator"
  export GONKA_REPOSITORY GONKA_SOURCE_REF GONKA_COMMIT MODEL_ID MODEL_REVISION
  export GDC_INFERENCED_TOOL_IMAGE
}

profile_summary() {
  printf 'release_profile=%s\ndeployment_profile=%s\nmodel_profile=%s\noperator_services_profile=%s\n' \
    "$GDC_RELEASE_PROFILE" "$GDC_DEPLOYMENT_PROFILE" "$GDC_MODEL_PROFILE" "$GDC_OPERATOR_SERVICES_PROFILE"
  printf 'gonka_source_ref=%s\ngonka_commit=%s\nmodel=%s@%s\n' \
    "$GONKA_SOURCE_REF" "$GONKA_COMMIT" "$MODEL_ID" "$MODEL_REVISION"
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
  sha256sum "$root/profiles/releases/$GDC_RELEASE_PROFILE.lock" \
    "$root/profiles/deployments/$GDC_DEPLOYMENT_PROFILE.lock" \
    "$root/profiles/models/$GDC_MODEL_PROFILE.lock" | sha256sum | awk '{print $1}'
}

operator_profile_hash() {
  local root
  root="$(profile_root)"
  sha256sum "$root/profiles/operator-services/$GDC_OPERATOR_SERVICES_PROFILE.lock" \
    | sha256sum | awk '{print $1}'
}
