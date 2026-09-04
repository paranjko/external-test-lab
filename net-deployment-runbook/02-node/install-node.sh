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
DEST="/srv/dai/deploy/$NODE"
PARENT="$(dirname "$DEST")"
mkdir -p "$PARENT"
STAGE="$(mktemp -d "$PARENT/.${NODE}.gdc-stage.XXXXXX")"
BACKUP="${DEST}.gdc-rollback.$$"
activated=false
backup_made=false
backup_move_started=false
deployment_move_started=false
rollback() {
  local rc="$?"
  trap - ERR INT TERM EXIT
  if [[ "$activated" == true || "$backup_made" == true || "$backup_move_started" == true || "$deployment_move_started" == true ]]; then
    if [[ -e "$BACKUP" ]]; then
      rm -rf "$DEST"
      mv "$BACKUP" "$DEST"
    elif [[ "$deployment_move_started" == true ]]; then
      rm -rf "$DEST"
    fi
  fi
  rm -rf "$STAGE"
  exit "$rc"
}
trap rollback ERR INT TERM EXIT
profile_kind="$(awk -F= '$1 == "GDC_PROFILE_KIND" {print $2}' "$ENV_FILE")"
case "$profile_kind" in
  generated_join)
    new_join_profile="$(awk -F= '$1 == "GDC_JOIN_PROFILE_SHA256" {print $2}' "$ENV_FILE")"
    [[ "$new_join_profile" =~ ^[0-9a-f]{64}$ ]] || { echo 'rendered environment lacks generated JOIN profile identity' >&2; exit 1; }
    if [[ -s "$DEST/.gdc-release" ]]; then
      [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "legacy release deployment exists on $NODE; use the explicit migration path" >&2; exit 1; }
    fi
    if [[ -s "$DEST/.gdc-join-profile" ]] && ! grep -qx "$new_join_profile" "$DEST/.gdc-join-profile"; then
      [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "different generated JOIN profile exists on $NODE; use receipt-bound resume or migration" >&2; exit 1; }
    fi
    ;;
  release)
    new_release="$(awk -F= '$1 == "GDC_RELEASE_PROFILE" {print $2}' "$ENV_FILE")"
    new_hash="$(awk -F= '$1 == "GDC_PROFILE_HASH" {print $2}' "$ENV_FILE")"
    [[ -n "$new_release" && "$new_hash" =~ ^[0-9a-f]{64}$ ]] || { echo 'rendered environment lacks release identity' >&2; exit 1; }
    if [[ -s "$DEST/.gdc-join-profile" ]]; then
      [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "generated JOIN deployment exists on $NODE; use the explicit migration path" >&2; exit 1; }
    fi
    if [[ -s "$DEST/.gdc-release" ]] && ! cmp -s <(printf '%s %s\n' "$new_release" "$new_hash") "$DEST/.gdc-release"; then
      [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "mixed release family on $NODE; use the explicit upgrade phase" >&2; exit 1; }
    fi
    ;;
  *) echo 'rendered environment lacks a known profile kind' >&2; exit 1 ;;
esac
install -m 0644 "$(dirname "$0")/compose.yaml" "$STAGE/compose.yaml"
install -m 0644 "$(dirname "$0")/compose.ml-local.yaml" "$STAGE/compose.ml-local.yaml"
install -m 0644 "$(dirname "$0")/compose.devshard-ha.yaml" "$STAGE/compose.devshard-ha.yaml"
install -m 0644 "$(dirname "$0")/compose.bridge-sepolia.yaml" "$STAGE/compose.bridge-sepolia.yaml"
install -d -m 0755 "$STAGE/versiond-router"
install -m 0644 "$(dirname "$0")/vendor-router/nginx.conf.template" "$STAGE/versiond-router/nginx.conf.template"
install -m 0644 "$(dirname "$0")/nginx-mlnode.conf" "$STAGE/nginx-mlnode.conf"
install -m 0755 "$(dirname "$0")/node-entrypoint.sh" "$STAGE/node-entrypoint.sh"
install -m 0755 "$(dirname "$0")/api-entrypoint.sh" "$STAGE/api-entrypoint.sh"
install -m 0755 "$(dirname "$0")/tmkms-entrypoint.sh" "$STAGE/tmkms-entrypoint.sh"
install -m 0755 "$(dirname "$0")/start-node.sh" "$STAGE/start-node.sh"
install -m 0755 "$(dirname "$0")/ensure-warm-key.sh" "$STAGE/ensure-warm-key.sh"
install -m 0755 "$(dirname "$0")/migrate-v1-validator-identity.sh" "$STAGE/migrate-v1-validator-identity.sh"
install -m 0755 "$(dirname "$0")/verify-canonical-join-state.sh" "$STAGE/verify-canonical-join-state.sh"
install -m 0755 "$(dirname "$0")/verify-active-signer-state.sh" "$STAGE/verify-active-signer-state.sh"
install -m 0755 "$(dirname "$0")/wait-state-sync-canary.sh" "$STAGE/wait-state-sync-canary.sh"
install -m 0755 "$(dirname "$0")/stop-state-sync-canary.sh" "$STAGE/stop-state-sync-canary.sh"
install -m 0755 "$(dirname "$0")/record-state-sync-canary.sh" "$STAGE/record-state-sync-canary.sh"
install -m 0755 "$(dirname "$0")/verify-state-sync-config.sh" "$STAGE/verify-state-sync-config.sh"
install -m 0755 "$(dirname "$0")/fence-existing-signer.sh" "$STAGE/fence-existing-signer.sh"
install -m 0755 "$(dirname "$0")/promote-state-sync-generation.sh" "$STAGE/promote-state-sync-generation.sh"
install -m 0755 "$(dirname "$0")/sync-node-config.sh" "$STAGE/sync-node-config.sh"
if [[ "$LOCAL_ML" == true ]]; then
  install -m 0755 "$(dirname "$0")/poc-winddown-watch.sh" "$STAGE/poc-winddown-watch.sh"
fi
if [[ -f "$(dirname "$0")/../03-join/register-participant.sh" ]]; then
  install -m 0755 "$(dirname "$0")/../03-join/register-participant.sh" "$STAGE/register-participant.sh"
fi
install -m 0600 "$ENV_FILE" "$STAGE/.env"
if [[ "$profile_kind" == generated_join ]]; then
  printf '%s\n' "$new_join_profile" >"$STAGE/.gdc-join-profile"
  chmod 600 "$STAGE/.gdc-join-profile"
else
  printf '%s %s\n' "$new_release" "$new_hash" >"$STAGE/.gdc-release"
  chmod 600 "$STAGE/.gdc-release"
fi
install -m 0644 "$NODE_CONFIG" "$STAGE/node-config.json"
printf '%s\n' "$LOCAL_ML" > "$STAGE/.local-ml"
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$STAGE"
# Validate the complete staged Compose configuration before it can replace the
# runbook-owned deployment directory. Data and TMKMS state live outside this
# directory and are never moved or recreated here.
docker compose --env-file "$STAGE/.env" -f "$STAGE/compose.yaml" config --quiet
[[ ! -e "$BACKUP" ]] || { echo "stale rollback path exists: $BACKUP" >&2; exit 1; }
if [[ -e "$DEST" ]]; then
  backup_move_started=true
  mv "$DEST" "$BACKUP"
fi
if [[ -e "$BACKUP" ]]; then backup_made=true; fi
deployment_move_started=true
mv "$STAGE" "$DEST"
activated=true
install -d -m 0755 /srv/dai/shared
install -m 0444 "$GENESIS" /srv/dai/shared/.genesis.json.gdc-stage
mv -f /srv/dai/shared/.genesis.json.gdc-stage /srv/dai/shared/genesis.json
(cd /srv/dai/shared && sha256sum genesis.json > genesis.sha256)
if [[ "$LOCAL_ML" == true ]]; then
  install -m 0644 "$(dirname "$0")/gdc-poc-winddown-watch@.service" /etc/systemd/system/gdc-poc-winddown-watch@.service
  systemctl daemon-reload
  systemctl enable --now "gdc-poc-winddown-watch@$NODE.service" >/dev/null
fi
rm -rf "$BACKUP"
trap - ERR INT TERM EXIT
printf 'READY installed %s deployment in %s\n' "$NODE" "$DEST"
