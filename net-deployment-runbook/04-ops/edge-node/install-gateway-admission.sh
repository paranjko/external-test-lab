#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 && $EUID -eq 0 ]] || { echo "Usage: sudo $0 rendered-admission.env" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/srv/dai/edge

protocols_json="$(sed -n 's/^GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=//p' "$1")"
single_runtime_protocol="$(sed -n 's/^GDC_GATEWAY_ADMISSION_SINGLE_RUNTIME_PROTOCOL=//p' "$1")"
jq -e '
  type == "object" and length > 0
  and all(to_entries[];
    (.key | test("^v[345]$"))
    and (.value.binary | test("^https?://"))
    and (.value.sha256 | test("^[0-9a-f]{64}$")))
' <<<"$protocols_json" >/dev/null \
  || { echo 'gateway admission environment has an invalid protocol contract' >&2; exit 2; }
if [[ ! "$single_runtime_protocol" =~ ^v[345]$ ]] \
  || ! jq -e --arg protocol "$single_runtime_protocol" 'has($protocol)' <<<"$protocols_json" >/dev/null; then
  echo 'gateway admission environment has an invalid single-runtime protocol' >&2
  exit 2
fi

install -d -m 0755 "$DEST"
install -m 0644 "$HERE/compose.yaml" "$DEST/compose.yaml"
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
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" \
  "$DEST/compose.yaml" "$DEST/gateway-admission-proxy.py" \
  "$DEST/gateway-admission.env" "$DEST/status"
printf 'READY installed gateway admission contract in %s\n' "$DEST"
