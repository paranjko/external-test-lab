#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
release="$tmp/release"
mkdir -p "$release" "$tmp/bin"

printf '%s\n' '<main>preview</main>' >"$release/index.html"
digest="$(bash "$root/scripts/site-static-digest.sh" "$release")"
revision=0123456789012345678901234567890123456789
printf 'window.GDC_SITE_BUILD = {"revision":"%s","artifactDigest":"%s"};\n' "$revision" "$digest" >"$release/site-build.js"

cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
relative="${url##*/preview/103/}"
if [[ "$relative" == site-build.js && ! -e "$PREVIEW_CURL_ATTEMPT" ]]; then
  : >"$PREVIEW_CURL_ATTEMPT"
  printf '%s\n' 'window.GDC_SITE_BUILD = {"revision":"stale"};'
  exit 0
fi
cat "$PREVIEW_FIXTURE_DIR/$relative"
SH
cat >"$tmp/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp/bin/curl" "$tmp/bin/sleep"

PREVIEW_CURL_ATTEMPT="$tmp/attempt" PREVIEW_FIXTURE_DIR="$release" PATH="$tmp/bin:$PATH" \
  GDC_SITE_PREVIEW_VERIFY_WAIT_SECONDS=2 \
  "$root/scripts/verify-site-preview-live.sh" "$release" preview/103 "$revision" https://example.test
[[ -e "$tmp/attempt" ]] || { echo 'preview verifier did not retry a stale manifest' >&2; exit 1; }
printf 'PASS preview verifier waits for a coherent published payload\n'
