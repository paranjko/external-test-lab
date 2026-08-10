#!/usr/bin/env bash
set -Eeuo pipefail
NODE=''; ENV_FILE=''
while (($#)); do
  case "$1" in
    --node-name) NODE="${2:-}"; shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    *) echo "Usage: sudo $0 --node-name ML_SSH_ALIAS --env rendered-ml.env" >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 && "$NODE" =~ ^[A-Za-z0-9._-]+$ && -s "$ENV_FILE" ]] || {
  echo "Usage: sudo $0 --node-name ML_SSH_ALIAS --env rendered-ml.env" >&2; exit 2;
}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; DEST="/srv/dai/deploy/$NODE"
mkdir -p "$DEST"; install -m 0644 "$HERE/compose.yaml" "$DEST/compose.yaml"; install -m 0644 "$HERE/../nginx-mlnode.conf" "$DEST/nginx-mlnode.conf"
# Compose refers to ../nginx-mlnode.conf in source layout; normalize the installed copy.
sed -i 's#../nginx-mlnode.conf#./nginx-mlnode.conf#' "$DEST/compose.yaml"
install -m 0600 "$ENV_FILE" "$DEST/.env"; install -m 0755 "$HERE/start-ml.sh" "$DEST/start-ml.sh"
install -m 0755 "$HERE/../poc-winddown-watch.sh" "$DEST/poc-winddown-watch.sh"
install -m 0644 "$HERE/../gdc-poc-winddown-watch@.service" /etc/systemd/system/gdc-poc-winddown-watch@.service
systemctl daemon-reload
systemctl enable --now "gdc-poc-winddown-watch@$NODE.service" >/dev/null
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST"
printf 'READY installed ML-only stack in %s\n' "$DEST"
