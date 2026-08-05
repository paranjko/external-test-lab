#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -ge 1 && $# -le 2 && $EUID -eq 0 ]] || { echo "Usage: sudo $0 rendered-agent.env [--gpu]" >&2; exit 2; }
ENV_FILE="$1"; GPU=false; [[ "${2:-}" == --gpu ]] && GPU=true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; DEST=/srv/dai/monitoring-agent
mkdir -p "$DEST" /var/lib/node_exporter/textfile_collector
install -m 0644 "$HERE/compose.yaml" "$DEST/compose.yaml"; install -m 0600 "$ENV_FILE" "$DEST/.env"
if [[ "$GPU" == true ]]; then "$HERE/install-nvidia-metrics.sh"; fi
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST"
printf 'READY installed monitoring agent in %s\n' "$DEST"
