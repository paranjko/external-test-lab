#!/usr/bin/env bash
set -Eeuo pipefail

# Root-owned, narrowly callable administration boundary for the preview
# account. `ops` may pass a candidate public key but cannot choose a script,
# environment, path, or arbitrary root command.

LIBRARY=/usr/local/lib/gdc-preview
USER_PREVIEW="$LIBRARY/user-preview.sh"

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || die 'run through sudo as root'
[[ -x "$USER_PREVIEW" && ! -L "$USER_PREVIEW" ]] || die 'trusted preview provisioner is unavailable'

case "${1:-}" in
  verify)
    [[ $# -eq 1 ]] || die 'usage: preview-admin.sh verify|provision <base64-public-key>'
    exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$USER_PREVIEW" verify
    ;;
  provision)
    [[ $# -eq 2 ]] || die 'usage: preview-admin.sh verify|provision <base64-public-key>'
    [[ "$2" =~ ^[A-Za-z0-9+/=]+$ ]] || die 'encoded public key is invalid'
    key="$(printf '%s' "$2" | base64 --decode 2>/dev/null)" || die 'encoded public key is invalid'
    [[ -n "$key" && "$key" != *$'\n'* && "$key" != *$'\r'* ]] || die 'decoded public key is invalid'
    exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin PREVIEW_AUTHORIZED_KEY="$key" "$USER_PREVIEW" provision
    ;;
  *) die 'usage: preview-admin.sh verify|provision <base64-public-key>' ;;
esac
