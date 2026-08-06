#!/usr/bin/env bash
# Release and model profiles are deliberately separate inputs.  A Compose
# release must never quietly select a different model configuration.

profile_root() { cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd; }

load_profiles() {
  local root release model
  root="$(profile_root)"
  release="${GDC_RELEASE_PROFILE:-testnet-0.2.14}"
  model="${GDC_MODEL_PROFILE:-qwen3-0.6b}"
  [[ "$release" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "invalid release profile: $release" >&2; return 2; }
  [[ "$model" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "invalid model profile: $model" >&2; return 2; }
  [[ -r "$root/profiles/releases/$release.lock" ]] || { echo "unknown release profile: $release" >&2; return 2; }
  [[ -r "$root/profiles/models/$model.lock" ]] || { echo "unknown model profile: $model" >&2; return 2; }
  # shellcheck disable=SC1090
  source "$root/profiles/releases/$release.lock"
  # shellcheck disable=SC1090
  source "$root/profiles/models/$model.lock"
  if [[ -n "${GDC_RESOLVED_IMAGE_LOCK:-}" ]]; then
    [[ -r "$GDC_RESOLVED_IMAGE_LOCK" ]] || { echo "resolved image lock is unreadable: $GDC_RESOLVED_IMAGE_LOCK" >&2; return 2; }
    # shellcheck disable=SC1090
    source "$GDC_RESOLVED_IMAGE_LOCK"
  fi
  export GDC_RELEASE_PROFILE="$release" GDC_MODEL_PROFILE="$model"
  export GONKA_COMMIT MODEL_ID MODEL_REVISION
}

profile_summary() {
  printf 'release_profile=%s\nmodel_profile=%s\ngonka_commit=%s\nmodel=%s@%s\n' \
    "$GDC_RELEASE_PROFILE" "$GDC_MODEL_PROFILE" "$GONKA_COMMIT" "$MODEL_ID" "$MODEL_REVISION"
  printf 'tmkms_image=%s\ninferenced_image=%s\ndapi_image=%s\nedge_api_image=%s\n' \
    "$TMKMS_IMAGE" "$INFERENCED_IMAGE" "$DAPI_IMAGE" "$EDGE_API_IMAGE"
  printf 'versiond_image=%s\nproxy_image=%s\npostgres_image=%s\n' \
    "$VERSIOND_IMAGE" "$PROXY_IMAGE" "$POSTGRES_IMAGE"
  printf 'mlnode_generic_image=%s\nmlnode_blackwell_image=%s\nmlnode_proxy_image=%s\n' \
    "$MLNODE_GENERIC_IMAGE" "$MLNODE_BLACKWELL_IMAGE" "$MLNODE_PROXY_IMAGE"
  printf 'explorer_image=%s\ncaddy_image=%s\nprometheus_image=%s\ngrafana_image=%s\n' \
    "$EXPLORER_IMAGE" "$CADDY_IMAGE" "$PROMETHEUS_IMAGE" "$GRAFANA_IMAGE"
  printf 'alertmanager_image=%s\nblackbox_image=%s\nnode_exporter_image=%s\ncadvisor_image=%s\nbridge_image=%s\n' \
    "$ALERTMANAGER_IMAGE" "$BLACKBOX_IMAGE" "$NODE_EXPORTER_IMAGE" "$CADVISOR_IMAGE" "$BRIDGE_IMAGE"
}

profile_hash() {
  local root
  root="$(profile_root)"
  sha256sum "$root/profiles/releases/$GDC_RELEASE_PROFILE.lock" \
    "$root/profiles/models/$GDC_MODEL_PROFILE.lock" | sha256sum | awk '{print $1}'
}
