#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

make -C "$ROOT" prepare-static-site site_release_dir="$tmp/site"

node - "$tmp/site" <<'NODE'
const fs = require('fs');
const path = require('path');
const release = process.argv[2];
const index = fs.readFileSync(path.join(release, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(release, 'contract.css'), 'utf8');
const app = fs.readFileSync(path.join(release, 'app.js'), 'utf8');
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
if (new URL('/config.js', preview).pathname !== '/config.js' || !index.includes('src="/config.js"')) {
  throw new Error('preview must retain the root configuration endpoint');
}
if (!app.includes('"/status/participants"') || new URL('/status/participants', preview).pathname !== '/status/participants') {
  throw new Error('preview must retain root status endpoints');
}
NODE

printf 'PASS static release resolves local assets below its publication directory\n'
