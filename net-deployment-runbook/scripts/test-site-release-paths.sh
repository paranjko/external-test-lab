#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${TMPDIR:-$ROOT/../.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/gdc-site-release-paths.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

make -C "$ROOT" prepare-static-site site_release_dir="$tmp/site"

node - "$tmp/site" <<'NODE'
const fs = require('fs');
const path = require('path');
const release = process.argv[2];
const index = fs.readFileSync(path.join(release, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(release, 'contract.css'), 'utf8');
const app = fs.readFileSync(path.join(release, 'app.js'), 'utf8');
const build = fs.readFileSync(path.join(release, 'site-build.js'), 'utf8');
const preview = 'http://gonka-dev.net/preview/83/';

const relativeAssets = [...index.matchAll(/(?:href|src)="([^"]+)"/g)]
  .map(([, value]) => value)
  .filter((value) => !value.startsWith('/') && !value.startsWith('http') && !value.startsWith('#'));
if (relativeAssets.length === 0) {
  throw new Error('release has no relative local assets');
}
for (const asset of relativeAssets) {
  if (new URL(asset, preview).pathname !== `/preview/83/${asset}`) {
    throw new Error(`preview does not retain local asset ${asset}`);
  }
}
for (const [, asset] of css.matchAll(/url\("([^"]+)"\)/g)) {
  if (!asset.startsWith('http') && !asset.startsWith('/') && new URL(asset, preview).pathname !== `/preview/83/${asset}`) {
    throw new Error(`preview does not retain local CSS asset ${asset}`);
  }
}
if (new URL('config.js', preview).pathname !== '/preview/83/config.js' || !index.includes('src="config.js"')) {
  throw new Error('preview must resolve configuration inside its own generation');
}
if (!app.includes('cfg.statusBase || "/status"')) {
  throw new Error('root static site must retain the production status default');
}
if (!/"revision":"[0-9a-f]{40}"/.test(build) || !/"artifactDigest":"[0-9a-f]{64}"/.test(build) || !/"appDigest":"[0-9a-f]{64}"/.test(build)) {
  throw new Error('release must expose its exact revision, static payload digest and app.js digest');
}
NODE

declared_digest="$(sed -n 's/.*"artifactDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$tmp/site/site-build.js")"
actual_digest="$(bash "$ROOT/scripts/site-static-digest.sh" "$tmp/site")"
[[ "$declared_digest" == "$actual_digest" ]] || {
  echo 'release manifest does not describe the final static payload' >&2
  exit 1
}

printf 'PASS static release resolves local assets below its publication directory\n'
