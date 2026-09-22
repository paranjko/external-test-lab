#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
site_release_dir="${2:-}"
site_publish_prefix="${3:-}"
deploy_host="${4:-${DEPLOY_HOST:-}}"
deploy_user="${5:-${DEPLOY_USER:-}}"
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
site_origin="${GDC_SITE_ORIGIN:-https://gonka-dev.net}"

# Local preview publication may use an ignored, owner-only environment file.
# CI passes the deploy values explicitly and never relies on this file.
if [[ ( "$action" == publish-preview || "$action" == rollback-preview || "$action" == remove ) && ( -n "${GDC_SITE_PREVIEW_ENV_FILE:-}" || ( -z "${4:-}" && -z "${5:-}" && -z "${DEPLOY_HOST:-}" && -z "${DEPLOY_USER:-}" ) ) ]]; then
    gdc_home="${GDC_HOME:-$HOME/.gdc-data}"
  if [[ -n "${GDC_SITE_PREVIEW_ENV_FILE:-}" ]]; then
    preview_env_file="$GDC_SITE_PREVIEW_ENV_FILE"
  elif [[ -r "$gdc_home/.env-site-preview" ]]; then
    preview_env_file="$gdc_home/.env-site-preview"
  else
    preview_env_file="$script_root/.env-site-preview"
  fi
  if [[ -r "$preview_env_file" ]]; then
    [[ ! -L "$preview_env_file" ]] || { echo 'preview environment file must not be a symlink' >&2; exit 2; }
    permissions="$(stat -c '%a' "$preview_env_file")"
    (( (8#$permissions & 077) == 0 )) || { echo 'preview environment file must not be readable by group or others' >&2; exit 2; }
    set -a
    # shellcheck disable=SC1090
    . "$preview_env_file"
    set +a
    deploy_host="${4:-${DEPLOY_HOST:-}}"
    deploy_user="${5:-${DEPLOY_USER:-}}"
  fi
fi

[[ "$deploy_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'set a valid deploy_host' >&2; exit 2; }
[[ "$deploy_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo 'set a valid deploy_user' >&2; exit 2; }
[[ "$site_origin" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'GDC_SITE_ORIGIN must be an HTTPS origin without a path' >&2; exit 2; }

if [[ -z "$site_publish_prefix" ]]; then
  destination=/srv/dai/edge/site
elif [[ "$site_publish_prefix" =~ ^preview/[1-9][0-9]*$ ]]; then
  destination="/srv/dai/edge/site/$site_publish_prefix"
else
  echo 'site_publish_prefix must be empty or preview/<positive-PR-number>' >&2
  exit 2
fi

ssh_options=(-o BatchMode=yes)
if [[ -n "${DEPLOY_PRIVATE_KEY_FILE:-}" || -n "${DEPLOY_KNOWN_HOSTS_FILE:-}" ]]; then
  [[ -n "${DEPLOY_PRIVATE_KEY_FILE:-}" && -n "${DEPLOY_KNOWN_HOSTS_FILE:-}" ]] || {
    echo 'set both DEPLOY_PRIVATE_KEY_FILE and DEPLOY_KNOWN_HOSTS_FILE' >&2
    exit 2
  }
  [[ -r "$DEPLOY_PRIVATE_KEY_FILE" && -r "$DEPLOY_KNOWN_HOSTS_FILE" ]] || {
    echo 'local preview key or known_hosts file is unreadable' >&2
    exit 2
  }
  ssh_options+=(-o IdentitiesOnly=yes -i "$DEPLOY_PRIVATE_KEY_FILE" -o "UserKnownHostsFile=$DEPLOY_KNOWN_HOSTS_FILE" -o StrictHostKeyChecking=yes)
elif [[ -n "${DEPLOY_KNOWN_HOSTS:-}" || -n "${DEPLOY_PRIVATE_KEY:-}" ]]; then
  [[ -n "${DEPLOY_KNOWN_HOSTS:-}" && -n "${DEPLOY_PRIVATE_KEY:-}" ]] || {
    echo 'set both DEPLOY_KNOWN_HOSTS and DEPLOY_PRIVATE_KEY' >&2
    exit 2
  }
  ssh_temp_root="${RUNNER_TEMP:-${GDC_HOME:-$HOME/.gdc-data}}"
  mkdir -p "$ssh_temp_root"
  ssh_temp_dir="$(mktemp -d "$ssh_temp_root/site-release-ssh.XXXXXX")"
  trap 'rm -rf -- "$ssh_temp_dir"' EXIT
  printf '%s\n' "$DEPLOY_KNOWN_HOSTS" >"$ssh_temp_dir/known_hosts"
  printf '%s\n' "$DEPLOY_PRIVATE_KEY" >"$ssh_temp_dir/id_ed25519"
  chmod 0600 "$ssh_temp_dir/id_ed25519" "$ssh_temp_dir/known_hosts"
  ssh_options+=(-o IdentitiesOnly=yes -i "$ssh_temp_dir/id_ed25519" -o "UserKnownHostsFile=$ssh_temp_dir/known_hosts" -o StrictHostKeyChecking=yes)
fi

remote="$deploy_user@$deploy_host"
ssh_transport="$(printf '%q ' ssh "${ssh_options[@]}")"
# destination is validated locally before it is interpolated into remote commands.
# shellcheck disable=SC2029
case "$action" in
  publish-preview)
    if [[ "$site_publish_prefix" =~ ^preview/([1-9][0-9]*)$ ]]; then
      preview_number="${BASH_REMATCH[1]}"
    else
      echo 'preview publication requires preview/<positive-PR-number>' >&2
      exit 2
    fi
    [[ -d "$site_release_dir" ]] || { echo 'preview release directory is required' >&2; exit 2; }
    generation="$(sed -n 's/.*"revision":"\([0-9a-f]\{40\}\)".*/\1/p' "$site_release_dir/site-build.js")"
    [[ "$generation" =~ ^[0-9a-f]{40}$ ]] || { echo 'preview release must contain a full revision' >&2; exit 2; }
    composition="$site_release_dir/preview-composition.json"
    [[ -s "$composition" ]] || { echo 'preview release must contain a composition manifest' >&2; exit 2; }
    mode="$(jq -r '.mode // empty' "$composition")"
    [[ "$mode" =~ ^(static|endpoint|combined)$ ]] || { echo 'preview release composition mode is invalid' >&2; exit 2; }
    remote_preview_root=/srv/dai/edge/site/preview
    remote_generation_root="$remote_preview_root/.generations/$preview_number"
    remote_staging="$remote_generation_root/.staging-$generation"
    remote_generation="$remote_generation_root/$generation"
    if [[ "$mode" == endpoint || "$mode" == combined ]]; then
      # The shared overlay is deployed by the reviewed edge lifecycle, never
      # copied from an untrusted preview artifact. Refuse before staging when
      # the public edge has not activated that route yet.
      ssh "${ssh_options[@]}" "$remote" \
        "body=\$(curl --fail --silent --show-error --connect-timeout 5 --max-time 15 '$site_origin/preview/$preview_number/status/participants'); test -n \"\$body\""
    fi
    # A repeated publish of the same immutable generation must not overwrite it.
    ssh "${ssh_options[@]}" "$remote" "install -d -m 0755 $remote_generation_root; test ! -e $remote_generation; rm -rf -- $remote_staging; install -d -m 0755 $remote_staging"
    rsync -a --delete --exclude preview/ -e "$ssh_transport" "$site_release_dir/" "$remote:$remote_staging/"
    # Validate the complete staged generation before one atomic rename replaces
    # the active preview symlink. The static digest intentionally includes the
    # OpenAPI documents but excludes its self-describing site-build.js.
    ssh "${ssh_options[@]}" "$remote" "bash -s -- publish $preview_number $generation" <"$script_root/scripts/switch-site-preview-generation.sh"
    ;;
  rollback-preview)
    if [[ "$site_publish_prefix" =~ ^preview/([1-9][0-9]*)$ ]]; then
      preview_number="${BASH_REMATCH[1]}"
    else
      echo 'preview rollback requires preview/<positive-PR-number>' >&2
      exit 2
    fi
    remote_preview_root=/srv/dai/edge/site/preview
    ssh "${ssh_options[@]}" "$remote" "bash -s -- rollback $preview_number" <"$script_root/scripts/switch-site-preview-generation.sh"
    ;;
  publish)
    [[ -d "$site_release_dir" ]] || { echo 'run prepare-static-site first' >&2; exit 2; }
    ssh "${ssh_options[@]}" "$remote" "install -d -m 0755 $destination"
    rsync -a --delete --exclude config.js --exclude preview/ -e "$ssh_transport" \
      "$site_release_dir/" "$remote:$destination/"
    ssh "${ssh_options[@]}" "$remote" \
      'cd /srv/dai/edge && sudo /usr/bin/docker compose up -d --force-recreate caddy'
    ;;
  remove)
    [[ "$site_publish_prefix" =~ ^preview/[1-9][0-9]*$ ]] || {
      echo 'site_publish_prefix must be preview/<positive-PR-number> for removal' >&2
      exit 2
    }
    ssh "${ssh_options[@]}" "$remote" "rm -rf -- $destination"
    ;;
  *) echo 'usage: site-release.sh publish|publish-preview|rollback-preview|remove SITE_RELEASE_DIR SITE_PUBLISH_PREFIX DEPLOY_HOST DEPLOY_USER' >&2; exit 2 ;;
esac
