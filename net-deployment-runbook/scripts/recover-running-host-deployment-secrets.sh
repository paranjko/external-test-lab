#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || die 'usage: recover-running-host-deployment-secrets.sh SSH_ALIAS SECRETS_DIR'
node="$1"
secrets_dir="$2"
[[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid running Host SSH alias'
[[ "$secrets_dir" == /* ]] || die 'running Host secrets directory must be absolute'

remote_values="$(ssh -T "$node" "sudo awk -F= '
  \$1 == \"KEYRING_PASSWORD\" || \$1 == \"POSTGRES_PASSWORD\" {
    print \$1 \"=\" substr(\$0, index(\$0, \"=\") + 1)
  }
' '/srv/dai/deploy/$node/.env'")" \
  || die "$node deployed keyring and database secrets are unavailable"

remote_secret() {
  local name="$1" count value
  count="$(grep -c "^${name}=" <<<"$remote_values" || true)"
  [[ "$count" == 1 ]] || die "$node deployment has no unique $name"
  value="$(grep "^${name}=" <<<"$remote_values")"
  value="${value#*=}"
  [[ "$value" =~ ^[A-Za-z0-9]{48}$ ]] || die "$node deployment has malformed $name"
  printf '%s\n' "$value"
}

install_secret() {
  local label="$1" value="$2" target="$3" existing
  if [[ -e "$target" ]]; then
    [[ -f "$target" && -r "$target" ]] || die "local $label is not a readable regular file"
    existing="$(<"$target")"
    [[ "$existing" == "$value" ]] \
      || die "local $label conflicts with the unchanged running Host deployment"
    chmod 0600 "$target"
    return 0
  fi
  printf '%s\n' "$value" >"$target"
  chmod 0600 "$target"
}

keyring_password="$(remote_secret KEYRING_PASSWORD)"
postgres_password="$(remote_secret POSTGRES_PASSWORD)"
umask 077
install -d -m 0700 "$secrets_dir"
install_secret 'node keyring password' "$keyring_password" "$secrets_dir/$node.keyring"
install_secret 'PostgreSQL password' "$postgres_password" "$secrets_dir/$node.postgres"
printf 'READY recovered deployment passwords for %s without changing the Host\n' "$node"
