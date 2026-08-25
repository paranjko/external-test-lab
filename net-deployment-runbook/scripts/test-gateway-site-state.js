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
  primaryLabel: 'Effective validator',
  primaryClass: 'status ok',
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
  primaryLabel: 'Not in validator set',
  primaryClass: 'status skip',
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
  primaryLabel: 'Validator data unavailable',
  primaryClass: 'status bad',
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
  primaryLabel: 'Validator data unavailable',
  primaryClass: 'status bad',
  votingPower: 'Unavailable',
  endpointLabel: 'Unavailable – Network error',
  syncLabel: 'Unavailable',
  validatorEffective: false,
});
assert.equal(hostState.classify({
  participantKnown: false,
  endpointState: 'unknown',
}).primaryLabel, 'Participant data unavailable');
assert.equal(hostState.classify({
  participantKnown: true,
  participantStatus: 'INACTIVE',
  validatorKnown: true,
  votingPower: '88',
}).primaryLabel, 'Participant inactive');
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
assert.match(readability, /\.nodes\.compact \{\s*grid-auto-rows: 424px;/);
assert.match(readability, /\.nodes\.compact \.node \{\s*box-sizing: border-box;\s*height: 424px;/);
assert.match(readability, /\.nodes\.compact \.metric \{\s*box-sizing: border-box;/);
assert.match(readability, /\.nodes\.compact \.metric\.software,\s*\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\) \{/);
assert.match(readability, /grid-template-columns: 72px minmax\(0, 1fr\);/);
assert.match(readability, /\.nodes\.compact \.metric\.software \{\s*min-height: 60px;/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\) \{[\s\S]*min-height: 52px;[\s\S]*border-top: 2px solid var\(--line\);/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\) \{\s*grid-template-columns: 28px minmax\(0, 1fr\);/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu b \{\s*overflow-wrap: normal;\s*white-space: nowrap;/);
assert.match(readability, /\.nodes\.compact \.metric\.software b,[\s\S]*white-space: normal;/);
assert.match(readability, /text-overflow: ellipsis/);

fs.rmSync(siteBuild, { recursive: true, force: true });
console.log('PASS gateway public-site state contract');
