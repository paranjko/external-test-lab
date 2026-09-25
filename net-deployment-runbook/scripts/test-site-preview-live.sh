#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${TMPDIR:-$root/../.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/gdc-site-preview-live.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
release="$tmp/release"
mkdir -p "$release" "$tmp/bin"

grep -Fq 'site_origin ?= https://gonka-dev.net' "$root/Makefile"
grep -Fq 'url: https://preview.gonka-dev.net/${{ needs.publish-context.outputs.number }}/' \
  "$root/../.github/workflows/site-preview-publish.yml"

printf '%s\n' '<main>preview</main>' >"$release/index.html"
revision=0123456789012345678901234567890123456789
printf '%s\n' '{"schema_version":1,"base_revision":"0123456789012345678901234567890123456789","head_revision":"0123456789012345678901234567890123456789","mode":"static","static_revision":"0123456789012345678901234567890123456789","endpoint_revision":"0123456789012345678901234567890123456789","runtime_dependencies":{"config":"/config.js","status_base":"/status"},"endpoint_handlers":[],"changed_files":["net-deployment-runbook/04-ops/site/index.html"],"digest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}' >"$release/preview-composition.json"
digest="$(bash "$root/scripts/site-static-digest.sh" "$release")"
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
