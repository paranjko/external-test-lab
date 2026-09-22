#!/usr/bin/env node
const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const siteBuild = fs.mkdtempSync(path.join(os.tmpdir(), 'gdc-site-test-'));
childProcess.execFileSync(
  path.join(__dirname, 'build-site-js.sh'),
  ['--output', siteBuild],
  { stdio: 'inherit' },
);
const versions = require(path.join(siteBuild, 'software-versions.js'));

function state(chain, mlnodes = [], dapi = '0.2.14') {
  return {
    node_version: { version: chain },
    api_version: { version: dapi },
    mlnodes: mlnodes.map(version => ({ version })),
  };
}

assert.equal(
  versions.format(state('0.2.14', ['0.2.0'])),
  'chain 0.2.14 · DAPI 0.2.14',
);
assert.equal(versions.normalizeMlNodeVersion('0.2.14', '0.2.0'), '3.0.14-post2');
assert.equal(versions.normalizeMlNodeVersion('0.2.15', '0.2.0'), '3.0.14-post2');
assert.equal(versions.normalizeMlNodeVersion('v0.2.15', '0.2.0'), '3.0.14-post2');
assert.equal(versions.normalizeMlNodeVersion('0.2.16', '3.0.15'), '3.0.15');
assert.equal(versions.displayVersion('v0.2.15'), '0.2.15');
assert.equal(
  versions.displayVersion('41d765d1bf2b0f2e1c2aa7b131ff5a5da7a6eaebfe8c3276f67478924e466cd5'),
  '41d765',
);
assert.equal(
  versions.format(state('0.2.15', [])),
  'chain 0.2.15 · DAPI 0.2.14',
);
assert.equal(
  versions.format(state('0.2.16', ['3.0.15'])),
  'chain 0.2.16 · DAPI 0.2.14',
);
assert.equal(
  versions.format(state('0.2.16')),
  'chain 0.2.16 · DAPI 0.2.14',
);
assert.equal(
  versions.formatMlNodes('0.2.15', [{ version: '0.2.0' }]),
  '3.0.14-post2',
);
assert.equal(
  versions.formatMlNodes('0.2.16', [
    { version: '3.0.15' },
    { version: '3.0.15' },
    { version: '3.0.16' },
  ]),
  '3.0.15 ×2 · 3.0.16',
);
assert.equal(versions.formatMlNodes('0.2.15', []), '');
assert.deepEqual(
  versions.describeMlNodes('0.2.15', [
    { node_id: 'model:gonka1one', version: '0.2.0' },
    { node_id: 'model:gonka1two', version: '0.2.0' },
  ]),
  ['model:gonka1one: 3.0.14-post2', 'model:gonka1two: 3.0.14-post2'],
);

function sample(component, version, observationTimestamp, source = 'runtime') {
  // /status/software returns max_over_time(timestamp(...)[24h:15s]).
  // value[0] is therefore the source observation time, even though the
  // Prometheus HTTP query itself is evaluated at one shared instant.
  return {
    metric: { component, version, source },
    value: [observationTimestamp, '1'],
  };
}

function selectedVersion(samples, component) {
  return versions.selectLatestInventory(samples).get(component)?.version;
}

const upgradeSamples = [
  sample('inference-chain', 'v0.2.15', 0),
  sample('inference-chain', 'v0.2.16', 300),
];
assert.equal(selectedVersion(upgradeSamples, 'chain'), 'v0.2.16');
assert.equal(selectedVersion([...upgradeSamples].reverse(), 'chain'), 'v0.2.16');

const rollbackSamples = [
  sample('decentralized-api', 'v0.2.16-post1', 0),
  sample('decentralized-api', 'v0.2.15-post3', 300),
];
assert.equal(selectedVersion(rollbackSamples, 'DAPI'), 'v0.2.15-post3');
assert.equal(selectedVersion([...rollbackSamples].reverse(), 'DAPI'), 'v0.2.15-post3');

assert.equal(
  selectedVersion([
    sample('mlnode', 'container-old', 300, 'container'),
    sample('mlnode', 'runtime-current', 300, 'runtime'),
  ], 'MLNode'),
  'runtime-current',
);

assert.equal(
  selectedVersion([
    sample('decentralized-api', '0.2.15-post3', 100, 'container'),
    sample('decentralized-api', 'unreported', 300, 'runtime'),
  ], 'DAPI'),
  '0.2.15-post3',
);

fs.rmSync(siteBuild, { recursive: true, force: true });
console.log('PASS software and per-Host MLNode version display');
