#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${TMPDIR:-$ROOT/../.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/gdc-preview-generation.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
root="$tmp/site/preview"
number=172
first=1111111111111111111111111111111111111111
second=2222222222222222222222222222222222222222

stage() {
  local revision="$1" directory expected
  directory="$root/.generations/$number/.staging-$revision"
  mkdir -p "$directory"
  printf '<script src="config.js"></script>\n' >"$directory/index.html"
  printf 'console.log("preview");\n' >"$directory/app.js"
  cat >"$directory/preview-composition.json" <<'JSON'
{
  "mode": "static",
  "runtime_dependencies": {
    "config": "/config.js"
  },
  "endpoint_handlers": [],
  "endpoint_sources": []
}
JSON
  expected="$(bash "$ROOT/scripts/site-static-digest.sh" "$directory")"
  printf 'window.GDC_SITE_BUILD = {"revision":"%s","artifactDigest":"%s"};\n' "$revision" "$expected" >"$directory/site-build.js"
}

stage "$first"
GDC_SITE_PREVIEW_ROOT="$root" "$ROOT/scripts/switch-site-preview-generation.sh" publish "$number" "$first"
[[ "$(readlink "$root/$number")" == ".generations/$number/$first" ]]

stage "$second"
GDC_SITE_PREVIEW_ROOT="$root" "$ROOT/scripts/switch-site-preview-generation.sh" publish "$number" "$second"
[[ "$(readlink "$root/$number")" == ".generations/$number/$second" ]]
[[ "$(cat "$root/$number/previous-generation")" == ".generations/$number/$first" ]]

GDC_SITE_PREVIEW_ROOT="$root" "$ROOT/scripts/switch-site-preview-generation.sh" rollback "$number"
[[ "$(readlink "$root/$number")" == ".generations/$number/$first" ]]

stage 3333333333333333333333333333333333333333
printf 'fixture\n' >"$root/.generations/$number/.staging-3333333333333333333333333333333333333333/status"
if GDC_SITE_PREVIEW_ROOT="$root" "$ROOT/scripts/switch-site-preview-generation.sh" publish "$number" 3333333333333333333333333333333333333333; then
  echo 'invalid staged preview unexpectedly published' >&2
  exit 1
fi
[[ "$(readlink "$root/$number")" == ".generations/$number/$first" ]]

printf 'PASS preview generations validate before an atomic switch and preserve rollback state\n'
