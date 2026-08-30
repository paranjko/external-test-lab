#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: sudo $0 --component gateway|monitoring|site|faucet --render-dir DIR [--gateway-env FILE] [--gateway-observer-env FILE] [--faucet-env FILE] [--gateway-reserve-env FILE]" >&2; }
RENDER=""; GATEWAY=""; GATEWAY_OBSERVER=""; FAUCET=""; GATEWAY_RESERVE=""; COMPONENT=""
while (($#)); do case "$1" in --component) COMPONENT="$2";shift 2;;--render-dir) RENDER="$2";shift 2;;--gateway-env) GATEWAY="$2";shift 2;;--gateway-observer-env) GATEWAY_OBSERVER="$2";shift 2;;--faucet-env) FAUCET="$2";shift 2;;--gateway-reserve-env) GATEWAY_RESERVE="$2";shift 2;;*)usage;exit 2;;esac;done
[[ $EUID -eq 0 && -s "$RENDER/.env" ]] || { usage; exit 2; }
case "$COMPONENT" in
  gateway) [[ -s "$GATEWAY" && -s "$GATEWAY_OBSERVER" ]] || { usage; exit 2; } ;;
  faucet) [[ -s "$FAUCET" && -s "$GATEWAY_RESERVE" ]] || { usage; exit 2; } ;;
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
  # Close the old lifecycle controller before replacing its environment. It
  # is restarted only after Compose has recreated the matching gateway.
  systemctl stop gdc-gateway-escrow-reconciler.timer gdc-gateway-escrow-reconciler.service >/dev/null 2>&1 || true
  install -m 0600 "$GATEWAY" "$DEST/gateway.env"
  install -m 0600 "$GATEWAY_OBSERVER" "$DEST/gateway-admission-observer.env"
elif [[ ! -e "$DEST/gateway.env" ]]; then
  install -m 0600 /dev/null "$DEST/gateway.env"
fi
if [[ "$COMPONENT" == faucet ]]; then
  install -m 0600 "$FAUCET" "$DEST/faucet.env"
  install -m 0600 "$GATEWAY_RESERVE" "$DEST/gateway-reserve-signer.env"
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
install -d -m 0755 "$DEST/bootstrap"
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
# OPS deployment files are intentionally writable by the deployment operator.
# The reconciler is executed by systemd, so install its executable under
# root-owned ancestors rather than below /srv/dai/ops.
install -d -o root -g root -m 0755 /usr/local/lib/gonka-devnet
install -o root -g root -m 0755 "$HERE/gateway-reserve-controller.sh" /usr/local/lib/gonka-devnet/gateway-reserve-controller.sh
install -o root -g root -m 0755 "$HERE/gateway-reserve-policy.sh" /usr/local/lib/gonka-devnet/gateway-reserve-policy.sh
install -m 0755 "$HERE/gateway-status-routable.sh" "$DEST/gateway-status-routable.sh"
sed -e "s/@GDC_SERVICE_USER@/$service_user/g" -e "s/@GDC_SERVICE_GROUP@/$service_group/g" \
  "$HERE/gdc-gateway-reserve-controller.service" \
  | install -m 0644 /dev/stdin /etc/systemd/system/gdc-gateway-reserve-controller.service
install -m 0644 "$HERE/gdc-gateway-reserve-controller.timer" /etc/systemd/system/gdc-gateway-reserve-controller.timer
# Upgrade the reconciler executable, unit and environment as one gateway
# operation. An unrelated OPS deployment must not start new lifecycle code
# against a retained gateway.env with an older contract.
if [[ "$COMPONENT" == gateway ]]; then
  install -o root -g root -m 0755 "$HERE/gateway-admission-observer.py" /usr/local/lib/gonka-devnet/gateway-admission-observer.py
  sed -e "s/@GDC_SERVICE_USER@/$service_user/g" -e "s/@GDC_SERVICE_GROUP@/$service_group/g" \
    "$HERE/gdc-gateway-admission-observer.service" \
    | install -m 0644 /dev/stdin /etc/systemd/system/gdc-gateway-admission-observer.service
  install -o root -g root -m 0755 "$HERE/gateway-escrow-reconciler.sh" /usr/local/lib/gonka-devnet/gateway-escrow-reconciler.sh
  sed -e "s/@GDC_SERVICE_USER@/$service_user/g" -e "s/@GDC_SERVICE_GROUP@/$service_group/g" \
    "$HERE/gdc-gateway-escrow-reconciler.service" \
    | install -m 0644 /dev/stdin /etc/systemd/system/gdc-gateway-escrow-reconciler.service
  install -m 0644 "$HERE/gdc-gateway-escrow-reconciler.timer" /etc/systemd/system/gdc-gateway-escrow-reconciler.timer
fi
systemctl daemon-reload
systemctl enable --now gdc-gateway-health-probe.timer >/dev/null
systemctl enable --now gdc-gateway-reserve-controller.timer >/dev/null
systemctl start gdc-gateway-reserve-controller.service || true
systemctl start gdc-gateway-health-probe.service || true
printf 'READY installed %s operations component in %s\n' "$COMPONENT" "$DEST"
