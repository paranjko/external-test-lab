#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const siteRoot = process.argv[2];
if (!siteRoot) throw new Error('usage: test-network-selection.js SITE_ROOT');
const script = fs.readFileSync(path.join(siteRoot, 'network-selection.js'), 'utf8');
const chainId = 'gonka-testnet-devshards';
async function select(location) {
  const config = {
    chainId: 'gonka-devnet-community',
    bootstrapOrigin: 'https://bootstrap.example.test',
    nodes: [{ name: 'catalog-only' }],
  };
  const window = { location, GDC_CONFIG: config };
  vm.runInNewContext(script, { window, URLSearchParams, decodeURIComponent, Promise });
  await window.GDC_SITE_CONFIG_READY;
  return { config, error: window.GDC_SITE_CONFIG_ERROR };
}

(async () => {
  for (const location of [
    { search: `?chainId=${chainId}`, hash: '' },
    { search: '', hash: `#chainId=${chainId}` },
  ]) {
    const selected = await select(location);
    assert.equal(selected.error, undefined);
    assert.equal(selected.config.chainId, chainId);
    assert.equal(selected.config.publicBootstrap, true);
    assert.equal(selected.config.model, 'Not reported');
    assert.equal(selected.config.nodes.length, 0);
    assert.equal(selected.config.nodeCatalog.length, 0);
  }
  console.log('PASS selected chain replaces catalog-only configuration before the observer is queried');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
