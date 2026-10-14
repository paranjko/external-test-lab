#!/usr/bin/env node
const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const siteBuild = fs.mkdtempSync(path.join(os.tmpdir(), 'gdc-stable-site-test-'));
process.on('exit', () => fs.rmSync(siteBuild, {recursive: true, force: true}));
childProcess.execFileSync(
  path.join(__dirname, 'build-site-js.sh'),
  ['--output', siteBuild],
  {cwd: siteBuild, stdio: 'inherit'},
);
const state = require(path.join(siteBuild, 'gateway-state.js'));
const now = 200000;
const admission = {available: true, gateway: 'A', model: 'model', protocol: 'v6'};
const probe = {
  contract: 'stable_native_observation', schema_version: 1,
  state: 'OBSERVED', readiness: 'STABLE_OBSERVED',
  reason: 'stable_completion_with_native_accounting_increment',
  checked_at: new Date(now - 1000).toISOString(), finished_ms: now - 1000,
  gateway: 'A', model: 'model', protocol: 'v6', request_id: 'native-request',
  escrow_id: '123', finished_used_delta: 1, exclusive_attribution_proven: false,
};
const classify = (value = probe, binding = admission, healthy = 1) =>
  state.classify(null, healthy, value, now, 30000, binding);
assert.equal(classify().state, 'STABLE_OBSERVED');
assert.equal(classify().available, false);
assert.match(classify().message, /exclusive attribution is not verified/);
for (const change of [
  {schema_version: 2}, {state: 'READY'}, {readiness: 'TRAFFIC_READY'},
  {exclusive_attribution_proven: true}, {finished_used_delta: 2},
  {request_id: ''}, {escrow_id: 'other'}, {model: ''}, {gateway: 'S'},
  {protocol: 'v5'}, {finished_ms: now + 1}, {finished_ms: now - 30001},
  {checked_at: new Date(now - 30001).toISOString()},
]) assert.equal(classify({...probe, ...change}).state, 'UNAVAILABLE', JSON.stringify(change));
for (const binding of [null, {}, {...admission, gateway: 'B'},
  {...admission, model: 'other'}, {...admission, available: false, reason: 'poc_fence'}]) {
  assert.equal(classify(probe, binding).state, 'UNAVAILABLE');
}
assert.equal(classify(probe, admission, 0).state, 'OFFLINE');
assert.match(classify(probe, {...admission, available: false, reason: 'poc_fence'}).message, /poc fence/);
console.log('PASS stable observation site contract (never TRAFFIC_READY)');
