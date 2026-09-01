#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: sudo $0 --node-name ssh-alias --env FILE --node-config FILE --genesis FILE [--local-ml] [--allow-release-change]" >&2; }
NODE=""; ENV_FILE=""; NODE_CONFIG=""; GENESIS=""; LOCAL_ML=false; ALLOW_RELEASE_CHANGE=false
while (($#)); do
  case "$1" in
    --node-name) NODE="$2"; shift 2;; --env) ENV_FILE="$2"; shift 2;;
    --node-config) NODE_CONFIG="$2"; shift 2;; --genesis) GENESIS="$2"; shift 2;;
    --local-ml) LOCAL_ML=true; shift;; --allow-release-change) ALLOW_RELEASE_CHANGE=true; shift;; *) usage; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
[[ "$NODE" =~ ^[a-z0-9][a-z0-9_-]*$ && -s "$ENV_FILE" && -s "$NODE_CONFIG" && -s "$GENESIS" ]] || { usage; exit 2; }
DEST="/srv/dai/deploy/$NODE"; mkdir -p "$DEST"
new_release="$(awk -F= '$1 == "GDC_RELEASE_PROFILE" {print $2}' "$ENV_FILE")"
new_hash="$(awk -F= '$1 == "GDC_PROFILE_HASH" {print $2}' "$ENV_FILE")"
[[ -n "$new_release" && "$new_hash" =~ ^[0-9a-f]{64}$ ]] || { echo 'rendered environment lacks release identity' >&2; exit 1; }
if [[ -s "$DEST/.gdc-release" ]] && ! cmp -s <(printf '%s %s\n' "$new_release" "$new_hash") "$DEST/.gdc-release"; then
  [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "mixed release family on $NODE; use the explicit upgrade phase" >&2; exit 1; }
fi
rm -rf "$DEST/node-entrypoint.sh" "$DEST/api-entrypoint.sh"
install -m 0644 "$(dirname "$0")/compose.yaml" "$DEST/compose.yaml"
install -m 0644 "$(dirname "$0")/compose.ml-local.yaml" "$DEST/compose.ml-local.yaml"
install -m 0644 "$(dirname "$0")/compose.devshard-ha.yaml" "$DEST/compose.devshard-ha.yaml"
install -m 0644 "$(dirname "$0")/compose.bridge-sepolia.yaml" "$DEST/compose.bridge-sepolia.yaml"
install -d -m 0755 "$DEST/versiond-router"
install -m 0644 "$(dirname "$0")/vendor-router/nginx.conf.template" "$DEST/versiond-router/nginx.conf.template"
install -m 0644 "$(dirname "$0")/nginx-mlnode.conf" "$DEST/nginx-mlnode.conf"
install -m 0755 "$(dirname "$0")/node-entrypoint.sh" "$DEST/node-entrypoint.sh"
install -m 0755 "$(dirname "$0")/api-entrypoint.sh" "$DEST/api-entrypoint.sh"
install -m 0755 "$(dirname "$0")/tmkms-entrypoint.sh" "$DEST/tmkms-entrypoint.sh"
install -m 0755 "$(dirname "$0")/start-node.sh" "$DEST/start-node.sh"
install -m 0755 "$(dirname "$0")/sync-node-config.sh" "$DEST/sync-node-config.sh"
if [[ "$LOCAL_ML" == true ]]; then
  install -m 0755 "$(dirname "$0")/poc-winddown-watch.sh" "$DEST/poc-winddown-watch.sh"
  install -m 0644 "$(dirname "$0")/gdc-poc-winddown-watch@.service" /etc/systemd/system/gdc-poc-winddown-watch@.service
fi
if [[ -f "$(dirname "$0")/../03-join/register-participant.sh" ]]; then
  install -m 0755 "$(dirname "$0")/../03-join/register-participant.sh" "$DEST/register-participant.sh"
fi
install -m 0600 "$ENV_FILE" "$DEST/.env"
printf '%s %s\n' "$new_release" "$new_hash" >"$DEST/.gdc-release"
chmod 600 "$DEST/.gdc-release"
install -m 0644 "$NODE_CONFIG" "$DEST/node-config.json"
install -d -m 0755 /srv/dai/shared
install -m 0444 "$GENESIS" /srv/dai/shared/genesis.json
(cd /srv/dai/shared && sha256sum genesis.json > genesis.sha256)
printf '%s\n' "$LOCAL_ML" > "$DEST/.local-ml"
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST"
if [[ "$LOCAL_ML" == true ]]; then
  systemctl daemon-reload
  systemctl enable --now "gdc-poc-winddown-watch@$NODE.service" >/dev/null
fi
printf 'READY installed %s deployment in %s\n' "$NODE" "$DEST"
