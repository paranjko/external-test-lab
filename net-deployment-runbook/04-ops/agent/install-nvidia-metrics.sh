#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -d -m 0755 /var/lib/node_exporter/textfile_collector
install -m 0755 "$HERE/nvidia-prometheus.sh" /usr/local/sbin/gdc-nvidia-prometheus
cat >/etc/systemd/system/gdc-nvidia-prometheus.service <<'EOF'
[Unit]
Description=Export NVIDIA metrics for node_exporter
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gdc-nvidia-prometheus
EOF
cat >/etc/systemd/system/gdc-nvidia-prometheus.timer <<'EOF'
[Unit]
Description=Refresh NVIDIA Prometheus metrics
[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=2s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now gdc-nvidia-prometheus.timer
systemctl start gdc-nvidia-prometheus.service
