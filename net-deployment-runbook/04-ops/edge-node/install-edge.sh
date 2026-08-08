#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 && $EUID -eq 0 ]] || { echo "Usage: sudo $0 rendered-node.env" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; DEST=/srv/dai/edge
set -a
# shellcheck disable=SC1090
source "$1"
set +a
[[ "${PUBLIC_GRAFANA_PROMETHEUS_URL:-}" =~ ^http://[A-Za-z0-9.-]+:9099$ ]] || {
  echo 'PUBLIC_GRAFANA_PROMETHEUS_URL must be an HTTP host on port 9099' >&2
  exit 2
}
mkdir -p "$DEST"; install -m 0644 "$HERE/compose.yaml" "$DEST/compose.yaml"; install -m 0600 "$1" "$DEST/.env"
rm -rf "$DEST/public-grafana"
cp -a "$HERE/public-grafana" "$DEST/public-grafana"
sed "s|__PUBLIC_GRAFANA_PROMETHEUS_URL__|$PUBLIC_GRAFANA_PROMETHEUS_URL|g" \
  "$HERE/public-grafana/provisioning/datasources/prometheus.yml" \
  >"$DEST/public-grafana/provisioning/datasources/prometheus.yml"
chmod -R a+rX "$DEST/public-grafana"
# Only the configured public edge owns the three public origins. All other participants retain a
# narrowly-scoped per-node edge proxy and never contend for their certificates.
if grep -qx 'PUBLIC_EDGE=true' "$1"; then
  install -m 0644 "$HERE/PublicCaddyfile" "$DEST/Caddyfile"
else
  install -m 0644 "$HERE/Caddyfile" "$DEST/Caddyfile"
fi
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST"
printf 'READY installed edge proxy in %s\n' "$DEST"
