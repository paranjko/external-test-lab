#!/usr/bin/env bash
set -Eeuo pipefail
[[ ( $# -eq 1 || $# -eq 3 ) && $EUID -eq 0 ]] || { echo "Usage: sudo $0 rendered-admission.env [--preserve-compose SHA256]" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/srv/dai/edge
preserve_compose=false
if [[ $# -eq 3 ]]; then
  [[ $2 == --preserve-compose && $3 =~ ^[a-f0-9]{64}$ ]] || exit 2
  [[ -f "$DEST/compose.yaml" && ! -L "$DEST/compose.yaml" && ! -L "$DEST" ]]
  [[ $(sha256sum "$DEST/compose.yaml" | cut -d' ' -f1) == "$3" ]] || {
    echo 'existing edge composition changed before admission installation' >&2; exit 2;
  }
  for target in gateway-admission-proxy.py gateway-admission.env status; do
    [[ ! -L "$DEST/$target" ]] || { echo 'admission target must not be a symlink' >&2; exit 2; }
  done
  for target in gateway-admission-proxy.py gateway-admission.env; do
    [[ ! -e "$DEST/$target" || -f "$DEST/$target" ]] || {
      echo 'preserved admission target must be a regular file' >&2; exit 2;
    }
  done
  [[ ! -e "$DEST/status" || -d "$DEST/status" ]] || exit 2
  preserve_compose=true
fi

protocols_json="$(sed -n 's/^GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=//p' "$1")"
status_bearer_token="$(sed -n 's/^GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=//p' "$1")"
jq -e '
  type == "object" and length > 0
  and all(to_entries[];
    (.key | test("^v[3456]$"))
    and (.value.binary | test("^https?://"))
    and (.value.sha256 | test("^[0-9a-f]{64}$")))
' <<<"$protocols_json" >/dev/null \
  || { echo 'gateway admission environment has an invalid protocol contract' >&2; exit 2; }
if [[ ! "$status_bearer_token" =~ ^[A-Za-z0-9._:-]+$ ]] \
  || (( ${#status_bearer_token} < 16 || ${#status_bearer_token} > 256 )); then
  echo 'gateway admission environment has an invalid status credential' >&2
  exit 2
fi

install -d -m 0755 "$DEST"
if [[ $preserve_compose == false ]]; then
  install -m 0644 "$HERE/compose.yaml" "$DEST/compose.yaml"
fi
# A failed first deployment can leave this exact bind-mount target as a
# directory. Remove only that known invalid target before installing the file.
if [[ -d "$DEST/gateway-admission-proxy.py" ]]; then
  rm -rf "$DEST/gateway-admission-proxy.py"
fi
if [[ -d "$DEST/gateway-admission.env" ]]; then
  rm -rf "$DEST/gateway-admission.env"
fi
install -m 0644 "$HERE/gateway-admission-proxy.py" "$DEST/gateway-admission-proxy.py"
install -d -m 0750 "$DEST/status"
install -m 0600 "$1" "$DEST/gateway-admission.env"
if [[ $preserve_compose == false ]]; then
  chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST/compose.yaml"
fi
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" \
  "$DEST/gateway-admission-proxy.py" \
  "$DEST/gateway-admission.env" "$DEST/status"
printf 'READY installed gateway admission contract in %s\n' "$DEST"
