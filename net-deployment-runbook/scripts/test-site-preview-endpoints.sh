#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -Fq 'previewPrefix && DYNAMIC_STATUS_HOST.test(host)' "$ROOT/04-ops/site/src/app.js"
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
printf 'Content-Type: application/json\r\n' >"$headers"
case "$url" in
  */status/gateway-health|*/status/gdc-node0/health) printf 'healthy\n' >"$body" ;;
  *) printf '{"timestamp":"volatile","value":"stable"}\n' >"$body" ;;
esac
SH
chmod 0755 "$tmp/bin/curl"

PATH="$tmp/bin:$PATH" TMPDIR="$tmp" \
  "$ROOT/scripts/verify-site-preview-endpoints.sh" "$release" preview/172 https://example.test

printf 'PASS preview endpoint verifier compares the production-equivalent overlay without live network access\n'
