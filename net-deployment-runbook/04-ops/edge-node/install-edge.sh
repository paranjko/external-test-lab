#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 && $EUID -eq 0 ]] || { echo "Usage: sudo $0 rendered-node.env" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; DEST=/srv/dai/edge
set -a
# shellcheck disable=SC1090
source "$1"
set +a
expected_remote_prometheus="https://${GATEWAY_PUBLIC_HOST:-}/ops-prometheus"
[[ "${PUBLIC_GRAFANA_PROMETHEUS_URL:-}" == http://127.0.0.1:9099 || "${PUBLIC_GRAFANA_PROMETHEUS_URL:-}" == "$expected_remote_prometheus" ]] || {
  echo 'PUBLIC_GRAFANA_PROMETHEUS_URL must use the configured gateway Prometheus route' >&2
  exit 2
}

mkdir -p "$DEST"
install -m 0644 "$HERE/compose.yaml" "$DEST/compose.yaml"
install -m 0644 "$HERE/bootstrap-nginx.conf" "$DEST/bootstrap-nginx.conf"
# A failed first deployment can leave this exact bind-mount target as a
# directory. Remove only that known invalid target before installing the file.
if [[ -d "$DEST/gateway-admission-proxy.py" ]]; then
  rm -rf "$DEST/gateway-admission-proxy.py"
fi
install -m 0644 "$HERE/gateway-admission-proxy.py" "$DEST/gateway-admission-proxy.py"
install -d -m 0750 "$DEST/status"
install -m 0600 "$1" "$DEST/.env"
"$HERE/reconcile-join-bootstrap.sh" "$HERE/join-bootstrap" "$DEST/join-bootstrap"
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
