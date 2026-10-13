#!/usr/bin/env bash
set -Eeuo pipefail

# Convert GitHub Environment secrets into the same strictly parsed local
# configuration consumed by isolated-preview-publish.sh. Do not echo values.

output="${PREVIEW_DEPLOY_ENV_FILE:-}"
deploy_host="${DEPLOY_HOST:-}"
deploy_user="${DEPLOY_USER:-preview}"
private_key="${DEPLOY_PRIVATE_KEY:-}"
known_hosts="${DEPLOY_KNOWN_HOSTS:-}"
prometheus_origin="${PREVIEW_PROMETHEUS_ORIGIN:-}"

die() { printf 'ERROR %s\n' "$*" >&2; exit 2; }
[[ "$output" = /* && "$output" != / && "$output" != *..* && ! -e "$output" ]] || die 'PREVIEW_DEPLOY_ENV_FILE must be a new absolute safe path'
[[ "$deploy_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die 'DEPLOY_HOST is invalid'
[[ "$deploy_user" == preview ]] || die 'DEPLOY_USER must be preview'
[[ -n "$private_key" && -n "$known_hosts" ]] || die 'deployment key and known-hosts data are required'
[[ "$prometheus_origin" =~ ^http://[A-Za-z0-9.-]+:9099$ ]] || die 'PREVIEW_PROMETHEUS_ORIGIN must be http://HOST:9099'

directory="$(dirname "$output")"
install -d -m 0700 "$directory"
umask 077
key_file="$directory/deploy.key"
known_hosts_file="$directory/known_hosts"
printf '%s\n' "$private_key" >"$key_file"
printf '%s\n' "$known_hosts" >"$known_hosts_file"
chmod 0600 "$key_file" "$known_hosts_file"
cat >"$output" <<EOF
DEPLOY_HOST=$deploy_host
DEPLOY_USER=$deploy_user
DEPLOY_PRIVATE_KEY_FILE=$key_file
DEPLOY_KNOWN_HOSTS_FILE=$known_hosts_file
PREVIEW_PROMETHEUS_ORIGIN=$prometheus_origin
EOF
chmod 0600 "$output"
printf 'PASS wrote isolated preview deployment configuration\n'
