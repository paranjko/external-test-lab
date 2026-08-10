#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${GONKA_UPSTREAM_WORKTREE:-$ROOT/../../gonka}"
source "$ROOT/scripts/profile.sh"
VERIFY_REGISTRY=false
if [[ "${1:-}" == --registry ]]; then
  VERIFY_REGISTRY=true
  shift
fi
[[ $# -eq 0 ]] || { echo 'Usage: verify-release-profiles.sh [--registry]' >&2; exit 2; }

[[ -d "$UPSTREAM/.git" || -f "$UPSTREAM/.git" ]] || {
  echo "Gonka upstream worktree is missing: $UPSTREAM" >&2
  exit 2
}

without_digest() {
  printf '%s\n' "${1%@sha256:*}"
}

normalize_image() {
  local image tail
  image="$(without_digest "$1")"
  tail="${image##*/}"
  [[ "$tail" == *:* ]] || image="$image:latest"
  printf '%s\n' "$image"
}

upstream_service_image() {
  local ref="$1" file="$2" service="$3"
  git -C "$UPSTREAM" show "$ref:$file" | awk -v service="$service" '
    $0 == "  " service ":" { in_service=1; next }
    in_service && $0 ~ /^    image:/ { gsub(/"/, "", $2); print $2; exit }
    in_service && $0 ~ /^  [^ ]+:/ { exit }
  '
}

assert_service_image() {
  local ref="$1" file="$2" service="$3" variable="$4"
  local expected actual
  expected="$(normalize_image "$(upstream_service_image "$ref" "$file" "$service")")"
  actual="$(normalize_image "${!variable}")"
  [[ -n "$expected" ]] || {
    echo "$ref does not define $service in $file" >&2
    exit 1
  }
  [[ "$actual" == "$expected" ]] || {
    printf '%s: %s mismatch: profile=%s upstream=%s\n' "$ref" "$variable" "$actual" "$expected" >&2
    exit 1
  }
}

assert_registry_digest() {
  local variable="$1" pinned tag expected actual manifest
  pinned="${!variable}"
  [[ "$pinned" == *@sha256:* ]] || {
    echo "$variable is not pinned by digest: $pinned" >&2
    exit 1
  }
  tag="${pinned%@sha256:*}"
  expected="sha256:${pinned##*@sha256:}"
  manifest="$(docker buildx imagetools inspect "$tag")"
  actual="$(awk '$1 == "Digest:" {print $2; exit}' <<<"$manifest")"
  [[ "$actual" == "$expected" ]] || {
    printf '%s registry mismatch: profile=%s registry=%s\n' "$variable" "$expected" "$actual" >&2
    exit 1
  }
}

for item in \
  'v2026.07.23|release/v0.2.14' \
  'v2026.08.06|release/v0.2.15'
do
  IFS='|' read -r profile ref <<<"$item"
  GDC_RELEASE_PROFILE="$profile" load_profiles
  stack_ref="$ref"

  [[ "$GONKA_SOURCE_REF" == "$ref" ]] || {
    echo "$profile source ref is $GONKA_SOURCE_REF, expected $ref" >&2
    exit 1
  }
  upstream_commit="$(git -C "$UPSTREAM" rev-parse "$ref^{commit}")"
  [[ "$GONKA_COMMIT" == "$upstream_commit" ]] || {
    echo "$profile commit $GONKA_COMMIT does not match $ref commit $upstream_commit" >&2
    exit 1
  }

  if [[ -n "${GONKA_HOST_STACK_COMMIT:-}" ]]; then
    [[ "$GONKA_HOST_STACK_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
      || { echo "$profile has an invalid host-stack commit" >&2; exit 1; }
    git -C "$UPSTREAM" cat-file -e "$GONKA_HOST_STACK_COMMIT^{commit}" \
      || { echo "$profile host-stack commit is unavailable: $GONKA_HOST_STACK_COMMIT" >&2; exit 1; }
    actual_doc_sha256="$(git -C "$UPSTREAM" show "$GONKA_HOST_STACK_COMMIT:docs/host-stack-latest.md" | sha256sum | awk '{print $1}')"
    actual_compose_sha256="$(git -C "$UPSTREAM" show "$GONKA_HOST_STACK_COMMIT:deploy/join/docker-compose.yml" | sha256sum | awk '{print $1}')"
    [[ "$actual_doc_sha256" == "$GONKA_HOST_STACK_DOC_SHA256" ]] \
      || { echo "$profile host-stack document hash mismatch" >&2; exit 1; }
    [[ "$actual_compose_sha256" == "$GONKA_HOST_STACK_COMPOSE_SHA256" ]] \
      || { echo "$profile host-stack Compose hash mismatch" >&2; exit 1; }
    dapi_commit="$(git -C "$UPSTREAM" rev-parse "$DAPI_SOURCE_REF^{commit}")"
    [[ "$dapi_commit" == "$DAPI_COMMIT" ]] \
      || { echo "$profile DAPI commit $DAPI_COMMIT does not match $DAPI_SOURCE_REF commit $dapi_commit" >&2; exit 1; }
    stack_ref="$GONKA_HOST_STACK_COMMIT"
  fi

  compose=deploy/join/docker-compose.yml
  assert_service_image "$stack_ref" "$compose" tmkms TMKMS_IMAGE
  assert_service_image "$stack_ref" "$compose" node INFERENCED_IMAGE
  assert_service_image "$stack_ref" "$compose" api DAPI_IMAGE
  assert_service_image "$stack_ref" "$compose" versiond VERSIOND_IMAGE
  assert_service_image "$stack_ref" "$compose" proxy PROXY_IMAGE
  assert_service_image "$stack_ref" "$compose" explorer EXPLORER_IMAGE
  assert_service_image "$stack_ref" "$compose" bridge BRIDGE_IMAGE
  if [[ "$EDGE_API_ENABLED" == true ]]; then
    assert_service_image "$stack_ref" "$compose" edge-api EDGE_API_IMAGE
  else
    [[ -z "$(upstream_service_image "$stack_ref" "$compose" edge-api)" ]] || {
      echo "$ref contains edge-api but $profile disables it" >&2
      exit 1
    }
  fi

  ml_compose=deploy/join/docker-compose.mlnode.yml
  assert_service_image "$stack_ref" "$ml_compose" mlnode-308 MLNODE_GENERIC_IMAGE
  assert_service_image "$stack_ref" "$ml_compose" inference MLNODE_PROXY_IMAGE
  if [[ "$VERIFY_REGISTRY" == true ]]; then
    registry_vars=(TMKMS_IMAGE INFERENCED_IMAGE DAPI_IMAGE VERSIOND_IMAGE PROXY_IMAGE BRIDGE_IMAGE MLNODE_GENERIC_IMAGE MLNODE_PROXY_IMAGE)
    [[ "$EDGE_API_ENABLED" != true ]] || registry_vars+=(EDGE_API_IMAGE)
    for variable in "${registry_vars[@]}"; do
      assert_registry_digest "$variable"
    done
  fi
  if [[ -n "${GONKA_HOST_STACK_COMMIT:-}" ]]; then
    printf 'PASS %s core=%s (%s) host-stack=%s dapi=%s (%s)\n' \
      "$profile" "$ref" "$GONKA_COMMIT" "$GONKA_HOST_STACK_COMMIT" "$DAPI_SOURCE_REF" "$DAPI_COMMIT"
  else
    printf 'PASS %s matches %s (%s)\n' "$profile" "$ref" "$GONKA_COMMIT"
  fi
done

operator_vars='EXPLORER_IMAGE DASHBOARD_PORT CADDY_IMAGE PROMETHEUS_IMAGE GRAFANA_IMAGE ALERTMANAGER_IMAGE BLACKBOX_IMAGE NODE_EXPORTER_IMAGE CADVISOR_IMAGE'
for lock in "$ROOT"/profiles/releases/*.lock; do
  for variable in $operator_vars; do
    if grep -q "^$variable=" "$lock"; then
      echo "operator service $variable must not be in release profile $lock" >&2
      exit 1
    fi
  done
done

for variable in TMKMS_IMAGE INFERENCED_IMAGE DAPI_IMAGE EDGE_API_IMAGE VERSIOND_IMAGE PROXY_IMAGE MLNODE_GENERIC_IMAGE BRIDGE_IMAGE; do
  if grep -q "^$variable=" "$ROOT/profiles/operator-services/gdc-lab.lock"; then
    echo "network release input $variable must not be in operator-services profile" >&2
    exit 1
  fi
done

printf 'PASS release and operator-service profile boundary\n'
