#!/usr/bin/env bash
set -Eeuo pipefail

# Restrict the source-bound collector to the preview's trusted egress routes.
# The collector's only curl call supplies this exact option list and one URL.

preview_curl_target() {
  local url="${1:-}" ip a b c d
  if [[ "$url" =~ ^https://gonka-dev\.net/([A-Za-z0-9][A-Za-z0-9._-]{0,127})/bootstrap\.json$ ]]; then
    printf '/observer/bootstrap/%s/bootstrap.json\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$url" =~ ^https://node([0-9]+)\.gonka-dev\.net(/[^?#]*)(\?([A-Za-z0-9._~%&=+-]+))?$ ]]; then
    printf '/observer/node/node%s%s%s\n' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]:-}"
    return 0
  fi
  if [[ "$url" =~ ^https://ipwho\.is/([0-9]{1,3}(\.[0-9]{1,3}){3})$ ]]; then
    ip="${BASH_REMATCH[1]}"
    IFS=. read -r a b c d <<<"$ip"
    [[ "$a" =~ ^[0-9]{1,3}$ && "$b" =~ ^[0-9]{1,3}$ &&
      "$c" =~ ^[0-9]{1,3}$ && "$d" =~ ^[0-9]{1,3}$ ]] || return 1
    a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d))
    ((a <= 223 && b <= 255 && c <= 255 && d <= 255)) || return 1
    ((a != 0 && a != 10 && a != 127)) || return 1
    ((a != 100 || b < 64 || b > 127)) || return 1
    ((a != 169 || b != 254)) || return 1
    ((a != 172 || b < 16 || b > 31)) || return 1
    ((a != 192 || b != 0 || c != 0)) || return 1
    ((a != 192 || b != 0 || c != 2)) || return 1
    ((a != 192 || b != 88 || c != 99)) || return 1
    ((a != 192 || b != 168)) || return 1
    ((a != 198 || b < 18 || b > 19)) || return 1
    ((a != 198 || b != 51 || c != 100)) || return 1
    ((a != 203 || b != 0 || c != 113)) || return 1
    printf '/observer/geo/%s\n' "$ip"
    return 0
  fi
  return 1
}

main() {
  [[ $# -eq 8 && "$1" == -fsS && "$2" == --connect-timeout && "$3" == 3 &&
    "$4" == --max-time && "$5" == 5 && "$6" == --max-filesize && "$7" == 16777216 ]] || {
    echo 'preview collector request is outside the read-only transport contract' >&2
    return 2
  }
  local target
  target="$(preview_curl_target "$8")" || {
    echo 'preview collector URL is outside the read-only transport contract' >&2
    return 2
  }
  exec /usr/bin/curl -fsS --connect-timeout 3 --max-time 5 --max-filesize 16777216 \
    "http://gdc-preview-egress:8080$target"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
