#!/usr/bin/env bash
set -Eeuo pipefail

# Installed once by the host owner over the root bootstrap transport. It
# creates a root-owned helper and grants ops only its fixed provision/verify
# interface – never a generic root shell or Docker socket.

PREVIEW_OPS_USER=ops
LIBRARY=/usr/local/lib/gdc-preview
SUDOERS_FILE=/etc/sudoers.d/gdc-preview-ops
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || die 'run as root'
[[ "${1:-bootstrap}" == bootstrap && $# -eq 1 ]] || die 'usage: install-preview-admin.sh bootstrap'
[[ "$PREVIEW_OPS_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die 'PREVIEW_OPS_USER is invalid'
getent passwd "$PREVIEW_OPS_USER" >/dev/null || die "required user is absent: $PREVIEW_OPS_USER"
command -v visudo >/dev/null || die 'visudo is required'

for source in user-preview.sh preview-admin.sh install-rootless-prerequisites.sh; do
  [[ -f "$SOURCE_DIR/$source" && ! -L "$SOURCE_DIR/$source" ]] || die "trusted source is unsafe or absent: $source"
done
[[ ! -e "$LIBRARY" || ( -d "$LIBRARY" && ! -L "$LIBRARY" ) ]] || die 'preview helper directory is unsafe'
[[ ! -e "$SUDOERS_FILE" || ! -L "$SUDOERS_FILE" ]] || die 'preview sudoers path is unsafe'

install -d -o root -g root -m 0755 "$LIBRARY"
install -o root -g root -m 0755 "$SOURCE_DIR/user-preview.sh" "$LIBRARY/user-preview.sh"
install -o root -g root -m 0755 "$SOURCE_DIR/preview-admin.sh" "$LIBRARY/preview-admin.sh"
install -o root -g root -m 0755 "$SOURCE_DIR/install-rootless-prerequisites.sh" "$LIBRARY/install-rootless-prerequisites.sh"

temporary="$(mktemp "${SUDOERS_FILE}.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
cat >"$temporary" <<EOF
$PREVIEW_OPS_USER ALL=(root) NOPASSWD: $LIBRARY/preview-admin.sh verify, $LIBRARY/preview-admin.sh provision *
EOF
chmod 0440 "$temporary"
visudo -cf "$temporary" >/dev/null
install -o root -g root -m 0440 "$temporary" "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

printf 'READY preview administrator installed helper=%s sudo_user=%s\n' "$LIBRARY/preview-admin.sh" "$PREVIEW_OPS_USER"
