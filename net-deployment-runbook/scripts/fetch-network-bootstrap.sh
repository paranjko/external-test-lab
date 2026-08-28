#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --url HTTPS_URL --output FILE" >&2; }

URL=''
OUTPUT=''
while (($#)); do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]]+$ && -n "$OUTPUT" ]] || { usage; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$(dirname "$OUTPUT")"
temporary="$(mktemp "$(dirname "$OUTPUT")/.${OUTPUT##*/}.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
status='000'
set +e
status="$(curl -sS --connect-timeout 10 --max-time 60 --retry 4 --retry-delay 2 --retry-all-errors -o "$temporary" -w '%{http_code}' "$URL")"
curl_status=$?
set -e
if (( curl_status != 0 )) || [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
  echo "network bootstrap download failed url=$URL http_status=$status curl_exit=$curl_status" >&2
  exit 1
fi
"$ROOT/scripts/network-bootstrap.sh" verify "$temporary" >/dev/null
chmod 0600 "$temporary"
mv -f -- "$temporary" "$OUTPUT"
printf 'PASS downloaded and validated network bootstrap url=%s sha256=%s\n' "$URL" "$(sha256sum "$OUTPUT" | awk '{print $1}')"
