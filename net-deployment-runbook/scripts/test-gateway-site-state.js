#!/usr/bin/env node
const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const temporaryRoot = process.env.TMPDIR || path.join(__dirname, '..', '..', '.data', 'preview-tmp');
fs.mkdirSync(temporaryRoot, { recursive: true });
const siteBuild = fs.mkdtempSync(path.join(temporaryRoot, 'gdc-site-test-'));
childProcess.execFileSync(
  path.join(__dirname, 'build-site-js.sh'),
  ['--output', siteBuild],
  { cwd: temporaryRoot, stdio: 'inherit' },
);
const state = require(path.join(siteBuild, 'gateway-state.js'));
const softwareIdentity = require(path.join(siteBuild, 'software-versions.js'));
const observedRuntime = {metric:{host:'fixture',slot:'v5',source:'process',version:'v5.0.2',binary_sha256:'b'.repeat(64),archive_sha256:'c'.repeat(64)},value:[9999,'1000']};
const selectRuntime = (samples, timestamp=1001) => softwareIdentity.selectDevShardIdentity(samples,'fixture',timestamp);
assert.equal(selectRuntime([observedRuntime]).get('v5').binarySha256,'b'.repeat(64));
assert.equal(selectRuntime([observedRuntime]).get('v5').archiveSha256,'c'.repeat(64));
assert.equal(selectRuntime([observedRuntime],1091).size,0);
assert.equal(selectRuntime([observedRuntime],999).size,0);
assert.equal(selectRuntime([observedRuntime,observedRuntime]).size,0);
for (const override of [{host:'other'},{source:'container'},{version:'v5'},{binary_sha256:'installed'},{slot:'v6'}]) {
  assert.equal(selectRuntime([{...observedRuntime,metric:{...observedRuntime.metric,...override}}]).size,0);
}
const hostState = require(path.join(siteBuild, 'host-state.js'));
const generatedGatewayState = fs.readFileSync(path.join(siteBuild, 'gateway-state.js'), 'utf8');
assert.doesNotMatch(generatedGatewayState, /run make site-js\n\n\n/);
const now = Date.parse('2026-08-06T10:30:00Z');
const readyProbe = { state: 'READY', checked_at: '2026-08-06T10:29:50Z', http_status: 200 };
const trafficReadyProbe = {
  ...readyProbe, readiness: 'TRAFFIC_READY', reason: 'completion_succeeded',
  completion_finished_ms: now - 1000, admission: 'dispatched_once',
  admission_id: '0123456789abcdef0123456789abcdef',
  safe_generation: `sha256:${'a'.repeat(64)}`,
  arrival_height: 100, permit_height: 101, dispatch_height: 101, response_height: 102,
};
const unknownReadinessProbe = { ...readyProbe, readiness: 'FUTURE_READY' };
const arrayReadinessProbe = { ...readyProbe, readiness: ['TRAFFIC_READY'] };
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

assert.equal(state.classify({ mode: 'gateway', runtimes: 0, devshards: [] }, 1, readyProbe, now).state, 'UNAVAILABLE');
assert.deepEqual(state.classify({ mode: 'gateway', runtimes: 0, devshards: [] }, 1, {
  ...failedProbe,
  reason: 'replacement_escrow_creation_failed',
}, now), {
  state: 'UNAVAILABLE',
  available: false,
  message: 'Gateway unavailable – replacement escrow creation failed',
});
assert.equal(state.classify({ mode: 'gateway', runtimes: 1, devshards: [] }, 1, readyProbe, now).state, 'UNAVAILABLE');
assert.deepEqual(state.classify({ mode: 'gateway', runtimes: 1, devshards: [activeShard] }, 1, unknownReadinessProbe, now), {
  state: 'UNAVAILABLE', available: false,
  message: 'Gateway unavailable – traffic readiness is unknown',
});
assert.deepEqual(state.classify({ mode: 'gateway', runtimes: 1, devshards: [activeShard] }, 1, arrayReadinessProbe, now), {
  state: 'UNAVAILABLE', available: false,
  message: 'Gateway unavailable – traffic readiness is unknown',
});
assert.equal(state.classify({ mode: 'gateway', runtimes: 1, devshards: [{ ...activeShard, requests_blocked: null }] }, 1, trafficReadyProbe, now).state, 'UNAVAILABLE');
assert.equal(state.classify({ mode: 'gateway', runtimes: 1, devshards: [{ ...activeShard, active: 'true' }] }, 1, trafficReadyProbe, now).state, 'UNAVAILABLE');
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
assert.deepEqual(state.classify(zeroCapacity, 1, trafficReadyProbe, now), {
  state: 'UNAVAILABLE',
  available: false,
  message: 'Gateway unavailable – no current eligible inference capacity',
});
assert.deepEqual(state.classify({ ...zeroCapacity, capacity: { total_weight: 468 } }, 1, readyProbe, now, 30000, {
  available: false, reason: 'runtime_unavailable',
}), {
  state: 'UNAVAILABLE',
  available: false,
  message: 'Gateway unavailable – runtime unavailable',
});
assert.deepEqual(state.classify(zeroCapacity, 1, trafficReadyProbe, now, 30000, {
  available: true,
}), {
  state: 'UNAVAILABLE',
  available: false,
  message: 'Gateway unavailable – no current eligible inference capacity',
});

const liveCapacity = {
  ...zeroCapacity,
  capacity: { total_weight: 468, baseline_weight: 468, lost_weight: 0, available_percent: 100 },
  devshards: [activeShard],
};
assert.equal(state.classify(liveCapacity, 1, readyProbe, now).state, 'UNAVAILABLE');
assert.equal(state.classify(liveCapacity, 1, readyProbe, now).available, false);
assert.equal(state.classify(liveCapacity, 1, trafficReadyProbe, now).state, 'TRAFFIC_READY');
assert.deepEqual(state.classify(liveCapacity, 1, { ...trafficReadyProbe, admission_id: '' }, now), {
  state: 'UNAVAILABLE', available: false,
  message: 'Gateway unavailable – traffic receipt is incomplete',
});
assert.deepEqual(state.classify(liveCapacity, 1, { ...trafficReadyProbe, completion_finished_ms: now + 1 }, now), {
  state: 'UNAVAILABLE', available: false,
  message: 'Gateway unavailable – traffic receipt is incomplete',
});
assert.equal(state.classify(liveCapacity, 1, { ...trafficReadyProbe, permit_height: 99 }, now).state, 'UNAVAILABLE');
assert.equal(state.classify(liveCapacity, 1, readyProbe, now).state, 'UNAVAILABLE');
assert.equal(state.classify(liveCapacity, 1, readyProbe, now).available, false);
assert.equal(state.classify(liveCapacity, 1, unknownReadinessProbe, now).state, 'UNAVAILABLE');
const gatewaySiteSource = fs.readFileSync(path.join(__dirname, '..', '04-ops/site/src/app.js'), 'utf8');
assert.equal((gatewaySiteSource.match(/availability\.state !== "TRAFFIC_READY"/g) || []).length, 2);
assert.equal((gatewaySiteSource.match(/availability\.available !== true/g) || []).length, 2);
assert.equal(state.classify(liveCapacity, 1, { ...readyProbe, readiness: 'CONTROL_READY' }, now).state, 'CONTROL_READY');
assert.equal(state.classify(liveCapacity, 1, { ...readyProbe, readiness: 'ROUTING_READY' }, now).state, 'ROUTING_READY');
assert.equal(state.classify(liveCapacity, 1, { ...readyProbe, readiness: 'SATURATED' }, now).state, 'SATURATED');
assert.equal(state.classify(liveCapacity, 1, failedProbe, now).state, 'UNAVAILABLE');
assert.equal(state.classify(liveCapacity, 1, degradedProbe, now).state, 'UNAVAILABLE');
assert.equal(state.classify(liveCapacity, 1, { ...readyProbe, checked_at: '2026-08-06T10:28:00Z' }, now).state, 'UNAVAILABLE');

const legacy = { escrow_id: '7', phase: 'active', requests_blocked: false };
assert.equal(state.classify(legacy, 1, trafficReadyProbe, now).state, 'TRAFFIC_READY');

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
  state: 'inactive',
  stateLabel: 'Inactive',
  reason: 'Public endpoint unavailable',
  primaryLabel: 'Inactive',
  primaryClass: 'status inactive',
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
  state: 'inactive',
  stateLabel: 'Inactive',
  reason: 'Public endpoint unavailable',
  primaryLabel: 'Inactive',
  primaryClass: 'status inactive',
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
assert.equal(hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: true,
  votingPower: '0',
  endpointState: 'unavailable',
  endpointDiagnostic: 'HTTP 502',
}).primaryLabel, 'Inactive');
assert.deepEqual(hostState.classify({
  participantKnown: true,
  participantStatus: 'ACTIVE',
  validatorKnown: true,
  votingPower: '42',
  endpointState: 'unknown',
}), {
  state: 'unknown',
  stateLabel: 'Unknown',
  reason: 'Endpoint status is being checked',
  primaryLabel: 'Unknown',
  primaryClass: 'status unknown',
  votingPower: '42',
  endpointLabel: 'Unknown',
  syncLabel: 'Unknown',
  validatorEffective: false,
});
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
assert.match(siteApp, /TRAFFIC_READY – verified inference; processing requests/);
assert.match(siteApp, /TRAFFIC_READY – verified inference; no requests in flight/);
assert.match(siteApp, /quality-recovery/);
assert.match(siteApp, /document\.createElement\(["']time["']\)/);
assert.match(siteApp, /started.*UTC/);
assert.match(siteApp, /cloudflare-dns\.com\/dns-query/);
assert.match(siteApp, /ipwho\.is/);
assert.match(siteApp, /DYNAMIC_STATUS_HOST/);
assert.match(siteApp, /DYNAMIC_STATUS_HOST\.test\(host\)/);
assert.match(
  siteApp,
  /DYNAMIC_STATUS_HOST\.test\(host\) \|\| !catalog \|\| !catalog\.ip \|\| !catalog\.geo/,
);
assert.match(siteApp, /ip: discovered\.ip \|\| catalog\?\.ip \|\| ""/);
assert.match(siteApp, /geo: discovered\.geo \|\| catalog\?\.geo \|\| null/);
assert.match(siteApp, /`\$\{statusBase\}\/\$\{host\}`/);
assert.match(siteApp, /json\(statusUrl\("\/gpus"\)\)/);
assert.match(siteApp, /json\(statusUrl\("\/software"\)\)/);
assert.match(siteApp, /previewPrefix \? `\$\{previewPrefix\}\/status`/);
assert.match(siteApp, /const previewHostMatch/);
assert.match(siteApp, /const previewNumber = previewMatch\?\.\[1\] \|\| previewHostMatch\?\.\[1\] \|\| ""/);
assert.match(siteApp, /const footerGithub = \$\("footer-github"\)/);
assert.match(siteApp, /https:\/\/github\.com\/paranjko\/external-test-lab\/pull\/\$\{previewNumber\}/);
assert.match(siteApp, /async function readSoftwareVersions\(statusBase\)/);
assert.match(siteApp, /\\b\(\?:503\|504\)\\b/);
assert.match(siteApp, /const versionsRequest = readSoftwareVersions\(statusBase\)/);
assert.match(siteApp, /sample\?\.metric\?\.gpu_name/);
assert.match(siteApp, /const networkAttached = \(hardware\?\.nodes \|\| \[\]\)\.some/);
assert.match(siteApp, /host !== node\.ip/);
assert.match(siteApp, /\? "network"\s*:\s*"local"/);
assert.match(siteApp, /const gpuHost = node\.gpuHost \|\| node\.name/);
assert.match(siteApp, /const inventoryKey = \[gpuHost, node\.publicHost, node\.name\]/);
assert.match(siteApp, /hardware_nodes\/\$\{encodeURIComponent\(address\)\}/);
assert.match(siteApp, /function refreshHardwareInventory/);
assert.match(siteApp, /function reportedSoftwareMetadata/);
assert.match(siteApp, /function softwareInventoryKeys/);
assert.match(siteApp, /\^\(\?:gdc-\)\?\(node\[0-9\]\+\)/);
assert.match(siteApp, /keys\.add\(`gdc-\$\{match\[1\]\}`\)/);
assert.match(siteApp, /reportedSoftwareMetadata\(node, component\)\n\s*\? "Version unavailable"/);
assert.match(siteApp, /Current on-chain runtime inventory/);
assert.match(siteApp, /fullGpuValue\.length > 42/);
assert.match(siteApp, /inventoryLabel\.slice\(0, 30\)\.trimEnd\(\)\}… – \$\{connection\}/);
assert.match(siteApp, /Chain runtime inventory reports no GPU for this participant/);
assert.match(siteApp, /Chain runtime inventory reports no MLNode for this participant/);
assert.match(siteApp, /\$\{inventoryLabel\} – \$\{connection\}/);
assert.match(siteApp, /replace\(\/\^NVIDIA\\s\+\/i, ""\)/);
assert.match(
  siteApp,
  /participantNode\(participant, validators, validatorKnown\)/,
);
assert.match(siteApp, /function topologyHosts\(status, netInfo\)/);
assert.match(siteApp, /function participantForTopologyHost\(/);
assert.match(siteApp, /topologyStatusResult\.status === "fulfilled"/);
assert.match(siteApp, /topologyHost\(status\?\.result\?\.node_info\?\.listen_addr\)/);
assert.match(siteApp, /const observedTopologyHosts/);
assert.match(siteApp, /const hosts = observedParticipantHosts\(participants, observedTopologyHosts\)/);
const discoveryFunctions = siteApp.slice(
  siteApp.indexOf('function topologyHost('),
  siteApp.indexOf('async function reconcileParticipants('),
);
const discoveredHosts = new Function('DYNAMIC_STATUS_HOST', `${discoveryFunctions}; return observedParticipantHosts;`)(/^node[0-9]+\.gonka-dev\.net$/i);
const registry = [
  { inference_url: 'https://node5.gonka-dev.net' },
  { inference_url: 'https://node8.gonka-dev.net' },
  { inference_url: 'https://node5.gonka-dev.net' },
];
assert.deepEqual(discoveredHosts(registry, ['node4.gonka-dev.net']), [
  'node4.gonka-dev.net', 'node5.gonka-dev.net', 'node8.gonka-dev.net',
]);
assert.deepEqual(discoveredHosts(registry, []), ['node5.gonka-dev.net', 'node8.gonka-dev.net']);
assert.deepEqual(discoveredHosts([...registry, { inference_url: 'https://node9.gonka-dev.net' }], []), [
  'node5.gonka-dev.net', 'node8.gonka-dev.net', 'node9.gonka-dev.net',
]);
assert.match(siteApp, /hostState\.classify/);
assert.match(siteApp, /GDC_SOFTWARE_VERSIONS\.formatMlNodes/);
assert.match(siteApp, /data-k="vp"/);
assert.match(siteApp, /<span>voting power<\/span>/);
assert.match(siteApp, /class="metric inferenced" data-k-row="inferenced"/);
assert.match(siteApp, /class="metric dapi" data-k-row="dapi"/);
assert.match(siteApp, /class="metric devshard" data-k-row="devshard"/);
assert.match(siteApp, /json\(`\$\{statusBase\}\/devshard\/healthz`\)/);
assert.match(siteApp, /function updateDevShards/);
assert.match(siteApp, /class="metric gpu" data-k-row="gpu" hidden/);
assert.match(siteApp, /class="metric mlnodes" data-k-row="mlnodes" hidden/);
assert.match(siteApp, /<span>MLNodes<\/span>/);
assert.match(siteApp, /function updateMlNodes/);
assert.match(siteApp, /formatMlNodes/);
assert.match(siteApp, /\$\("devshard-versions"\)/);
assert.match(siteApp, /refreshDevShardVersions/);
assert.match(siteApp, /approved_versions/);
assert.match(
  fs.readFileSync(path.join(__dirname, '..', '04-ops/site/src/host-state.js'), 'utf8'),
  /Public endpoint unavailable/,
);
assert.match(siteApp, /function hostCardCapacity\(totalCards\)/);
assert.match(siteApp, /width < 1200 \? 2 : 4/);
assert.match(siteApp, /minimumExpandedWidth = 270/);
assert.match(siteApp, /class="node-toggle"/);
assert.match(siteApp, /aria-expanded="false"/);
assert.match(siteApp, /class="node-details"/);
assert.match(siteApp, /function activateHostCard\(key\)/);
assert.match(siteApp, /event.key === "ArrowRight"/);
assert.match(siteApp, /deck.dataset.expandedCount/);
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
assert.match(siteApp, /\$\{statusBase\}\/health/);
assert.match(siteApp, /function markerStateCounts\(validators/);
assert.match(siteApp, /function markerGroupState\(counts/);
assert.match(siteApp, /label:\s*states\.length > 1 \? "Mixed"/);
assert.match(siteApp, /function markerRadius\(count/);
assert.match(siteApp, /7\.5 \* Math\.sqrt\(count\)/);
assert.match(siteApp, /function maidenheadLocator\(latitude/);
assert.match(siteApp, /function markerFill\(counts/);
assert.match(siteApp, /conic-gradient/);
assert.match(siteApp, /L\.divIcon/);
assert.match(siteApp, /class="validator-map-summary"/);
assert.match(siteApp, /<details class="validator-map-location-evidence">/);
assert.match(siteApp, /const popupNodeLabel = `\$\{nodeLabel\} at this location`/);
assert.doesNotMatch(siteApp, /validator-marker-number/);
assert.doesNotMatch(siteApp, /let popupOpen = false/);
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
assert.match(
  readability,
  /\.nodes\.compact \{[\s\S]*display: flex;[\s\S]*align-items: flex-start;[\s\S]*height: auto;[\s\S]*min-height: 350px;[\s\S]*overflow-x: auto;[\s\S]*overflow-y: hidden;[\s\S]*overscroll-behavior-x: contain;/,
);
assert.match(readability, /\.validator-map-encoding-note/);
assert.match(readability, /\.validator-marker-face[\s\S]*background: var\(--validator-marker-fill\)/);
assert.match(readability, /\.validator-map \.leaflet-popup-pane \{ z-index: 1200 !important; \}/);
assert.match(readability, /\.validator-map-tooltip \{ position: fixed; z-index: 20000;/);
assert.match(readability, /\.validator-map-tooltip \{[\s\S]*width: min\(420px, calc\(100vw - 20px\)\);/);
assert.match(readability, /\.validator-map-tooltip li \{[\s\S]*grid-template-columns: minmax\(0,1fr\) max-content;/);
assert.match(readability, /\.validator-map-location-evidence dl \{[\s\S]*grid-template-columns: max-content minmax\(0,1fr\);/);
assert.match(readability, /footer \{[\s\S]*grid-template-columns: max-content minmax\(180px, 1fr\) repeat\(5, max-content\);/);
assert.match(readability, /\.footer-github \{[\s\S]*justify-self: end;[\s\S]*align-self: center;/);
assert.doesNotMatch(readability, /validator-marker-number/);
assert.match(
  readability,
  /\.nodes\.compact \.node \{[\s\S]*flex: 1 1 0;[\s\S]*height: 400px;[\s\S]*min-height: 400px;[\s\S]*max-height: 400px;[\s\S]*transition:/,
);
assert.match(readability, /\.nodes\.compact \.node\.is-collapsed \{[\s\S]*flex: 0 0 var\(--collapsed-host-width\);[\s\S]*width: var\(--collapsed-host-width\);/);
assert.match(readability, /\.nodes\.compact \.node\.is-expanded \{[\s\S]*min-width: 270px;/);
assert.match(readability, /--collapsed-host-width: 32px;/);
assert.match(readability, /\.nodes\.compact \.node-toggle:focus-visible \{[\s\S]*outline: 2px solid var\(--lime\);/);
assert.match(readability, /\.nodes\.compact \.node\.is-collapsed \.node-toggle \{[\s\S]*writing-mode: vertical-rl;[\s\S]*transform: rotate\(180deg\);/);
assert.match(readability, /\.nodes\.compact \.metric \{\s*box-sizing: border-box;[\s\S]*max-height: none;[\s\S]*align-items: flex-start;/);
assert.match(readability, /\.nodes\.compact \.metric\.inferenced,[\s\S]*\.nodes\.compact \.metric\.dapi,[\s\S]*\.nodes\.compact \.metric\.devshard,[\s\S]*\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\),[\s\S]*\.nodes\.compact \.metric\.mlnodes:not\(\[hidden\]\) \{/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\) \{[\s\S]*grid-template-columns: 24px minmax\(0, 1fr\);[\s\S]*align-items: center;/);
assert.match(readability, /\.nodes\.compact \.metric\.inferenced b,[\s\S]*\.nodes\.compact \.metric\.dapi b,[\s\S]*\.nodes\.compact \.metric\.devshard b,[\s\S]*\.nodes\.compact \.metric\.mlnodes b \{[\s\S]*font-size: 9px;[\s\S]*overflow: hidden;[\s\S]*overflow-wrap: anywhere;[\s\S]*text-overflow: clip;[\s\S]*white-space: normal;/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu b \{[\s\S]*font-size: 8px;[\s\S]*min-width: 0;[\s\S]*overflow: hidden;[\s\S]*text-overflow: ellipsis;[\s\S]*white-space: nowrap;/);
assert.match(readability, /\.nodes\.compact \.metric b \{[\s\S]*flex: 1 1 auto;[\s\S]*overflow: hidden;[\s\S]*overflow-wrap: anywhere;[\s\S]*text-overflow: clip;[\s\S]*white-space: normal;/);
assert.match(readability, /@media \(max-width: 700px\) \{[\s\S]*\.nodes\.compact \{[\s\S]*flex-direction: column;[\s\S]*height: auto;[\s\S]*overflow: visible;[\s\S]*\.nodes\.compact \.node\.is-collapsed \{[\s\S]*height: 52px;/);
assert.match(readability, /@media \(prefers-reduced-motion: reduce\) \{[\s\S]*transition: none;/);
assert.match(mapFixture, /name: "fixture-dynamic",\s*mode: "skip",\s*reason: "fixture skip path"/);
assert.match(mapFixture, /\.\.\.Array\.from\(\{ length: 11 \}, \(_, index\) => \(\{\s*name: `fixture-overflow-\$\{index \+ 1\}`/);
assert.match(mapFixture, /\[1399, 720\][\s\S]*\[1321, 720\][\s\S]*\[1320, 720\][\s\S]*\[1101, 720\][\s\S]*\[1100, 720\][\s\S]*\[701, 720\][\s\S]*\[700, 720\][\s\S]*\[521, 720\][\s\S]*\[1400, 900\][\s\S]*\[1440, 900\][\s\S]*\[1920, 1080\][\s\S]*\[390, 844\]/);
assert.match(mapFixture, /\[1920, 1440, 1400, 1399, 1321, 1320, 1280, 1101, 1100, 844, 701, 700, 521, 390, 375, 360, 320\]\.includes\(width\)/);
assert.match(mapFixture, /!skippedGpu\.hidden[\s\S]*skippedGpu\.text === "Unavailable"/);
assert.match(mapFixture, /cards\.length > 5[\s\S]*cardsReachable[\s\S]*activationValid[\s\S]*keyboardValid/);
assert.match(mapFixture, /cards\.length !== 22[\s\S]*desktopReachability[\s\S]*mobileReachability/);
assert.match(mapFixture, /waitForSettledOverlappingMarker[\s\S]*stableSamples >= 3/);
assert.doesNotMatch(mapFixture, /startsWith\(\$\{JSON\.stringify\(expected\)\}\)/);
assert.match(homepageCapture, /return value && \{[\s\S]*width: value\.width,[\s\S]*height: value\.height/);
assert.match(homepageCapture, /state\.nodeDeck/);
assert.match(homepageCapture, /deck\.cards\.every\(card => card\.height >= 350\)/);
assert.match(homepageCapture, /const deckInternalOverflow = deck\.scrollWidth > deck\.clientWidth \+ 1;/);
assert.match(homepageCapture, /deck\.firstAtStart && deck\.lastAtEnd && deck\.appliedScrollLeft > 1/);
assert.match(homepageCapture, /Host accordion layout contract failed/);
assert.match(homepageCapture, /Host accordion activation contract failed/);
assert.match(homepageCapture, /GDC_EXPECT_STATUS_PREFIX/);
assert.match(homepageCapture, /GDC_EXPECT_CARD_COUNT/);
assert.match(homepageCapture, /GDC_EXPECT_NODE_STATES/);
assert.match(homepageCapture, /preview shared status request failed/);
assert.match(homepageCapture, /homepage rendered .* required Host cards/);
assert.match(homepageCapture, /Host cards do not have equal heights/);
assert.match(homepageCapture, /Host state does not match expected/);
assert.match(homepageCapture, /visualWidth: visualViewport\?\.width \|\| innerWidth/);
assert.match(homepageCapture, /Math\.abs\(state\.visualWidth - width\) > 0\.5/);
assert.ok(
  homepageCapture.includes(
    'requirementsNote: element?.querySelector(".join-requirements-note")?.textContent?.trim(),',
  ),
);
assert.ok(
  homepageCapture.includes(
    "await call('Emulation.setVisibleSize', { width, height }, sessionId);",
  ),
);
assert.match(
  homepageCapture,
  /validator-map \.validator-map-world[\s\S]*naturalWidth[\s\S]*gatewayStateReadyExpression/,
);
assert.match(homepageCapture, /\/\^TRAFFIC_READY – \/\.test/);
assert.match(homepageCapture, /"CONTROL_READY","ROUTING_READY","RECOVERING","SATURATED"/);
assert.match(
  homepageCapture,
  /startChromeDevTools\(\{[\s\S]*context: `homepage viewport \$\{width\}x\$\{height\}`/,
);
assert.match(homepageCapture, /await stopChromeDevTools\(browser\)/);
assert.match(
  homepageCapture,
  /await rm\(profile, \{ recursive: true, force: true \}\)/,
);

async function testSharedTelegramProjection() {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, { dataset: {}, children: [], removeAttribute() {} });
    return elements.get(id);
  };
  let timestamp = 1000000;
  let read = async () => ({ status: 'ok', readiness_projection: snapshot });
  const source = siteApp.slice(siteApp.indexOf('let telegramStatusFetch ='), siteApp.indexOf('$("grafana-network")'));
  assert.ok(source.includes('renderTelegramProjection'));
  const consumer = new Function('$', 'cfg', 'json', 'statusUrl', 'Date', `${source};return {refreshTelegramConsumer,renderTelegramProjection};`)(
    element, { model: 'model', telegramBot: 'https://t.me/test' }, (...args) => read(...args), (path) => '/status' + path, { now: () => timestamp },
  );
  const observation = (state, backend) => ({ state, backend, model: 'model', reason: 'observed', observed_at: 1000, expires_at: 1030 });
  let snapshot = { schema_version: 1, scope: 'telegram_model_backend', model: 'model', revision: 5,
    combined_state: 'LIVE', gateway_state: 'DEGRADED', reason: 'recent_delivery_and_current_eligibility',
    backends: [observation('UNAVAILABLE', 'A'), observation('ELIGIBLE', 'B')],
    bot: observation('OK'), delivery: { state: 'RECENT', model: 'model', observed_at: 1000, expires_at: 1120 },
    telemetry: { state: 'PARTIAL' } };
  await consumer.refreshTelegramConsumer();
  assert.equal(element('contact').dataset.state, 'LIVE');
  assert.equal(element('gateway-a-state').textContent, 'UNAVAILABLE');
  assert.equal(element('gateway-b-state').textContent, 'ELIGIBLE');
  assert.match(element('contact').title, /telemetry PARTIAL/);
  assert.equal(element('quality-health-state').textContent, 'A/B DEGRADED; telemetry UNVERIFIED');
  assert.equal(element('quality-accepted').textContent, 'unknown');
  const telemetry = { scope: 'native_gateway_requests_including_bot_and_direct_clients', model: 'model', state: 'CURRENT',
    backends: [{ ...observation('FRESH', 'A'), counters: [{outcome:'success',reason:'none',value:3},{outcome:'failed',reason:'none',value:1}] },
               { ...observation('FRESH', 'B'), counters: [{outcome:'success',reason:'none',value:4}] }] };
  snapshot = { ...snapshot, revision: 6, telemetry };
  await consumer.refreshTelegramConsumer();
  assert.equal(element('quality-accepted').textContent, '7');
  assert.equal(element('quality-rejected').textContent, 'unknown');
  assert.equal(element('quality-active').textContent, 'unknown');
  assert.equal(element('quality-health-state').textContent, 'A/B DEGRADED; telemetry CURRENT');
  assert.match(element('gateway-b-detail').textContent, /native traffic success:none=4/);
  snapshot = { ...snapshot, revision: 7, telemetry: { ...telemetry, backends: [telemetry.backends[0]] } };
  await consumer.refreshTelegramConsumer();
  assert.equal(element('quality-accepted').textContent, '3');
  assert.equal(element('quality-rejected').textContent, '1');
  assert.equal(element('quality-health-state').textContent, 'A/B DEGRADED; telemetry PARTIAL');
  timestamp = 1031000;
  consumer.renderTelegramProjection();
  assert.equal(element('contact').dataset.state, 'UNVERIFIED');
  assert.equal(element('gateway-b-state').textContent, 'UNVERIFIED');
  assert.equal(element('quality-accepted').textContent, 'unknown');
  assert.equal(element('quality-health-state').textContent, 'A/B UNVERIFIED; telemetry UNVERIFIED');
  timestamp = 1000000;
  snapshot = { ...snapshot, revision: 8, combined_state: 'BOT_FAILED', bot: observation('FAILED') };
  await consumer.refreshTelegramConsumer();
  assert.equal(element('contact').dataset.state, 'BOT_FAILED');
  snapshot = { ...snapshot, revision: 7, combined_state: 'LIVE', bot: observation('OK') };
  await consumer.refreshTelegramConsumer();
  assert.equal(element('contact').dataset.state, 'BOT_FAILED');
  let releaseOld;
  read = () => new Promise((resolve) => { releaseOld = resolve; });
  const old = consumer.refreshTelegramConsumer();
  read = async () => ({ status: 'ok', readiness_projection: { ...snapshot, revision: 9, combined_state: 'UNVERIFIED' } });
  await consumer.refreshTelegramConsumer();
  releaseOld({ status: 'ok', readiness_projection: { ...snapshot, revision: 999 } });
  await old;
  assert.equal(element('contact').dataset.state, 'UNVERIFIED');
  read = async () => ({ status: 'ok', inference_ready: true });
  await consumer.refreshTelegramConsumer();
  assert.equal(element('contact').dataset.state, 'UNVERIFIED');
  assert.equal(element('gateway-a-state').textContent, 'UNVERIFIED');
  assert.match(element('contact').title, /unverified/);
}
async function testObservedFleetIdentity() {
  const target = {};
  const card = {querySelector: () => target};
  const node = {name:'fixture',devShardHealth:{state:'observed',runtimes:[{name:'v5',status:'running',binary_version:'nominal-only',sha256:'claimed-archive'},{name:'v4',status:'running'}]}};
  let timestamp = 1001000;
  let read = async () => ({status:'success',data:{resultType:'vector',result:[observedRuntime]}});
  const source = siteApp.slice(siteApp.indexOf('function updateDevShards('),siteApp.indexOf('function updateMlNodes('));
  const fleet = new Function('GDC_SOFTWARE_VERSIONS','softwareInventoryKeys','Date','json','statusUrl','observedNodes','cards','nodeKey',
    `let cardDevShardInventory = new Map(); let devShardInventoryRequest = 0; let devShardInventoryWatermarks = new Map(); ${source}; return {refreshDevShardInventory,renderDevShardInventory};`)(
    softwareIdentity,(item) => [item.name],{now:() => timestamp},(...args) => read(...args),(item) => '/status'+item,
    [node],new Map([['fixture',card]]),(item) => item.name);
  await fleet.refreshDevShardInventory();
  assert.match(target.textContent,/v5 v5\.0\.2/);
  assert.match(target.textContent,/v4 identity unknown/);
  assert.match(target.title,new RegExp('binary SHA-256 '+'b'.repeat(64)));
  assert.match(target.title,new RegExp('archive SHA-256 '+'c'.repeat(64)));
  assert.doesNotMatch(target.title,/nominal-only|claimed-archive/);
  timestamp=1091000;
  fleet.renderDevShardInventory();
  assert.match(target.title,/identity unverified/);
  assert.doesNotMatch(target.title,new RegExp('b'.repeat(64)));
  timestamp=1001000;
  let releaseOld;
  read=() => new Promise((resolve) => {releaseOld=resolve;});
  const old=fleet.refreshDevShardInventory();
  read=async () => {throw new Error('unreachable fixture');};
  await fleet.refreshDevShardInventory();
  releaseOld({status:'success',data:{resultType:'vector',result:[observedRuntime]}});
  await old;
  assert.match(target.title,/identity unverified/);
  assert.doesNotMatch(target.title,new RegExp('b'.repeat(64)));
  const response = (samples) => ({status:'success',data:{resultType:'vector',result:samples}});
  const sample = (source, version, hash) => ({...observedRuntime,metric:{...observedRuntime.metric,version,binary_sha256:hash.repeat(64)},value:[1005,String(source)]});
  read=async () => response([sample(995,'v5.0.0','a')]);
  await fleet.refreshDevShardInventory();
  assert.match(target.title,/identity unverified/);
  assert.doesNotMatch(target.title,new RegExp('a'.repeat(64)));
  read=async () => response([sample(1000,'v5.0.0','d')]);
  await fleet.refreshDevShardInventory();
  assert.match(target.title,/identity unverified/);
  assert.doesNotMatch(target.title,new RegExp('d'.repeat(64)));
  read=async () => response([]);
  await fleet.refreshDevShardInventory();
  read=async () => response([sample(995,'v5.0.0','a')]);
  await fleet.refreshDevShardInventory();
  assert.match(target.title,/identity unverified/);
  read=async () => response([sample(1001,'v5.0.3','e')]);
  await fleet.refreshDevShardInventory();
  assert.match(target.textContent,/v5\.0\.3/);
  assert.match(target.title,new RegExp('e'.repeat(64)));
}
testSharedTelegramProjection().then(testObservedFleetIdentity).then(() => {
  fs.rmSync(siteBuild, { recursive: true, force: true });
  console.log('PASS gateway public-site and timed Telegram projection contracts');
}).catch((error) => { console.error(error); process.exitCode = 1; });
