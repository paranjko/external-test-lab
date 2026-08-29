#!/usr/bin/env bash
set -Eeuo pipefail

# Provision the least-privilege account used by the public-site publication
# workflow. Invoke on the target host as root and supply one SSH public key:
#
#   OPS_AUTHORIZED_KEY="$(<ops.pub)" sudo -E ./ops/chore/user-ops.sh

OPS_USER=ops
SITE_ROOT=/srv/dai/edge/site
SUDOERS_FILE=/etc/sudoers.d/gonka-site-ops
DOCKER_BIN=/usr/bin/docker
SETFACL_BIN=/usr/bin/setfacl

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ -n "${OPS_AUTHORIZED_KEY:-}" ]] || die 'set OPS_AUTHORIZED_KEY to one SSH public key'
[[ "$OPS_AUTHORIZED_KEY" != *$'\n'* && "$OPS_AUTHORIZED_KEY" != *$'\r'* ]] \
  || die 'OPS_AUTHORIZED_KEY must contain exactly one line'
[[ "$OPS_AUTHORIZED_KEY" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] \
  || die 'OPS_AUTHORIZED_KEY is not an accepted SSH public key'
[[ -x "$DOCKER_BIN" ]] || die "required Docker binary is missing: $DOCKER_BIN"
[[ -x "$SETFACL_BIN" ]] || die "required ACL utility is missing: $SETFACL_BIN"
[[ -f /srv/dai/edge/compose.yaml ]] || die 'public edge Compose file is missing'

if ! getent passwd "$OPS_USER" >/dev/null; then
  useradd --create-home --user-group --shell /bin/bash "$OPS_USER"
fi

install -d -o "$OPS_USER" -g "$OPS_USER" -m 0700 "/home/$OPS_USER/.ssh"
install -m 0600 /dev/null "/home/$OPS_USER/.ssh/authorized_keys"
printf '%s\n' "$OPS_AUTHORIZED_KEY" >"/home/$OPS_USER/.ssh/authorized_keys"
chown "$OPS_USER:$OPS_USER" "/home/$OPS_USER/.ssh/authorized_keys"

# The workflow preserves config.js. The deploy account owns only the static
# site directory required to replace browser assets without changing it.
install -d -o "$OPS_USER" -g "$OPS_USER" -m 0775 "$SITE_ROOT"
chown "$OPS_USER:$OPS_USER" "$SITE_ROOT"
# `/srv/dai` deliberately remains private to the deployment owner. Grant the
# deploy account traversal only; it cannot list or read other operator data.
"$SETFACL_BIN" -m "u:$OPS_USER:--x" /srv/dai
runuser -u "$OPS_USER" -- test -w "$SITE_ROOT" \
  || die "user $OPS_USER cannot write $SITE_ROOT"

temporary="$(mktemp "${SUDOERS_FILE}.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
printf '%s ALL=(root) NOPASSWD: %s compose up -d --force-recreate caddy\n' \
  "$OPS_USER" "$DOCKER_BIN" >"$temporary"
chmod 0440 "$temporary"
visudo -cf "$temporary" >/dev/null
install -o root -g root -m 0440 "$temporary" "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

printf 'READY user=%s site_root=%s sudo_command=%s compose up -d --force-recreate caddy\n' \
  "$OPS_USER" "$SITE_ROOT" "$DOCKER_BIN"
