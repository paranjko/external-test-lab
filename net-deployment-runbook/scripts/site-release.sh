#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
site_release_dir="${2:-}"
site_publish_prefix="${3:-}"
deploy_host="${4:-}"
deploy_user="${5:-}"

[[ "$deploy_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'set a valid deploy_host' >&2; exit 2; }
[[ "$deploy_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo 'set a valid deploy_user' >&2; exit 2; }

if [[ -z "$site_publish_prefix" ]]; then
  destination=/srv/dai/edge/site
elif [[ "$site_publish_prefix" =~ ^preview/[1-9][0-9]*$ ]]; then
  destination="/srv/dai/edge/site/$site_publish_prefix"
else
  echo 'site_publish_prefix must be empty or preview/<positive-PR-number>' >&2
  exit 2
fi

if [[ -n "${DEPLOY_KNOWN_HOSTS:-}" || -n "${DEPLOY_PRIVATE_KEY:-}" ]]; then
  [[ -n "${DEPLOY_KNOWN_HOSTS:-}" && -n "${DEPLOY_PRIVATE_KEY:-}" ]] || {
    echo 'set both DEPLOY_KNOWN_HOSTS and DEPLOY_PRIVATE_KEY' >&2
    exit 2
  }
  install -d -m 0700 "$HOME/.ssh"
  printf '%s\n' "$DEPLOY_KNOWN_HOSTS" >"$HOME/.ssh/known_hosts"
  printf '%s\n' "$DEPLOY_PRIVATE_KEY" >"$HOME/.ssh/id_ed25519"
  chmod 0600 "$HOME/.ssh/id_ed25519" "$HOME/.ssh/known_hosts"
fi

remote="$deploy_user@$deploy_host"
case "$action" in
  publish)
    [[ -d "$site_release_dir" ]] || { echo 'run prepare-static-site first' >&2; exit 2; }
    ssh -o BatchMode=yes "$remote" "install -d -m 0755 $destination"
    rsync -a --delete --exclude config.js --exclude preview/ -e 'ssh -o BatchMode=yes' \
      "$site_release_dir/" "$remote:$destination/"
    ssh -o BatchMode=yes "$remote" \
      'cd /srv/dai/edge && sudo /usr/bin/docker compose up -d --force-recreate caddy'
    ;;
  remove)
    [[ "$site_publish_prefix" =~ ^preview/[1-9][0-9]*$ ]] || {
      echo 'site_publish_prefix must be preview/<positive-PR-number> for removal' >&2
      exit 2
    }
    ssh -o BatchMode=yes "$remote" "rm -rf -- $destination"
    ;;
  *) echo 'usage: site-release.sh publish|remove SITE_RELEASE_DIR SITE_PUBLISH_PREFIX DEPLOY_HOST DEPLOY_USER' >&2; exit 2 ;;
esac
