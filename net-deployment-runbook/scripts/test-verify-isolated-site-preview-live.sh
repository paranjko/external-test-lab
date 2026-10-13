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
cat >"$tmp/bin/node" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == "$PREVIEW_TEST_VERIFIER" && "$2" == --base-url && "$3" == "$PREVIEW_ORIGIN" &&
   "$4" == --status-prefix && "$5" == "/$PREVIEW_TEST_NUMBER/status" ]] || {
  echo 'live preview verifier passed an unexpected observer target' >&2
  exit 2
}
[[ "${PREVIEW_TEST_OBSERVER_RESULT:-pass}" == pass ]] || {
  echo 'fixture observer capability failure' >&2
  exit 1
}
SH
chmod +x "$tmp/bin/curl" "$tmp/bin/node"
PATH="$tmp/bin:$PATH" PREVIEW_TEST_REVISION="$revision" PREVIEW_ORIGIN=https://preview.gonka-dev.net \
  PREVIEW_TEST_VERIFIER="$root/scripts/verify-network-observer.mjs" PREVIEW_TEST_NUMBER=172 \
  site_release_dir="$tmp/release" preview_number=172 preview_revision="$revision" \
  "$root/scripts/verify-isolated-site-preview-live.sh"
if PATH="$tmp/bin:$PATH" PREVIEW_TEST_REVISION="$revision" PREVIEW_ORIGIN=https://preview.gonka-dev.net \
  PREVIEW_TEST_VERIFIER="$root/scripts/verify-network-observer.mjs" PREVIEW_TEST_NUMBER=172 PREVIEW_TEST_OBSERVER_RESULT=fail \
  site_release_dir="$tmp/release" preview_number=172 preview_revision="$revision" \
  "$root/scripts/verify-isolated-site-preview-live.sh" >"$tmp/fail.out" 2>&1; then
  echo 'live preview verifier ignored a failed network observer check' >&2
  exit 1
fi
grep -Fq 'source-bound network observer HTTP/WebSocket routes are unavailable or invalid' "$tmp/fail.out"
printf 'PASS isolated public preview verifier checks source revision and backend route\n'
