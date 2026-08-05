#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/profile.sh"
load_profiles
OUT="${1:-$ROOT/state/resolved-images/$GDC_RELEASE_PROFILE.lock}"
mkdir -p "$(dirname "$OUT")"

image_vars=(
  TMKMS_IMAGE INFERENCED_IMAGE DAPI_IMAGE VERSIOND_IMAGE PROXY_IMAGE
  POSTGRES_IMAGE MLNODE_GENERIC_IMAGE MLNODE_BLACKWELL_IMAGE MLNODE_PROXY_IMAGE
  CADDY_IMAGE PROMETHEUS_IMAGE GRAFANA_IMAGE ALERTMANAGER_IMAGE BLACKBOX_IMAGE
  NODE_EXPORTER_IMAGE CADVISOR_IMAGE BRIDGE_IMAGE
)
[[ "$EDGE_API_ENABLED" =~ ^(true|false)$ ]] || { echo 'EDGE_API_ENABLED must be true or false' >&2; exit 2; }
[[ "$EDGE_API_ENABLED" != true ]] || image_vars+=(EDGE_API_IMAGE)
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for var in "${image_vars[@]}"; do
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
install -m 0600 "$tmp" "$OUT"
printf '%s\n' "$OUT"
