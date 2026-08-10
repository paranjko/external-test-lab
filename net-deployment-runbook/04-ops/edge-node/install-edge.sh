#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 && $EUID -eq 0 ]] || { echo "Usage: sudo $0 rendered-node.env" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; DEST=/srv/dai/edge
set -a
# shellcheck disable=SC1090
source "$1"
set +a
[[ "${PUBLIC_GRAFANA_PROMETHEUS_URL:-}" =~ ^https://[A-Za-z0-9.-]+/ops-prometheus$ ]] || {
  echo 'PUBLIC_GRAFANA_PROMETHEUS_URL must be the edge-restricted HTTPS Prometheus route' >&2
  exit 2
}

# A JOIN operator can have an older public bootstrap in which this Host is not
# marked as the OPS public edge. Never let that participant-local input
# downgrade an already installed public edge and take the site, API, Grafana,
# and their TLS certificates offline. OPS remains the owner of that config.
if [[ -f "$DEST/.env" ]] && grep -qx 'PUBLIC_EDGE=true' "$DEST/.env" && ! grep -qx 'PUBLIC_EDGE=true' "$1"; then
  printf 'READY preserved existing OPS public edge in %s\n' "$DEST"
  exit 0
fi
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
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST"
printf 'READY installed edge proxy in %s\n' "$DEST"
