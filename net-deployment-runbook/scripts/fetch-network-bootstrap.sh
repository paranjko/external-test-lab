#!/bin/sh
# Download a Bootstrap descriptor on the local operator machine. Keep this
# path POSIX-sh compatible: it runs before any SSH or Host mutation.
set -eu

usage() { echo "Usage: $0 --url HTTPS_URL --output FILE" >&2; }

URL=''
OUTPUT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) URL=${2:-}; shift 2 ;;
    --output) OUTPUT=${2:-}; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
printf '%s\n' "$URL" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]]+$' \
  && [ -n "$OUTPUT" ] || { usage; exit 2; }

ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
# shellcheck source=portable.sh
. "$ROOT/scripts/portable.sh"
gdc_require_jq || exit $?
command -v curl >/dev/null 2>&1 || {
  printf 'dependency_missing: curl is required to download network Bootstrap\nmutation=none\n' >&2
  exit 69
}

output_dir=$(dirname "$OUTPUT")
mkdir -p "$output_dir"
temporary=$(mktemp "$output_dir/.${OUTPUT##*/}.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
status='000'
set +e
status=$(curl -sS --connect-timeout 10 --max-time 60 --retry 4 --retry-delay 2 --retry-all-errors -o "$temporary" -w '%{http_code}' "$URL")
curl_status=$?
set -e
case "$status" in 2??) http_ok=true ;; *) http_ok=false ;; esac
if [ "$curl_status" -ne 0 ] || [ "$http_ok" != true ]; then
  printf 'network bootstrap download failed url=%s http_status=%s curl_exit=%s\nmutation=none\n' "$URL" "$status" "$curl_status" >&2
  exit 1
fi
"$ROOT/scripts/network-bootstrap.sh" verify "$temporary" >/dev/null
chmod 0600 "$temporary"
mv "$temporary" "$OUTPUT"
printf 'PASS downloaded and validated network bootstrap url=%s sha256=%s\n' "$URL" "$(gdc_sha256 "$OUTPUT")"
