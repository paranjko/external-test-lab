#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${TMPDIR:-$ROOT/../.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/gdc-preview-endpoints-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
release="$tmp/release"
mkdir -p "$release" "$tmp/bin"

cat >"$release/preview-composition.json" <<'JSON'
{
  "mode": "combined"
}
JSON

cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
headers=''
body=''
url=''
while (($#)); do
  case "$1" in
    --dump-header) headers="$2"; shift 2 ;;
    --output) body="$2"; shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >>"$CALLS"
if [[ "$url" == */preview/* && "${MODE:-good}" == http_failure ]]; then exit 22; fi
content_type=application/json
if [[ "$url" == */preview/* && "${MODE:-good}" == wrong_type ]]; then content_type=text/html; fi
printf 'Content-Type: %s\r\n' "$content_type" >"$headers"
if [[ "$url" == */preview/* && "${MODE:-good}" == empty ]]; then : >"$body"; exit 0; fi
value=stable
if [[ "$url" == */preview/* && "${MODE:-good}" == wrong_body ]]; then value=changed; fi
case "$url" in
  */status/gateway-health|*/status/gdc-node0/health) printf 'healthy\n' >"$body" ;;
  *) printf '{"timestamp":"%s","value":"%s"}\n' "$RANDOM" "$value" >"$body" ;;
esac
SH
chmod 0755 "$tmp/bin/curl"

export CALLS="$tmp/calls"
PATH="$tmp/bin:$PATH" TMPDIR="$tmp" \
  "$ROOT/scripts/verify-site-preview-endpoints.sh" "$release" preview/172 https://example.test
[[ "$(wc -l <"$CALLS")" -eq 8 ]]
for endpoint in participants gateway-health gateway/v1/status gdc-node0/health; do
  grep -Fxq "https://example.test/status/$endpoint" "$CALLS"
  grep -Fxq "https://example.test/preview/172/status/$endpoint" "$CALLS"
done
for mode in wrong_type wrong_body empty http_failure; do
  if MODE="$mode" PATH="$tmp/bin:$PATH" TMPDIR="$tmp" \
    "$ROOT/scripts/verify-site-preview-endpoints.sh" "$release" preview/172 https://example.test >"$tmp/$mode.log" 2>&1; then
    printf 'FAIL preview verifier accepted %s\n' "$mode" >&2
    exit 1
  fi
done

printf 'PASS preview endpoint verifier compares the production-equivalent overlay without live network access\n'
