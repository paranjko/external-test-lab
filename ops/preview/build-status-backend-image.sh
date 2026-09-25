#!/usr/bin/env bash
set -Eeuo pipefail

# Build a non-programmable status backend from an exact source checkout.  The
# caller supplies a secret-free inventory; the build never reads GDC_HOME.

source_repository="${1:-}"
inventory="${2:-}"
revision="${3:-}"
preview_number="${4:-}"
output="${5:-}"
image="${6:-}"
caddy_image="${PREVIEW_CADDY_IMAGE:-caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648}"
renderer_image="${PREVIEW_STATUS_RENDERER_IMAGE:-gdc-preview-status-renderer:local}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
renderer_dockerfile="$root/ops/preview/Dockerfile.status-renderer"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }
git -C "$source_repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'source repository is not a Git checkout'
[[ -f "$inventory" && ! -L "$inventory" ]] || die 'safe inventory is required'
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'revision must be a full SHA-1'
[[ "$preview_number" =~ ^[1-9][0-9]*$ ]] || die 'preview number must be positive'
[[ "$image" =~ ^[a-z0-9][a-z0-9._/-]*:[a-z0-9][a-z0-9._-]*$ ]] || die 'image reference is invalid'
[[ "$caddy_image" =~ @sha256:[0-9a-f]{64}$ ]] || die 'PREVIEW_CADDY_IMAGE must be digest-pinned'
[[ "$renderer_image" =~ ^[a-z0-9][a-z0-9._/-]*:[a-z0-9][a-z0-9._-]*$ ]] || die 'status renderer image reference is invalid'
[[ "$output" = /* && "$output" != / && "$output" != *..* ]] || die 'output must be an absolute non-root path without ..'
[[ ! -e "$output" ]] || die 'output must not already exist'
compiler="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/render-status-backend.sh"
[[ -x "$compiler" ]] || die 'backend compiler is unavailable'
[[ -f "$renderer_dockerfile" && ! -L "$renderer_dockerfile" ]] || die 'trusted status renderer Dockerfile is unavailable'

install -d -m 0750 "$output/source" "$output/rendered" "$output/context"
git -C "$source_repository" archive --format=tar "$revision" | tar -xf - -C "$output/source"
renderer="$output/source/net-deployment-runbook/04-ops/render-ops.sh"
[[ -x "$renderer" ]] || die 'exact source snapshot lacks the status renderer'
docker build --pull=false -q -t "$renderer_image" -f "$renderer_dockerfile" "$root/ops/preview" >/dev/null
renderer_image_id="$(docker image inspect --format '{{.Id}}' "$renderer_image")"
if ! docker run --rm --network none --read-only --user "$(id -u):$(id -g)" --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 128 --memory 512m --cpus 1 \
  --tmpfs /workspace:rw,exec,nosuid,nodev,size=256m,uid="$(id -u)",gid="$(id -g)" \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m,uid="$(id -u)",gid="$(id -g)" \
  -e HOME=/tmp/home -e PATH=/sandbox-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -v "$output/source:/input:ro" -v "$inventory:/inventory.env:ro" -v "$output/rendered:/output" \
  "$renderer_image" bash -ceu '
    cp -R /input/. /workspace/
    /workspace/net-deployment-runbook/04-ops/render-ops.sh --inventory /inventory.env --output-dir /output
  '; then
  die 'disposable status renderer failed'
fi
"$compiler" "$output/rendered/Caddyfile" "$output/rendered/config.js" "$preview_number" "$output/context/Caddyfile"
cat >"$output/context/Dockerfile" <<EOF
FROM $caddy_image

# The upstream image grants caddy CAP_NET_BIND_SERVICE. The preview backend
# listens on 8080 and must run with no-new-privileges, so remove that file
# capability during the trusted image build rather than weakening runtime policy.
RUN setcap -r /usr/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["caddy", "version"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
EOF
docker build --pull=false --label "gdc.preview.source-revision=$revision" --label gdc.preview.managed=true -t "$image" "$output/context" >/dev/null
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
source_digest="$(git -C "$source_repository" ls-tree -r "$revision" -- net-deployment-runbook/04-ops/render-ops.sh net-deployment-runbook/04-ops/edge-node/PublicCaddyfile | sha256sum | awk '{print $1}')"
inventory_digest="$(sha256sum "$inventory" | awk '{print $1}')"
inventory_receipt_digest=''
if [[ -f "$inventory.receipt.json" && ! -L "$inventory.receipt.json" ]]; then
  inventory_receipt_digest="$(sha256sum "$inventory.receipt.json" | awk '{print $1}')"
fi
render_digest="$(sha256sum "$output/rendered/Caddyfile" | awk '{print $1}')"
backend_digest="$(sha256sum "$output/context/Caddyfile" | awk '{print $1}')"
jq -n --arg revision "$revision" --argjson preview "$preview_number" --arg source "$source_digest" --arg inventory "$inventory_digest" --arg inventory_receipt "$inventory_receipt_digest" --arg render "$render_digest" --arg backend "$backend_digest" --arg image "$image_id" --arg renderer "$renderer_image_id" \
  '{schema_version:1,source_revision:$revision,preview_number:$preview,source_digest:$source,inventory_sha256:$inventory,rendered_caddy_sha256:$render,backend_caddy_sha256:$backend,image_id:$image,status_renderer_image_id:$renderer} + (if $inventory_receipt == "" then {} else {inventory_receipt_sha256:$inventory_receipt} end)' \
  >"$output/backend-build.json"
printf 'PASS built source-bound status backend image=%s\n' "$image"
