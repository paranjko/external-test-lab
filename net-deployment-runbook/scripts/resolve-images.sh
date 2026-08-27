#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/profile.sh"
load_profiles
OUT="${1:-$STATE/resolved-images/$GDC_RELEASE_PROFILE+$GDC_DEPLOYMENT_PROFILE+$GDC_OPERATOR_SERVICES_PROFILE.lock}"
mkdir -p "$(dirname "$OUT")"

network_image_vars=(
  TMKMS_IMAGE INFERENCED_IMAGE DAPI_IMAGE VERSIOND_IMAGE PROXY_IMAGE
  POSTGRES_IMAGE MLNODE_GENERIC_IMAGE MLNODE_PROXY_IMAGE
  BRIDGE_IMAGE
)
operator_image_vars=(
  EXPLORER_IMAGE CADDY_IMAGE PROMETHEUS_IMAGE GRAFANA_IMAGE ALERTMANAGER_IMAGE BLACKBOX_IMAGE
  NODE_EXPORTER_IMAGE CADVISOR_IMAGE
)
[[ "$EDGE_API_ENABLED" =~ ^(true|false)$ ]] || { echo 'EDGE_API_ENABLED must be true or false' >&2; exit 2; }
[[ "$EDGE_API_ENABLED" != true ]] || network_image_vars+=(EDGE_API_IMAGE)
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
resolve_group() {
  local heading="$1" var image resolved manifest digest
  shift
  printf '# %s\n' "$heading" >>"$tmp"
  for var in "$@"; do
    image="${!var}"
    if [[ "$image" == *@sha256:* ]]; then
      resolved="$image"
    else
      if ! manifest="$(docker buildx imagetools inspect "$image" 2>&1)"; then
        printf 'cannot resolve immutable OCI manifest for %s:\n%s\n' "$image" "$manifest" >&2
        exit 1
      fi
      digest="$(awk '$1 == "Digest:" {print $2; exit}' <<<"$manifest")"
      [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        printf 'OCI inspection did not provide a manifest digest for %s:\n%s\n' "$image" "$manifest" >&2
        exit 1
      }
      resolved="$image@$digest"
    fi
    printf '%s=%q\n' "$var" "$resolved" >>"$tmp"
  done
}
resolve_group 'Network and deployment images' "${network_image_vars[@]}"
printf '\n' >>"$tmp"
resolve_group 'Operator-owned support images' "${operator_image_vars[@]}"
install -m 0600 "$tmp" "$OUT"
printf '%s\n' "$OUT"
