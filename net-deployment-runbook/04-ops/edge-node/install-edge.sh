#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 || ( $# -eq 3 && "${2:-}" == --node-name ) ]] && [[ $EUID -eq 0 ]] || { echo "Usage: sudo $0 rendered-node.env [--node-name SSH_ALIAS]" >&2; exit 2; }
ENV_FILE="$1"
DEST=/srv/dai/edge
if [[ $# -eq 3 ]]; then
  NODE="$3"
  [[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'invalid edge SSH alias' >&2; exit 2; }
  DEST=/srv/dai/deploy/edge
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
expected_remote_prometheus="https://${GATEWAY_PUBLIC_HOST:-}/ops-prometheus"
[[ "${PUBLIC_GRAFANA_PROMETHEUS_URL:-}" == http://127.0.0.1:9099 || "${PUBLIC_GRAFANA_PROMETHEUS_URL:-}" == "$expected_remote_prometheus" ]] || {
  echo 'PUBLIC_GRAFANA_PROMETHEUS_URL must use the configured gateway Prometheus route' >&2
  exit 2
}

mkdir -p "$DEST"
install -m 0644 "$HERE/compose.yaml" "$DEST/compose.yaml"
install -d -m 0755 "$DEST/bootstrap"
# Compose validates env_file paths even when only Caddy is selected. Seed an
# empty non-contract file once for participant edges; only gateway apply may
# replace it with a routable protocol contract.
if [[ -d "$DEST/gateway-admission.env" ]]; then
  rm -rf "$DEST/gateway-admission.env"
fi
if [[ ! -e "$DEST/gateway-admission.env" ]]; then
  install -m 0600 /dev/null "$DEST/gateway-admission.env"
fi
install -m 0600 "$1" "$DEST/.env"
# A running public Grafana bind-mounts the dashboards and provisioning
# directories. Replacing those directories would leave the container on the
# deleted inodes, serving its last imported definitions while the files on
# disk are already current. Refresh the files inside the existing
# directories instead so the provisioner sees every change.
install -d -m 0755 "$DEST/public-grafana"
find "$DEST/public-grafana" -mindepth 1 ! -type d -delete
cp -a "$HERE/public-grafana/." "$DEST/public-grafana/"
sed "s|__PUBLIC_GRAFANA_PROMETHEUS_URL__|$PUBLIC_GRAFANA_PROMETHEUS_URL|g" \
  "$HERE/public-grafana/provisioning/datasources/prometheus.yml" \
  >"$DEST/public-grafana/provisioning/datasources/prometheus.yml"
chmod -R a+rX "$DEST/public-grafana"
# Only the configured public edge owns the three public origins. All other participants retain a
# narrowly-scoped per-node edge proxy and never contend for their certificates.
if grep -qx 'PUBLIC_EDGE=true' "$1"; then
  caddy_source="$HERE/PublicCaddyfile"
else
  caddy_source="$HERE/Caddyfile"
fi
if [[ -n "${ACME_EMAIL:-}" ]]; then
  install -m 0644 "$caddy_source" "$DEST/Caddyfile"
else
  sed '/^[[:space:]]*email {\$ACME_EMAIL}[[:space:]]*$/d' "$caddy_source" >"$DEST/Caddyfile"
  chmod 0644 "$DEST/Caddyfile"
fi
edge_owner="${SUDO_USER:-root}:${SUDO_USER:-root}"
chown "$edge_owner" "$DEST"
# The site is provisioned by the OPS/site publisher and may include a
# separately-owned preview tree. Preserve those owners while retaining the
# installer ownership for every other edge file.
find "$DEST" -mindepth 1 -maxdepth 1 ! -name site -exec chown -R "$edge_owner" {} +
printf 'READY installed edge proxy in %s\n' "$DEST"
