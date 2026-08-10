#!/usr/bin/env node
const assert = require('node:assert/strict');
const versions = require('../04-ops/site/software-versions.js');

function state(chain, mlnodes = [], dapi = '0.2.14') {
  return {
    node_version: { version: chain },
    api_version: { version: dapi },
    mlnodes: mlnodes.map(version => ({ version })),
  };
}

assert.equal(
  versions.format(state('0.2.14', ['0.2.0'])),
  'chain 0.2.14 · DAPI 0.2.14 · MLNode 3.0.14-post2',
);
assert.equal(
  versions.format(state('0.2.15', [])),
  'chain 0.2.15 · DAPI 0.2.14 · MLNode 3.0.14-post2',
);
assert.equal(
  versions.format(state('0.2.16', ['3.0.15'])),
  'chain 0.2.16 · DAPI 0.2.14 · MLNode 3.0.15',
);
assert.equal(
  versions.format(state('0.2.16')),
  'chain 0.2.16 · DAPI 0.2.14 · MLNode unreported',
);

console.log('PASS temporary MLNode release display workaround');
