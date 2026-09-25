#!/usr/bin/env bash
set -Eeuo pipefail

release_dir="${1:-}"
prefix="${2:-}"
origin="${3:-}"
[[ -d "$release_dir" ]] || { echo 'release directory is required' >&2; exit 2; }
[[ "$prefix" =~ ^preview/[1-9][0-9]*$ ]] || { echo 'preview path is invalid' >&2; exit 2; }
[[ "$origin" =~ ^https?://[^/]+$ ]] || { echo 'site origin is invalid' >&2; exit 2; }

composition="$release_dir/preview-composition.json"
[[ -s "$composition" ]] || { echo 'preview composition manifest is required' >&2; exit 1; }
mode="$(sed -n 's/.*"mode": "\(static\|endpoint\|combined\)".*/\1/p' "$composition")"
[[ -n "$mode" ]] || { echo 'preview composition mode is invalid' >&2; exit 1; }
if [[ "$mode" == static ]]; then
  printf 'PASS static preview intentionally uses production status endpoints\n'
  exit 0
fi

tmp_root="${TMPDIR:-$(cd "$(dirname "$0")/../.." && pwd)/.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/gdc-preview-endpoints.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

# These contracts are unaffected by GPU/software presentation. The overlay
# must preserve their response body and media type without browser fallback.
endpoints=(participants gateway-health gateway/v1/status gdc-node0/health)

fetch() {
  local url="$1" headers="$2" body="$3"
  curl --silent --show-error --fail --connect-timeout 5 --max-time 15 \
    --header 'Cache-Control: no-cache' --dump-header "$headers" --output "$body" "$url"
  [[ -s "$body" ]] || { echo "endpoint returned an empty body: $url" >&2; exit 1; }
}

content_type() {
  awk -F ': *' 'BEGIN { IGNORECASE=1 } tolower($1) == "content-type" { value=$2 } END { sub(/\r$/, "", value); print value }' "$1"
}

normalise() {
  local endpoint="$1" input="$2"
  if [[ "$endpoint" == participants || "$endpoint" == gateway/v1/status ]]; then
    jq -S 'del(.. | .timestamp?, .updated_at?, .last_updated?, .observed_at?)' "$input"
  else
    cat "$input"
  fi
}

for endpoint in "${endpoints[@]}"; do
  stem="${endpoint//\//_}"
  fetch "$origin/status/$endpoint" "$tmp/production-$stem.headers" "$tmp/production-$stem.body"
  fetch "$origin/$prefix/status/$endpoint" "$tmp/preview-$stem.headers" "$tmp/preview-$stem.body"
  [[ "$(content_type "$tmp/production-$stem.headers")" == "$(content_type "$tmp/preview-$stem.headers")" ]] || {
    echo "preview content type differs for /status/$endpoint" >&2
    exit 1
  }
  normalise "$endpoint" "$tmp/production-$stem.body" >"$tmp/production-$stem.normalised"
  normalise "$endpoint" "$tmp/preview-$stem.body" >"$tmp/preview-$stem.normalised"
  cmp "$tmp/production-$stem.normalised" "$tmp/preview-$stem.normalised" || {
    echo "preview response differs from production for unchanged /status/$endpoint" >&2
    exit 1
  }
done

printf 'PASS preview endpoint overlay matches production contracts for unchanged endpoints\n'
