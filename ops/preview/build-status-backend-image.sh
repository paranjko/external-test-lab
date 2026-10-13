#!/usr/bin/env bash
set -Eeuo pipefail

# Build an isolated status backend from an exact source checkout. The source-
# bound observer runs with no secrets or direct network route; all external
# requests are forced through the trusted preview egress and node guard.

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
observer="$output/source/net-deployment-runbook/04-ops/network-observer.sh"
observer_http="$output/source/net-deployment-runbook/04-ops/network-observer-http.py"
[[ -f "$observer" && ! -L "$observer" && -f "$observer_http" && ! -L "$observer_http" ]] || die 'exact source snapshot lacks the network observer runtime'
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
[[ -s "$output/rendered/network-observer.env" ]] || die 'status renderer lacks the network observer configuration'
"$compiler" "$output/rendered/Caddyfile" "$output/rendered/config.js" "$preview_number" "$output/context/Caddyfile"
install -m 0644 "$observer_http" "$output/context/network-observer-http.py"
install -m 0644 "$observer" "$output/context/network-observer.sh"
install -m 0644 "$output/rendered/network-observer.env" "$output/context/network-observer.env"
install -m 0755 "$root/ops/preview/network-observer-runtime.py" "$output/context/network-observer-runtime.py"
install -m 0755 "$root/ops/preview/preview-curl.sh" "$output/context/preview-curl.sh"
install -m 0755 "$root/ops/preview/start-status-backend.sh" "$output/context/start-status-backend.sh"
cat >"$output/context/Dockerfile" <<EOF
FROM $caddy_image

# The upstream image grants caddy CAP_NET_BIND_SERVICE. The preview backend
# listens on 8080 and must run with no-new-privileges, so remove that file
# capability during the trusted image build rather than weakening runtime policy.
RUN setcap -r /usr/bin/caddy
RUN apk add --no-cache bash curl jq python3
COPY Caddyfile /etc/caddy/Caddyfile
COPY network-observer-http.py /usr/local/lib/gonka-devnet/network-observer-http.py
COPY network-observer.sh /usr/local/lib/gonka-devnet/network-observer.sh
COPY network-observer-runtime.py /opt/gdc-preview/network-observer-runtime.py
COPY network-observer.env /etc/gonka/gdc-network-observer.env
COPY preview-curl.sh /usr/local/bin/curl
COPY start-status-backend.sh /opt/gdc-preview/start-status-backend.sh
RUN chmod 0755 /usr/local/lib/gonka-devnet/network-observer.sh /usr/local/bin/curl /opt/gdc-preview/start-status-backend.sh
ENV GDC_NETWORK_OBSERVATION_STATE_DIR=/tmp/gonka-network-observer
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["/bin/sh", "-c", "/usr/bin/curl -fsS http://127.0.0.1:8080/health | grep -Fxq ready"]
CMD ["/opt/gdc-preview/start-status-backend.sh"]
EOF
docker build --pull=false --label "gdc.preview.source-revision=$revision" --label gdc.preview.managed=true -t "$image" "$output/context" >/dev/null
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
source_digest="$(git -C "$source_repository" ls-tree -r "$revision" -- net-deployment-runbook/04-ops/render-ops.sh net-deployment-runbook/04-ops/edge-node/PublicCaddyfile net-deployment-runbook/04-ops/network-observer.sh net-deployment-runbook/04-ops/network-observer-http.py | sha256sum | awk '{print $1}')"
inventory_digest="$(sha256sum "$inventory" | awk '{print $1}')"
inventory_receipt_digest=''
if [[ -f "$inventory.receipt.json" && ! -L "$inventory.receipt.json" ]]; then
  inventory_receipt_digest="$(sha256sum "$inventory.receipt.json" | awk '{print $1}')"
fi
render_digest="$(sha256sum "$output/rendered/Caddyfile" | awk '{print $1}')"
backend_digest="$(sha256sum "$output/context/Caddyfile" | awk '{print $1}')"
observer_digest="$(sha256sum "$output/context/network-observer-http.py" | awk '{print $1}')"
collector_digest="$(sha256sum "$output/context/network-observer.sh" | awk '{print $1}')"
observer_env_digest="$(sha256sum "$output/context/network-observer.env" | awk '{print $1}')"
preview_curl_digest="$(sha256sum "$root/ops/preview/preview-curl.sh" | awk '{print $1}')"
observer_runtime_digest="$(sha256sum "$root/ops/preview/network-observer-runtime.py" | awk '{print $1}')"
launcher_digest="$(sha256sum "$root/ops/preview/start-status-backend.sh" | awk '{print $1}')"
jq -n --arg revision "$revision" --argjson preview "$preview_number" --arg source "$source_digest" --arg inventory "$inventory_digest" --arg inventory_receipt "$inventory_receipt_digest" --arg render "$render_digest" --arg backend "$backend_digest" --arg observer "$observer_digest" --arg collector "$collector_digest" --arg observer_env "$observer_env_digest" --arg preview_curl "$preview_curl_digest" --arg observer_runtime "$observer_runtime_digest" --arg launcher "$launcher_digest" --arg image "$image_id" --arg renderer "$renderer_image_id" \
  '{schema_version:1,source_revision:$revision,preview_number:$preview,source_digest:$source,inventory_sha256:$inventory,rendered_caddy_sha256:$render,backend_caddy_sha256:$backend,network_observer_http_sha256:$observer,network_observer_collector_sha256:$collector,network_observer_env_sha256:$observer_env,preview_curl_sha256:$preview_curl,network_observer_runtime_sha256:$observer_runtime,start_status_backend_sha256:$launcher,image_id:$image,status_renderer_image_id:$renderer} + (if $inventory_receipt == "" then {} else {inventory_receipt_sha256:$inventory_receipt} end)' \
  >"$output/backend-build.json"
printf 'PASS built source-bound status backend image=%s\n' "$image"
