#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/release/assets" "$tmp/remote/assets"

printf '<html><script src="assets/app.js"></script></html>\n' >"$tmp/release/index.html"
printf 'console.log("release");\n' >"$tmp/release/assets/app.js"
digest="$(bash "$ROOT/scripts/site-static-digest.sh" "$tmp/release")"
printf 'globalThis.GDC_SITE_BUILD={"revision":"%040d","artifactDigest":"%s"};\n' 0 "$digest" >"$tmp/release/site-build.js"
cp -R "$tmp/release/." "$tmp/remote/"

cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${*: -1}"
path="${url#http://site.test/}"
printf '%s\n' "/$path" >>"$CURL_LOG"
[[ "$path" != status/* ]] || { echo 'dynamic endpoint requested' >&2; exit 90; }
[[ -f "$REMOTE_DIR/$path" ]] || exit 22
cat "$REMOTE_DIR/$path"
CURL
chmod +x "$tmp/bin/curl"

CURL_LOG="$tmp/curl.log" REMOTE_DIR="$tmp/remote" PATH="$tmp/bin:$PATH" \
  GDC_SITE_RELEASE_VERIFY_WAIT_SECONDS=1 \
  make -C "$ROOT" verify-site-release \
    site_release_dir="$tmp/release/" site_origin=http://site.test

if grep -Eq '^/status/' "$tmp/curl.log"; then
  echo 'site release verifier requested a dynamic endpoint' >&2
  exit 1
fi
grep -Fxq '/index.html' "$tmp/curl.log"
grep -Fxq '/assets/app.js' "$tmp/curl.log"
grep -Fxq '/site-build.js' "$tmp/curl.log"

printf 'console.log("stale");\n' >"$tmp/remote/assets/app.js"
if CURL_LOG="$tmp/mismatch.log" REMOTE_DIR="$tmp/remote" PATH="$tmp/bin:$PATH" \
  GDC_SITE_RELEASE_VERIFY_WAIT_SECONDS=1 \
  make -C "$ROOT" verify-site-release \
  site_release_dir="$tmp/release" site_origin=http://site.test \
  >"$tmp/mismatch.out" 2>"$tmp/mismatch.err"; then
  echo 'static mismatch unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'published static file differs: assets/app.js' "$tmp/mismatch.err"

printf 'PASS site release verification is static-only and detects mismatched assets\n'
