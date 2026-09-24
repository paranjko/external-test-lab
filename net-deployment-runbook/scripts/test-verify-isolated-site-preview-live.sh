#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$root/.data/verify-isolated-preview-live-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/release" "$tmp/bin"
revision=0123456789012345678901234567890123456789
printf '%s\n' '{"mode":"combined"}' >"$tmp/release/preview-composition.json"

cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
case "$url" in
  */site-build.js) printf 'window.GDC_SITE_BUILD = {"revision":"%s"};\n' "$PREVIEW_TEST_REVISION" ;;
  */status/gpus) printf '%s\n' '{"gpus":[]}' ;;
  */) printf '%s\n' '<!doctype html><title>preview</title>' ;;
  *) exit 22 ;;
esac
SH
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" PREVIEW_TEST_REVISION="$revision" PREVIEW_ORIGIN=https://preview.gonka-dev.net \
  site_release_dir="$tmp/release" preview_number=172 preview_revision="$revision" \
  "$root/scripts/verify-isolated-site-preview-live.sh"
printf 'PASS isolated public preview verifier checks source revision and backend route\n'
