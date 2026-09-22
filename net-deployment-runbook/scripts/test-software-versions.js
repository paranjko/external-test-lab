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
  'chain 0.2.14 · DAPI 0.2.14 · MLNode 3.0.14-post2',
);
assert.equal(versions.normalizeMlNodeVersion('0.2.14', '0.2.0'), '3.0.14-post2');
assert.equal(versions.normalizeMlNodeVersion('0.2.15', '0.2.0'), '3.0.14-post2');
assert.equal(versions.normalizeMlNodeVersion('0.2.16', '3.0.15'), '3.0.15');
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

fs.rmSync(siteBuild, { recursive: true, force: true });
console.log('PASS temporary MLNode release display workaround');
