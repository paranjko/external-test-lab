#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: sudo $0 --component gateway|monitoring|site|faucet --render-dir DIR [--gateway-env FILE] [--faucet-env FILE]" >&2; }
RENDER=""; GATEWAY=""; FAUCET=""; COMPONENT=""
while (($#)); do case "$1" in --component) COMPONENT="$2";shift 2;;--render-dir) RENDER="$2";shift 2;;--gateway-env) GATEWAY="$2";shift 2;;--faucet-env) FAUCET="$2";shift 2;;*)usage;exit 2;;esac;done
[[ $EUID -eq 0 && -s "$RENDER/.env" ]] || { usage; exit 2; }
case "$COMPONENT" in
  gateway) [[ -s "$GATEWAY" ]] || { usage; exit 2; } ;;
  faucet) [[ -s "$FAUCET" ]] || { usage; exit 2; } ;;
  monitoring) [[ -s "$RENDER/prometheus.yml" ]] || { usage; exit 2; } ;;
  site) [[ -s "$RENDER/config.js" ]] || { usage; exit 2; } ;;
  *) usage; exit 2 ;;
esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; DEST=/srv/dai/ops
service_user="${SUDO_USER:-root}"
service_group="$(id -gn "$service_user")"
mkdir -p "$DEST"; cp -a "$HERE"/. "$DEST"/
mkdir -p "$DEST/status"
install -m 0600 "$RENDER/.env" "$DEST/.env"
if [[ "$COMPONENT" == gateway ]]; then
  install -m 0600 "$GATEWAY" "$DEST/gateway.env"
elif [[ ! -e "$DEST/gateway.env" ]]; then
  install -m 0600 /dev/null "$DEST/gateway.env"
fi
if [[ "$COMPONENT" == faucet ]]; then
  install -m 0600 "$FAUCET" "$DEST/faucet.env"
elif [[ ! -e "$DEST/faucet.env" ]]; then
  install -m 0600 /dev/null "$DEST/faucet.env"
fi
if [[ -s "$RENDER/prometheus.yml" ]]; then
  # Every OPS component uses the same rendered bundle. Keep the Prometheus
  # bind source valid even when SITE is deployed before MONITORING; otherwise
  # Docker creates a directory at this path and a later Prometheus restart
  # fails with "not a directory".
  [[ ! -d "$DEST/prometheus/prometheus.yml" ]] || rm -rf "$DEST/prometheus/prometheus.yml"
  install -m 0644 "$RENDER/prometheus.yml" "$DEST/prometheus/prometheus.yml"
fi
[[ -s "$RENDER/Caddyfile" ]] && install -m 0644 "$RENDER/Caddyfile" "$DEST/Caddyfile"
if [[ -d "$RENDER/join-bootstrap" ]]; then
  rm -rf "$DEST/join-bootstrap"
  install -d -m 0755 "$DEST/join-bootstrap"
  cp -a "$RENDER/join-bootstrap/." "$DEST/join-bootstrap/"
fi
# Copy the rendered public configuration on every component install.  The
# source tree contains only a safe placeholder; installing gateway or
# monitoring used to overwrite an already-rendered site config and leave the
# public Grafana link as '#'.
[[ -s "$RENDER/config.js" ]] && install -m 0644 "$RENDER/config.js" "$DEST/site/config.js"
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST"
install -m 0755 "$HERE/gateway-health-probe.sh" "$DEST/gateway-health-probe.sh"
sed -e "s/@GDC_SERVICE_USER@/$service_user/g" -e "s/@GDC_SERVICE_GROUP@/$service_group/g" \
  "$HERE/gdc-gateway-health-probe.service" \
  | install -m 0644 /dev/stdin /etc/systemd/system/gdc-gateway-health-probe.service
install -m 0644 "$HERE/gdc-gateway-health-probe.timer" /etc/systemd/system/gdc-gateway-health-probe.timer
install -m 0755 "$HERE/gateway-escrow-reconciler.sh" "$DEST/gateway-escrow-reconciler.sh"
sed -e "s/@GDC_SERVICE_USER@/$service_user/g" -e "s/@GDC_SERVICE_GROUP@/$service_group/g" \
  "$HERE/gdc-gateway-escrow-reconciler.service" \
  | install -m 0644 /dev/stdin /etc/systemd/system/gdc-gateway-escrow-reconciler.service
install -m 0644 "$HERE/gdc-gateway-escrow-reconciler.timer" /etc/systemd/system/gdc-gateway-escrow-reconciler.timer
systemctl daemon-reload
systemctl enable --now gdc-gateway-health-probe.timer >/dev/null
systemctl enable --now gdc-gateway-escrow-reconciler.timer >/dev/null
systemctl start gdc-gateway-health-probe.service || true
systemctl start gdc-gateway-escrow-reconciler.service || true
printf 'READY installed %s operations component in %s\n' "$COMPONENT" "$DEST"
