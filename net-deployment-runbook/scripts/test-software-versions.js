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
assert.equal(versions.normalizeMlNodeVersion('0.2.14', '0.2.0'), '0.2.0');
assert.equal(versions.normalizeMlNodeVersion('0.2.15', '0.2.0'), '0.2.0');
assert.equal(versions.normalizeMlNodeVersion('v0.2.15', '0.2.0'), '0.2.0');
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
  '0.2.0',
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
  ['model:gonka1one: 0.2.0', 'model:gonka1two: 0.2.0'],
);

function sample(component, version, observationTimestamp, source = 'runtime') {
  // /status/software returns max_over_time(timestamp(...)[24h:15s]).
  // `value[0]` is the shared query evaluation time, while `value[1]` is the
  // retained source observation time for the version-labelled series.
  return {
    metric: { component, version, source },
    value: [2000, String(observationTimestamp)],
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
assert.equal(versions.freshInventoryVersion('', upgradeSamples, 'chain', 330, 60), 'v0.2.16');
assert.equal(versions.freshInventoryVersion('', upgradeSamples, 'chain', 1000, 60), '');
assert.equal(versions.freshInventoryVersion('v0.2.16-post1', upgradeSamples, 'chain', 1000, 60), 'v0.2.16-post1');

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

const hardware = {state: 'observed', nodes: [{local_id: 'old', version: '3.0.14-post2'}]};
assert.deepEqual(versions.selectMlNodes({mlnodes: [{node_id: 'current', version: '3.0.16'}]}, hardware), {
  observed: true, source: 'DAPI runtime report', nodes: [{node_id: 'current', version: '3.0.16'}],
});
assert.deepEqual(versions.selectMlNodes({mlnodes: []}, hardware), {
  observed: true, source: 'DAPI runtime report', nodes: [],
});
assert.deepEqual(versions.selectMlNodes({observed_at: '2000-01-01T00:00:00Z', mlnodes: [{node_id: 'stale', version: '3.0.14-post2'}]}, null), {
  observed: false, source: 'No MLNode observation', nodes: [],
});
assert.deepEqual(versions.selectMlNodes({observed_at: '2000-01-01T00:00:00Z', mlnodes: [{node_id: 'stale', version: '3.0.14-post2'}]}, hardware), {
  observed: true, source: 'Chain runtime inventory', nodes: [{node_id: 'old', version: '3.0.14-post2'}],
});
assert.deepEqual(versions.selectMlNodes({}, hardware), {
  observed: true, source: 'Chain runtime inventory', nodes: [{node_id: 'old', version: '3.0.14-post2'}],
});
assert.deepEqual(versions.selectMlNodes(null, {state: 'unavailable', nodes: []}), {
  observed: false, source: 'No MLNode observation', nodes: [],
});
assert.equal(versions.formatMlNodes('v0.2.16-post1',
  versions.selectMlNodes({mlnodes: [{version: '3.0.16'}]}, null).nodes), '3.0.16');

fs.rmSync(siteBuild, { recursive: true, force: true });
console.log('PASS software and per-Host MLNode version display');
