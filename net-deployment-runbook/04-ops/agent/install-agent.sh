#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -ge 2 && $# -le 3 && $EUID -eq 0 ]] || { echo "Usage: sudo $0 SSH_ALIAS rendered-agent.env [--gpu]" >&2; exit 2; }
NODE="$1"; ENV_FILE="$2"; GPU=false; [[ "${3:-}" == --gpu ]] && GPU=true
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'invalid monitoring SSH alias' >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; DEST="/srv/dai/deploy/$NODE/monitoring-agent"
mkdir -p "$DEST" /var/lib/node_exporter/textfile_collector
install -m 0644 "$HERE/compose.yaml" "$DEST/compose.yaml"; install -m 0600 "$ENV_FILE" "$DEST/.env"
install -d -m 0755 /usr/local/libexec
install -m 0755 "$HERE/collect-versions.sh" /usr/local/libexec/gdc-collect-versions
install -m 0644 "$HERE/gdc-version-collector.service" "/etc/systemd/system/gdc-version-collector@$NODE.service"
install -m 0644 "$HERE/gdc-version-collector.timer" "/etc/systemd/system/gdc-version-collector@$NODE.timer"
if [[ "$GPU" == true ]]; then "$HERE/install-nvidia-metrics.sh"; fi
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST"
systemctl daemon-reload
systemctl enable --now "gdc-version-collector@$NODE.timer"
systemctl start "gdc-version-collector@$NODE.service"
printf 'READY installed monitoring agent in %s\n' "$DEST"
