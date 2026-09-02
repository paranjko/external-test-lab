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
  { cwd: os.tmpdir(), stdio: 'inherit' },
);
const state = require(path.join(siteBuild, 'gateway-state.js'));
const hostState = require(path.join(siteBuild, 'host-state.js'));
const generatedGatewayState = fs.readFileSync(path.join(siteBuild, 'gateway-state.js'), 'utf8');
assert.doesNotMatch(generatedGatewayState, /run make site-js\n\n\n/);
const now = Date.parse('2026-08-06T10:30:00Z');
const readyProbe = { state: 'READY', checked_at: '2026-08-06T10:29:50Z', http_status: 200 };
const failedProbe = { state: 'UNAVAILABLE', checked_at: '2026-08-06T10:29:50Z', http_status: 429 };
const degradedProbe = { state: 'DEGRADED', reason: 'escrow_reserve_low', checked_at: '2026-08-06T10:29:50Z', http_status: 200 };
const recoveringProbe = {
  state: 'RECOVERING', reason: 'waiting_for_versiond_session', checked_at: '2026-08-06T10:29:50Z', http_status: 0,
  recovery: { stage: 'waiting_for_versiond_session', escrow_id: '123', started_at: '2026-08-06T10:29:40Z', next_check_seconds: 15 },
};

const activeShard = {
  id: '52',
  active: true,
  phase: 'active',
  requests_blocked: false,
  chain_phase: 'Inference',
};

assert.deepEqual(state.classify(undefined, 0), {
  state: 'OFFLINE',
  available: false,
  message: 'Network reset – no nodes online',
});

assert.equal(state.classify({ mode: 'gateway', runtimes: 0, devshards: [] }, 1, readyProbe, now).state, 'PENDING');
assert.deepEqual(state.classify({ mode: 'gateway', runtimes: 0, devshards: [] }, 1, {
  ...failedProbe,
  reason: 'replacement_escrow_creation_failed',
}, now), {
  state: 'UNAVAILABLE',
  available: false,
  message: 'Gateway unavailable – replacement escrow creation failed',
});
assert.equal(state.classify({ mode: 'gateway', runtimes: 1, devshards: [] }, 1, readyProbe, now).state, 'UNAVAILABLE');
assert.deepEqual(state.classify({ mode: 'gateway', runtimes: 1, devshards: [] }, 1, recoveringProbe, now), {
  state: 'RECOVERING', available: false,
  message: 'Escrow #123 is active – waiting for its versiond inference session – next check within 15 seconds',
  startedAt: '2026-08-06T10:29:40Z',
});
assert.equal(state.recoveryMessage({
  state: 'RECOVERING', reason: 'waiting_for_chain_confirmation',
  recovery: { escrow_id: '124', next_check_seconds: 15 },
}), 'Escrow #124 was submitted – waiting for chain confirmation – next check within 15 seconds');

const zeroCapacity = {
  mode: 'gateway',
  runtimes: 6,
  capacity: { total_weight: 0, baseline_weight: 438, lost_weight: 438, available_percent: 0 },
  devshards: [{ ...activeShard, chain_phase: 'PoCValidate', block_reason: 'poc' }],
};
assert.equal(state.classify(zeroCapacity, 1, failedProbe, now).state, 'UNAVAILABLE');
assert.deepEqual(state.classify(zeroCapacity, 1, readyProbe, now), {
  state: 'UNAVAILABLE',
  available: false,
  message: 'Gateway unavailable – no current eligible inference capacity',
});

const liveCapacity = {
  ...zeroCapacity,
  capacity: { total_weight: 468, baseline_weight: 468, lost_weight: 0, available_percent: 100 },
  devshards: [activeShard],
};
assert.equal(state.classify(liveCapacity, 1, readyProbe, now).state, 'AVAILABLE');
assert.equal(state.classify(liveCapacity, 1, readyProbe, now).available, true);
assert.equal(state.classify(liveCapacity, 1, failedProbe, now).state, 'UNAVAILABLE');
assert.equal(state.classify(liveCapacity, 1, degradedProbe, now).state, 'UNAVAILABLE');
assert.equal(state.classify(liveCapacity, 1, { ...readyProbe, checked_at: '2026-08-06T10:28:00Z' }, now).state, 'UNAVAILABLE');

const legacy = { escrow_id: '7', phase: 'active', requests_blocked: false };
assert.equal(state.classify(legacy, 1, readyProbe, now).state, 'AVAILABLE');

assert.deepEqual(hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: true,
  votingPower: '42',
  endpointState: 'reachable',
  catchingUp: false,
  blocksBehind: 0,
  blockAgeSeconds: 12,
  progressing: true,
  referenceKnown: true,
  referenceAgrees: true,
}), {
  state: 'validating',
  stateLabel: 'Validating',
  reason: 'Effective and synchronized validator',
  primaryLabel: 'Validating',
  primaryClass: 'status validating',
  votingPower: '42',
  endpointLabel: 'Reachable',
  syncLabel: 'Synced',
  validatorEffective: true,
});
assert.deepEqual(hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: true,
  votingPower: '0',
  endpointState: 'reachable',
  catchingUp: true,
  blocksBehind: 17,
  blockAgeSeconds: 12,
  progressing: true,
  referenceKnown: true,
  referenceAgrees: true,
}), {
  state: 'active',
  stateLabel: 'Active',
  reason: 'Not in validator set',
  primaryLabel: 'Active',
  primaryClass: 'status active',
  votingPower: '0',
  endpointLabel: 'Reachable',
  syncLabel: 'Lagging – 17 blocks',
  validatorEffective: false,
});
assert.deepEqual(hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: false,
  endpointState: 'unavailable',
  endpointDiagnostic: 'HTTP 502',
}), {
  state: 'unknown',
  stateLabel: 'Unknown',
  reason: 'Validator data unavailable',
  primaryLabel: 'Unknown',
  primaryClass: 'status unknown',
  votingPower: 'Unavailable',
  endpointLabel: 'Unavailable – HTTP 502',
  syncLabel: 'Unavailable',
  validatorEffective: false,
});
assert.deepEqual(hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: false,
  endpointState: 'unavailable',
  endpointDiagnostic: 'Network error',
}), {
  state: 'unknown',
  stateLabel: 'Unknown',
  reason: 'Validator data unavailable',
  primaryLabel: 'Unknown',
  primaryClass: 'status unknown',
  votingPower: 'Unavailable',
  endpointLabel: 'Unavailable – Network error',
  syncLabel: 'Unavailable',
  validatorEffective: false,
});
assert.equal(hostState.classify({
  participantKnown: false,
  endpointState: 'unknown',
}).primaryLabel, 'Unknown');
assert.equal(hostState.classify({
  participantKnown: true,
  participantStatus: 'INACTIVE',
  validatorKnown: true,
  votingPower: '88',
}).primaryLabel, 'Inactive');
const node2Inactive = hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: true,
  votingPower: '0',
  endpointState: 'reachable',
  catchingUp: false,
  blocksBehind: 0,
  blockAgeSeconds: 1,
  progressing: true,
  referenceKnown: true,
  referenceAgrees: true,
});
assert.equal(node2Inactive.state, 'active');
assert.equal(node2Inactive.stateLabel, 'Active');
assert.equal(node2Inactive.primaryClass, 'status active');
assert.equal(node2Inactive.reason, 'Not in validator set');
const activeButStale = hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: true,
  votingPower: '42',
  endpointState: 'reachable',
  catchingUp: false,
  blocksBehind: 0,
  blockAgeSeconds: 120,
  progressing: false,
  referenceKnown: true,
  referenceAgrees: true,
});
assert.equal(activeButStale.state, 'active');
assert.equal(activeButStale.stateLabel, 'Active');
assert.equal(activeButStale.primaryClass, 'status active');
assert.equal(hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: true,
  votingPower: '42',
  endpointState: 'reachable',
  catchingUp: false,
  blocksBehind: 7000,
  blockAgeSeconds: 36000,
  progressing: false,
  referenceKnown: true,
  referenceAgrees: true,
}).syncLabel, 'Lagging – 7,000 blocks');
assert.equal(hostState.classify({
  endpointState: 'reachable',
  catchingUp: false,
  blocksBehind: 0,
  blockAgeSeconds: 91,
  progressing: false,
  referenceKnown: true,
  referenceAgrees: true,
}).syncLabel, 'Stale');
assert.equal(hostState.classify({
  endpointState: 'reachable',
  catchingUp: false,
  blocksBehind: 0,
  blockAgeSeconds: 5,
  progressing: true,
  referenceKnown: false,
}).syncLabel, 'Unknown');
assert.equal(hostState.classify({
  endpointState: 'reachable',
  catchingUp: false,
  blocksBehind: 0,
  blockAgeSeconds: 5,
  progressing: true,
  referenceKnown: true,
  referenceAgrees: false,
}).syncLabel, 'Unknown');
assert.equal(hostState.endpointDiagnostic(new Error('502')), 'HTTP 502');
assert.equal(hostState.endpointDiagnostic(new Error('Failed to fetch')), 'Network error');
assert.equal(hostState.endpointDiagnostic(new Error('timeout exceeded')), 'Timed out');

const siteApp = fs.readFileSync(path.join(siteBuild, 'app.js'), 'utf8');
assert.match(siteApp, /READY – verified inference; processing requests/);
assert.match(siteApp, /READY – verified inference; no requests in flight/);
assert.match(siteApp, /quality-recovery/);
assert.match(siteApp, /document\.createElement\(["']time["']\)/);
assert.match(siteApp, /started.*UTC/);
assert.match(siteApp, /cloudflare-dns\.com\/dns-query/);
assert.match(siteApp, /ipwho\.is/);
assert.match(siteApp, /statusBase:\s*`https:\/\/\$\{host\}`/);
assert.match(siteApp, /json\("\/status\/gpus"\)/);
assert.match(siteApp, /sample\?\.metric\?\.gpu_name/);
assert.match(siteApp, /node\.gpuHost && node\.gpuHost !== node\.name \? "net" : "local"/);
assert.match(siteApp, /const gpuHost = node\.gpuHost \|\| node\.name/);
assert.match(siteApp, /const inventoryKey = \[gpuHost, node\.publicHost, node\.name\]/);
assert.match(siteApp, /configuredGpuLabel\(node\.gpuProfile\)/);
assert.match(siteApp, /RTX PRO 2000 Blackwell/);
assert.match(siteApp, /inventory unavailable/);
assert.match(siteApp, /\$\{inventoryLabel\} – \$\{connection\}/);
assert.match(siteApp, /replace\(\/\^NVIDIA\\s\+\/i, ""\)/);
assert.match(
  siteApp,
  /participantNode\(participant, validators, validatorKnown\)/,
);
assert.match(siteApp, /hostState\.classify/);
assert.match(siteApp, /GDC_SOFTWARE_VERSIONS\.normalizeMlNodeVersion/);
assert.match(siteApp, /data-k="vp"/);
assert.match(siteApp, /<span>voting power<\/span>/);
assert.match(siteApp, /class="metric software" data-k-row="software"/);
assert.match(siteApp, /class="metric gpu" data-k-row="gpu" hidden/);
assert.match(siteApp, /data-k="endpoint"/);
assert.match(siteApp, /Promise\.allSettled/);
assert.match(siteApp, /participantKnown: false/);
assert.match(siteApp, /validatorKnown: false/);
assert.match(siteApp, /Array\.isArray\(validatorResult\.value\?\.result\?\.validators\)/);
assert.match(siteApp, /validatorEffective/);
assert.match(siteApp, /catchingUp/);
assert.match(siteApp, /blockAgeSeconds/);
assert.match(siteApp, /referenceKnown/);
assert.match(siteApp, /chain-rpc\/status/);
assert.doesNotMatch(siteApp, /waiting for validator set/);
assert.doesNotMatch(siteApp, /effective validator – endpoint/);
assert.doesNotMatch(siteApp, /\$\{display\.text\} \(\$\{e\.message\}\)/);
assert.doesNotMatch(siteApp, /quality-health-state'\)\.textContent=state\.toUpperCase/);

const readability = fs.readFileSync(
  path.join(__dirname, '..', '04-ops', 'site', 'readability.css'),
  'utf8',
);
const mapFixture = fs.readFileSync(
  path.join(__dirname, 'test-validator-map-fixture.mjs'),
  'utf8',
);
const homepageCapture = fs.readFileSync(
  path.join(__dirname, 'capture-homepage-viewport.mjs'),
  'utf8',
);
assert.match(readability, /\.nodes\.compact \{[\s\S]*grid-template-columns: repeat\(4, minmax\(0, 1fr\)\);[\s\S]*grid-auto-rows: 424px;/);
assert.match(
  readability,
  /\.nodes\.compact \.node \{[\s\S]*box-sizing: border-box;[\s\S]*height: 424px;[\s\S]*min-height: 424px;[\s\S]*max-height: 424px;[\s\S]*overflow: hidden;/,
);
assert.match(readability, /\.nodes\.compact \.node h3 \{[\s\S]*max-height: 44px;[\s\S]*overflow: hidden;/);
assert.match(readability, /\.nodes\.compact \.node > small \{[\s\S]*max-height: 30px;[\s\S]*overflow: hidden;/);
assert.match(readability, /\.nodes\.compact \.status \{[\s\S]*max-height: 24px;[\s\S]*overflow: hidden;/);
assert.match(readability, /\.nodes\.compact \.metric \{\s*box-sizing: border-box;[\s\S]*max-height: none;[\s\S]*align-items: flex-start;/);
assert.match(readability, /\.nodes\.compact \.metric\.software,\s*\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\) \{/);
assert.match(readability, /grid-template-columns: 72px minmax\(0, 1fr\);/);
assert.match(readability, /\.nodes\.compact \.metric\.software \{\s*min-height: 24px;\s*margin-top: 0;\s*padding: 3px 0;/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\) \{\s*min-height: 24px;\s*margin-top: 0;\s*padding: 3px 0;\s*border-top-width: 1px;/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\) \{\s*grid-template-columns: 28px minmax\(0, 1fr\);/);
assert.match(readability, /\.nodes\.compact \.metric\.software b,[\s\S]*\.nodes\.compact \.metric\.gpu b \{[\s\S]*font-size: 9px;[\s\S]*overflow: hidden;[\s\S]*overflow-wrap: anywhere;[\s\S]*text-overflow: clip;[\s\S]*white-space: normal;/);
assert.match(readability, /\.nodes\.compact \.metric b \{[\s\S]*flex: 1 1 auto;[\s\S]*overflow: hidden;[\s\S]*overflow-wrap: anywhere;[\s\S]*text-overflow: clip;[\s\S]*white-space: normal;/);
assert.match(readability, /@media \(max-width: 700px\) \{[\s\S]*\.nodes\.compact \{[\s\S]*grid-template-columns: 1fr;/);
assert.match(readability, /@media \(max-width: 1320px\) and \(min-width: 1101px\) \{[\s\S]*\.nodes\.compact \{[\s\S]*grid-template-columns: repeat\(3, minmax\(0, 1fr\)\);/);
assert.match(readability, /@media \(max-width: 1100px\) and \(min-width: 701px\) \{[\s\S]*\.nodes\.compact \{[\s\S]*grid-template-columns: repeat\(2, minmax\(0, 1fr\)\);/);
assert.match(mapFixture, /name: "fixture-dynamic",\s*mode: "skip",\s*reason: "fixture skip path"/);
assert.match(mapFixture, /\[1101, 720\][\s\S]*\[1100, 720\][\s\S]*\[701, 720\][\s\S]*\[700, 720\][\s\S]*\[521, 720\][\s\S]*\[390, 844\]/);
assert.match(mapFixture, /\[1280, 1101, 1100, 701, 700, 521, 390\]\.includes\(width\)/);
assert.match(mapFixture, /skippedGpu\.hidden[\s\S]*skippedGpu\.text === ""[\s\S]*skippedGpu\.clientHeight === 0/);
assert.match(homepageCapture, /return value && \{[\s\S]*width: value\.width,[\s\S]*height: value\.height/);

fs.rmSync(siteBuild, { recursive: true, force: true });
console.log('PASS gateway public-site state contract');
