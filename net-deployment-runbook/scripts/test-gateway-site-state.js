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
const hostState = require(path.join(siteBuild, 'host-state.js'));
const networkObservationState = require(path.join(siteBuild, 'network-observation-state.js'));
const softwareVersions = require(path.join(siteBuild, 'software-versions.js'));
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
assert.deepEqual(hostState.classify({
  networkObserved: true,
  networkActive: true,
  endpointState: 'reachable',
}), {
  state: 'active', stateLabel: 'Active',
  reason: 'Public chain endpoint reachable; checking validator membership',
  primaryLabel: 'Active', primaryClass: 'status active',
  votingPower: 'Unavailable', endpointLabel: 'Reachable',
  syncLabel: 'Pending observation', validatorEffective: false,
});
const observedPeer = {
  networkObserved: true, networkActive: true, endpointState: 'reachable',
  catchingUp: false, blocksBehind: 0, blockAgeSeconds: 10,
  progressing: true, referenceKnown: true, referenceAgrees: true,
};
assert.equal(hostState.classify(observedPeer).syncLabel, 'Synced');
for (const [input, label] of [
  [{...observedPeer, networkActive: false}, 'Active'],
  [{...observedPeer, endpointState: 'unavailable'}, 'Unavailable'],
  [{...observedPeer, observationComplete: true}, 'Active'],
  [{...observedPeer, endpointState: 'unknown'}, 'Checking'],
  [{networkObserved: true, networkActive: true}, 'Checking'],
]) assert.equal(hostState.classify(input).primaryLabel, label);
for (const [power, displayed, effective] of [
  ['0', '0', false], ['42', '42', true],
  ['9007199254740993', '9007199254740993', true],
  [undefined, 'Unavailable', false], [null, 'Unavailable', false],
  ['invalid', 'Unavailable', false], ['-1', 'Unavailable', false],
]) {
  const result = hostState.classify({...observedPeer, validatorKnown: true, votingPower: power});
  assert.equal(result.votingPower, displayed);
  assert.equal(result.validatorEffective, effective);
}
assert.equal(hostState.classify({...observedPeer, validatorKnown: true,
  votingPower: '42', blockAgeSeconds: 200}).validatorEffective, false);
const node1Stalled = hostState.classify({...observedPeer,
  validatorKnown: true, votingPower: '32', blocksBehind: 5439,
  blockAgeSeconds: 29500, progressing: false, referenceAgrees: false});
assert.equal(node1Stalled.primaryLabel, 'Validating');
assert.equal(node1Stalled.syncLabel, 'Lagging – 5,439 blocks');
assert.equal(node1Stalled.votingPower, '32');
assert.equal(node1Stalled.validatorEffective, false);
assert.equal(node1Stalled.endpointLabel, 'Reachable');
assert.equal(node1Stalled.state, 'validating');
const node7SyncedNoPower = hostState.classify({...observedPeer,
  validatorKnown: true, votingPower: '0'});
assert.equal(node7SyncedNoPower.primaryLabel, 'Active');
assert.equal(node7SyncedNoPower.syncLabel, 'Synced');
assert.equal(node7SyncedNoPower.votingPower, '0');
assert.equal(node7SyncedNoPower.validatorEffective, false);
const currentValidator = hostState.classify({...observedPeer,
  validatorKnown: true, votingPower: '201'});
assert.equal(currentValidator.primaryLabel, 'Validating');
assert.equal(currentValidator.validatorEffective, true);
assert.equal(hostState.classify({...observedPeer, catchingUp: undefined}).syncLabel,
  'Pending observation');
const staleMlHardware = {state: 'observed', nodes: [{local_id: 'stale', version: '3.0.14-post2'}]};
const noAssignedMlNode = softwareVersions.selectMlNodes({mlnodes: []}, staleMlHardware);
assert.equal(softwareVersions.emptyMlNodeLabel(noAssignedMlNode), 'Not assigned');
const missingMlVersion = softwareVersions.selectMlNodes({mlnodes: [{node_id: 'model:account'}]}, staleMlHardware);
assert.equal(softwareVersions.emptyMlNodeLabel(missingMlVersion), 'Version unavailable');
const unavailableMlInventory = softwareVersions.selectMlNodes(null, {state: 'unavailable', nodes: []});
assert.equal(softwareVersions.emptyMlNodeLabel(unavailableMlInventory), 'Unavailable');
const versionNow = Date.now();
const freshVersionTime = new Date(versionNow - 1000).toISOString();
const freshVersionObservation = {
  state: 'observed', observed_at: freshVersionTime,
  application_name: 'inference-chain', version: 'v0.2.16-post1',
};
const freshVersionRpc = {
  state: 'observed', observed_at: freshVersionTime,
  p2p_node_id: 'a'.repeat(40), chain_id: 'gonka-devnet-community',
};
assert.equal(softwareVersions.freshNetworkInferenceVersion(
  freshVersionObservation, freshVersionRpc, 'a'.repeat(40), 'gonka-devnet-community', versionNow,
), 'v0.2.16-post1');
assert.equal(softwareVersions.freshNetworkInferenceVersion(
  {...freshVersionObservation, observed_at: new Date(versionNow - 301000).toISOString()},
  freshVersionRpc, 'a'.repeat(40), 'gonka-devnet-community', versionNow,
), '');
assert.equal(softwareVersions.freshNetworkInferenceVersion(
  freshVersionObservation, {...freshVersionRpc, p2p_node_id: 'b'.repeat(40)},
  'a'.repeat(40), 'gonka-devnet-community', versionNow,
), '');
assert.equal(softwareVersions.freshNetworkInferenceVersion(
  freshVersionObservation, {...freshVersionRpc, chain_id: 'other-chain'},
  'a'.repeat(40), 'gonka-devnet-community', versionNow,
), '');
assert.equal(softwareVersions.freshPayloadVersion({
  timestamp: freshVersionTime, node_version: {version: 'v0.2.15'},
}, 'chain', versionNow), 'v0.2.15');
assert.equal(softwareVersions.freshPayloadVersion({
  timestamp: new Date(versionNow - 301000).toISOString(), node_version: {version: 'v0.2.15'},
}, 'chain', versionNow), '');
assert.equal(hostState.classify({...observedPeer, blockAgeSeconds: null}).syncLabel,
  'Pending observation');
assert.equal(hostState.classify({...observedPeer, blocksBehind: undefined}).syncLabel,
  'Pending observation');
assert.equal(hostState.classify({...observedPeer, blocksBehind: 3978,
  blockAgeSeconds: 20000, progressing: false, referenceAgrees: false}).syncLabel,
  'Lagging – 3,978 blocks');
assert.equal(hostState.classify({...observedPeer, blockAgeSeconds: 120,
  progressing: false}).syncLabel, 'Stale');
assert.equal(hostState.classify({...observedPeer, referenceKnown: false}).syncLabel,
  'Pending observation');
assert.equal(hostState.classify({...observedPeer, endpointState: 'unavailable'}).syncLabel,
  'Unavailable');
assert.equal(hostState.classify({...observedPeer, catchingUp: true}).syncLabel,
  'Lagging');
assert.equal(hostState.classify({
  networkObserved: true,
  networkActive: false,
  endpointState: 'unavailable',
  endpointDiagnostic: 'HTTP 502',
}).primaryLabel, 'Unavailable');
assert.deepEqual(networkObservationState.nodeState({
  node_id: 'a'.repeat(40), node_name: 'node5', dapi_url: 'https://node5.gonka-dev.net', active: true,
  components: { chain_rpc: { state: 'observed', catching_up: true } },
}), {
  nodeId: 'a'.repeat(40), nodeName: 'node5', dapiUrl: 'https://node5.gonka-dev.net',
  active: true, endpointState: 'reachable', endpointDiagnostic: '', catchingUp: true,
});
assert.deepEqual(networkObservationState.nodeState({
  node_id: 'b'.repeat(40), active: false, error: 'HTTP 502',
  components: {chain_rpc: {state: 'unavailable'}},
}), {
  nodeId: 'b'.repeat(40), nodeName: '', dapiUrl: '', active: false,
  endpointState: 'unavailable', endpointDiagnostic: 'HTTP 502', catchingUp: false,
});
assert.equal(networkObservationState.nodeState({ node_id: 'not-a-node' }), null);
// Exercise the collector-to-card path, not just isolated status labels.
for (const [rpc, expected] of [
  [{state: 'observed'}, 'Active'],
  [{state: 'unavailable', error: 'HTTP 502'}, 'Unavailable'],
  [{state: 'not_exposed'}, 'Checking'],
  [undefined, 'Checking'],
]) {
  const node = networkObservationState.nodeState({
    node_id: 'c'.repeat(40), active: true, components: {chain_rpc: rpc},
  });
  const result = hostState.classify({...node, networkObserved: true, networkActive: node.active});
  assert.equal(result.primaryLabel, expected);
}
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
assert.match(siteApp, /sample\?\.metric\?\.gpu_name/);
assert.match(siteApp, /const networkAttached = \(hardware\?\.nodes \|\| \[\]\)\.some/);
assert.match(siteApp, /host !== node\.ip/);
assert.match(siteApp, /\? "network"\s*:\s*"local"/);
assert.match(siteApp, /const gpuHost = node\.gpuHost \|\| node\.name/);
assert.match(siteApp, /const inventoryKey = \[gpuHost, node\.publicHost, node\.name\]/);
assert.match(siteApp, /function refreshHardwareInventory/);
assert.match(siteApp, /function reportedSoftwareMetadata/);
assert.match(siteApp, /function softwareInventoryKeys/);
assert.match(siteApp, /\^\(\?:gdc-\)\?\(node\[0-9\]\+\)/);
assert.match(siteApp, /keys\.add\(`gdc-\$\{match\[1\]\}`\)/);
assert.match(siteApp, /reportedSoftwareMetadata\(node, component\)\n\s*\? "Version unavailable"/);
assert.match(siteApp, /Current on-chain runtime inventory/);
assert.match(siteApp, /Chain runtime inventory reports no GPU for this participant/);
assert.match(siteApp, /\$\{inventoryLabel\} – \$\{connection\}/);
assert.match(siteApp, /replace\(\/\^NVIDIA\\s\+\/i, ""\)/);
assert.match(siteApp, /hostState\.classify/);
assert.match(siteApp, /GDC_SOFTWARE_VERSIONS\.formatMlNodes/);
assert.match(siteApp, /data-k="vp"/);
assert.match(siteApp, /<span>voting power<\/span>/);
assert.match(siteApp, /class="metric inferenced" data-k-row="inferenced"/);
assert.match(siteApp, /class="metric dapi" data-k-row="dapi"/);
assert.match(siteApp, /class="metric devshard" data-k-row="devshard"/);
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
assert.match(siteApp, /validatorEffective/);
assert.match(siteApp, /catchingUp/);
assert.match(siteApp, /blockAgeSeconds/);
assert.match(siteApp, /referenceKnown/);
assert.match(siteApp, /refreshCurrentValidatorSet\(reference\)/);
assert.match(siteApp, /function markerStateCounts\(validators/);
assert.match(siteApp, /waiting: 0/);
assert.match(siteApp, /function markerGroupState\(counts/);
assert.match(siteApp, /label:\s*states\.length > 1 \? "Mixed"/);
assert.match(siteApp, /function markerRadius\(gpus/);
assert.match(siteApp, /7\.5 \* Math\.sqrt\(gpus\)/);
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
assert.match(homepageCapture, /compareHostIdentitySets\(/);
assert.match(homepageCapture, /rendered Host identities do not match current preview P2P observations/);
assert.match(
  readability,
  /\.nodes\.compact \{[\s\S]*display: flex;[\s\S]*align-items: flex-start;[\s\S]*height: auto;[\s\S]*min-height: 350px;[\s\S]*overflow-x: auto;[\s\S]*overflow-y: hidden;[\s\S]*overscroll-behavior-x: contain;/,
);
assert.doesNotMatch(readability, /validator-map-encoding-note/);
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
  /\.nodes\.compact \.node \{[\s\S]*flex: 1 1 0;[\s\S]*height: 480px;[\s\S]*min-height: 480px;[\s\S]*max-height: 480px;[\s\S]*transition:/,
);
assert.match(readability, /\.nodes\.compact \.node\.is-collapsed \{[\s\S]*flex: 0 0 var\(--collapsed-host-width\);[\s\S]*width: var\(--collapsed-host-width\);/);
assert.match(readability, /\.nodes\.compact \.node\.is-expanded \{[\s\S]*min-width: 270px;/);
assert.match(readability, /--collapsed-host-width: 32px;/);
assert.match(readability, /\.nodes\.compact \.node-toggle:focus-visible \{[\s\S]*outline: 2px solid var\(--lime\);/);
assert.match(readability, /\.nodes\.compact \.node\.is-collapsed \.node-toggle \{[\s\S]*writing-mode: vertical-rl;[\s\S]*transform: rotate\(180deg\);/);
assert.match(readability, /\.nodes\.compact \.metric \{\s*box-sizing: border-box;[\s\S]*max-height: none;[\s\S]*align-items: flex-start;/);
assert.match(readability, /\.nodes\.compact \.metric\.validator:not\(\[hidden\]\) \{[\s\S]*grid-template-columns: 52px minmax\(0, 1fr\);/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu:not\(\[hidden\]\) \{[\s\S]*grid-template-columns: 32px minmax\(0, 1fr\);[\s\S]*align-items: start;/);
assert.match(readability, /\.nodes\.compact \.metric\.inferenced b,[\s\S]*\.nodes\.compact \.metric\.dapi b,[\s\S]*\.nodes\.compact \.metric\.devshard b,[\s\S]*\.nodes\.compact \.metric\.mlnodes b \{[\s\S]*font-size: 9px;[\s\S]*overflow: hidden;[\s\S]*overflow-wrap: anywhere;[\s\S]*text-overflow: clip;[\s\S]*white-space: normal;/);
assert.match(readability, /\.nodes\.compact \.metric\.gpu b \{[\s\S]*font-size: 9px;[\s\S]*overflow-wrap: anywhere;[\s\S]*white-space: normal;/);
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

async function testRpcObservation() {
  const { compareHostIdentitySets } = await import('./preview-host-identities.mjs');
  assert.deepEqual(compareHostIdentitySets(['a'.repeat(40), 'b'.repeat(40)], ['B'.repeat(40), 'A'.repeat(40)]), {
    valid: true, matches: true,
    expected: ['A'.repeat(40), 'B'.repeat(40)],
    rendered: ['B'.repeat(40), 'A'.repeat(40)],
  });
  assert.equal(compareHostIdentitySets(['a'.repeat(40)], ['b'.repeat(40)]).matches, false);
  assert.equal(compareHostIdentitySets(['a'.repeat(40), 'a'.repeat(40)], ['a'.repeat(40)]).valid, false);
  assert.equal(compareHostIdentitySets([], ['a'.repeat(40)]).valid, false);
  const id = 'c'.repeat(40);
  const status = {result: {node_info: {id}, validator_info: {voting_power: '42'}}};
  const calls = [];
  const observation = await networkObservationState.observeRpc('/status/node', id, async (url) => {
    calls.push(url);
    if (url.endsWith('/status')) return status;
    throw new Error('HTTP 502');
  });
  assert.deepEqual(calls, ['/status/node/chain-rpc/status', '/status/node/chain-rpc/net_info']);
  assert.deepEqual(observation, {status, peers: null});
  assert.equal(networkObservationState.peerCount(observation.peers), '–');
  assert.equal(networkObservationState.peerCount({result: {n_peers: null}}), '–');
  assert.equal(networkObservationState.referenceProgressed(null, 10, 'chain-a', 1000), false);
  assert.equal(networkObservationState.referenceProgressed({height: 10, chainId: 'chain-a', observedAt: 900}, 11, 'chain-a', 1000), true);
  assert.equal(networkObservationState.referenceProgressed({height: 10, chainId: 'chain-b', observedAt: 900}, 11, 'chain-a', 1000), false);
  assert.equal(networkObservationState.referenceProgressed({height: 10, chainId: 'chain-a', observedAt: 900}, 10, 'chain-a', 1000), false);
  assert.equal(networkObservationState.referenceProgressed({height: 10, chainId: 'chain-a', observedAt: 0}, 11, 'chain-a', 100000), false);
  const gatewayId = 'a'.repeat(40);
  const peerId = 'b'.repeat(40);
  const prior = new Map([
    [gatewayId.toUpperCase(), {height: 100, chainId: 'chain-a', observedAt: 99000}],
    [peerId.toUpperCase(), {height: 50, chainId: 'chain-a', observedAt: 99000}],
  ]);
  const peerReference = networkObservationState.selectProgressingReference([
    {nodeId: gatewayId, statusBase: '/gateway', identityVerified: true, chainId: 'chain-a', height: 100,
      catchingUp: true, blockTimeMs: 99000, sampledAt: 100000},
    {nodeId: peerId, statusBase: '/healthy-peer', identityVerified: true, chainId: 'chain-a', height: 51,
      catchingUp: false, blockTimeMs: 99000, sampledAt: 100000},
  ], prior, 'chain-a', 100000);
  assert.equal(peerReference.statusBase, '/healthy-peer');
  assert.equal(networkObservationState.selectProgressingReference([
    {nodeId: peerId, identityVerified: true, chainId: 'chain-a', height: 101,
      catchingUp: false, blockTimeMs: 99000, sampledAt: 100000},
  ], new Map([[gatewayId.toUpperCase(), {height: 100, chainId: 'chain-a', observedAt: 99000}]]), 'chain-a', 100000), null);
  assert.equal(networkObservationState.selectProgressingReference([
    {nodeId: gatewayId, identityVerified: false, chainId: 'chain-a', height: 101,
      catchingUp: false, blockTimeMs: 99000},
    {nodeId: peerId, identityVerified: true, chainId: 'chain-b', height: 52,
      catchingUp: false, blockTimeMs: 99000},
  ], prior, 'chain-a', 100000), null);
  assert.equal(hostState.classify({...observedPeer,
    validatorKnown: true, votingPower: observation.status.result.validator_info.voting_power,
  }).syncLabel, 'Synced');
  assert.equal(networkObservationState.peerCount({result: {n_peers: '5'}}), '5');
  assert.equal(networkObservationState.peerCount({result: {n_peers: 'unknown'}}), '–');
  assert.equal(networkObservationState.currentVotingPower('A'.repeat(40), {
    state: 'observed', verified: true, complete: true, validators: [{address: 'a'.repeat(40), voting_power: '7'}],
  }), '7');
  assert.equal(networkObservationState.currentVotingPower('B'.repeat(40), {
    state: 'observed', verified: true, complete: true, validators: [{address: 'a'.repeat(40), voting_power: '7'}],
  }), '0');
  assert.equal(networkObservationState.currentVotingPower('B'.repeat(40), {
    state: 'observed', verified: false, complete: false, validators: [],
  }), null);
  assert.equal(networkObservationState.currentVotingPower('invalid', {
    state: 'observed', verified: true, complete: true, validators: [],
  }), null);
  assert.equal(networkObservationState.currentVotingPower('B'.repeat(40), {
    state: 'observed', verified: true, complete: true,
    validators: [{address: 'a'.repeat(40), voting_power: '7'}, {address: 'a'.repeat(40), voting_power: '9'}],
  }), null);
  assert.equal(networkObservationState.currentVotingPower('B'.repeat(40), {
    state: 'observed', verified: true, complete: true,
    validators: [{address: 'a'.repeat(40), voting_power: 'bad'}],
  }), null);
  const currentSetResponse = {result: {block_height: '88', count: '1', total: '1',
    validators: [{address: 'a'.repeat(40), voting_power: '7'}]}};
  const referenceNow = Date.now();
  const referenceStatusResponse = {result: {node_info: {id: 'a'.repeat(40), network: 'chain-a'},
    sync_info: {latest_block_height: '88', latest_block_time: new Date(referenceNow - 1000).toISOString(), catching_up: false}}};
  const currentReference = {statusBase: '/215/status/node0', nodeId: 'a'.repeat(40), identityVerified: true,
    height: 88, chainId: 'chain-a', catchingUp: false, blockTimeMs: referenceNow - 1000};
  assert.equal(networkObservationState.validatorSet(currentSetResponse, 88, 'chain-a', 'chain-a').verified, true);
  assert.equal(networkObservationState.validatorSet(currentSetResponse, 87, 'chain-a', 'chain-a').verified, false);
  assert.equal(networkObservationState.validatorSet(currentSetResponse, 88, 'chain-b', 'chain-a').verified, false);
  assert.equal(networkObservationState.validatorSet({...currentSetResponse, result: {...currentSetResponse.result, count: '10001', total: '10001'}}, 88, 'chain-a', 'chain-a').verified, false);
  const validatorUrls = [];
  const loadedSet = await networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    validatorUrls.push(url);
    return url.endsWith('/chain-rpc/status') ? referenceStatusResponse : currentSetResponse;
  });
  assert.deepEqual(validatorUrls, ['/215/status/node0/chain-rpc/validators?height=88&page=1&per_page=100']);
  assert.equal(loadedSet.verified, true);
  assert.equal(loadedSet.blockHeight, 88);

  const chainApiOrigin = 'https://node0.gonka-dev.net';
  const participantStatus = {result: {node_info: {id: 'a'.repeat(40), network: 'chain-a'},
    sync_info: {latest_block_height: '88', latest_block_time: new Date(Date.now() - 500).toISOString(), catching_up: false}}};
  const participantA = {address: 'gonka1aaaaaaaaaaaaaaaaaaaaaaaaaa', index: 'gonka1aaaaaaaaaaaaaaaaaaaaaaaaaa', inference_url: 'https://node1.gonka-dev.net'};
  const participantB = {address: 'gonka1bbbbbbbbbbbbbbbbbbbbbbbbbb', index: 'gonka1bbbbbbbbbbbbbbbbbbbbbbbbbb', inference_url: 'https://node2.gonka-dev.net'};
  const pageOne = {block_height: '87', participant: [participantA, ...Array.from({length: 99}, (_, i) => ({
    address: `gonka1${String(i).padStart(26, 'a')}`,
    index: `gonka1${String(i).padStart(26, 'a')}`,
    inference_url: `https://participant-${i}.example.test`,
  }))], pagination: {next_key: 'page-two'}};
  const pageTwo = {block_height: '87', participant: [participantB], pagination: {next_key: null}};
  const participantUrls = [];
  const participants = await networkObservationState.loadParticipants(chainApiOrigin,
    {nodeId: 'a'.repeat(40), chainId: 'chain-a', identityVerified: true}, 'chain-a', async (url) => {
      participantUrls.push(url);
      if (url.endsWith('/chain-rpc/status')) return participantStatus;
      return url.includes('pagination.key=page-two') ? pageTwo : pageOne;
    });
  assert.equal(participants.length, 101, 'all participant pages must be fetched before mapping');
  assert.equal(participantUrls.length, 4, 'identity/freshness is checked before and after the complete page sequence');
  const node1 = {address: '1'.repeat(40), dapiUrl: 'https://node1.gonka-dev.net', rpcIdentityVerified: true};
  assert.equal(networkObservationState.participantAddressForNode(participants, node1), participantA.address);
  assert.equal(networkObservationState.participantAddressForNode(participants, {...node1, rpcIdentityVerified: false}), null,
    'unverified P2P identities cannot be mapped');
  assert.equal(networkObservationState.participantAddressForNode([...participants, {...participantA, address: participantB.address, index: participantB.address}], node1), null,
    'ambiguous same-origin participant mappings must remain unavailable');
  assert.equal(networkObservationState.participantAddressForNode([], node1), null);
  assert.equal(networkObservationState.participantAddressForNode([participantA], {...node1, dapiUrl: 'http://node1.gonka-dev.net'}), null,
    'non-HTTPS origins cannot be mapped');
  await assert.rejects(networkObservationState.loadParticipants(chainApiOrigin,
    {nodeId: 'b'.repeat(40), chainId: 'chain-a', identityVerified: true}, 'chain-a', async () => participantStatus), /identity or freshness/);
  for (const invalidPage of [
    {block_height: '87', participants: [participantA], pagination: {next_key: null}},
    {block_height: '87', participant: [participantA], pagination: {}},
    {block_height: '87', participant: [{...participantA, index: 'other'}], pagination: {next_key: null}},
    {block_height: '87', participant: [participantA], pagination: {next_key: 'again'}},
  ]) {
    let pageCalls = 0;
    await assert.rejects(networkObservationState.loadParticipants(chainApiOrigin,
      {nodeId: 'a'.repeat(40), chainId: 'chain-a', identityVerified: true}, 'chain-a', async (url) => {
        if (url.endsWith('/chain-rpc/status')) return participantStatus;
        pageCalls += 1;
        return pageCalls === 1 ? invalidPage : {...invalidPage, block_height: '87', participant: [participantA], pagination: {next_key: null}};
      }));
  }
  await assert.rejects(networkObservationState.loadParticipants(chainApiOrigin,
    {nodeId: 'a'.repeat(40), chainId: 'chain-a', identityVerified: true}, 'chain-a', async (url) => {
      if (url.endsWith('/chain-rpc/status')) return participantStatus;
      return pageOne;
    }), /changed height|bounded page count|repeated/);

  const directReference = {...currentReference, validatorRpcBase: 'https://node0.gonka-dev.net'};
  const directUrls = [];
  const directSet = await networkObservationState.loadCurrentValidatorSet(directReference, 'chain-a', async (url) => {
    directUrls.push(url);
    if (url.includes('/validators?')) return currentSetResponse;
    if (url.startsWith('https://node0.gonka-dev.net/')) return {...referenceStatusResponse, result: {
      ...referenceStatusResponse.result,
      sync_info: {...referenceStatusResponse.result.sync_info, latest_block_height: '89'},
    }};
    return referenceStatusResponse;
  });
  assert.deepEqual(directUrls, [
    'https://node0.gonka-dev.net/chain-rpc/validators?height=88&page=1&per_page=100',
    'https://node0.gonka-dev.net/chain-rpc/status',
  ]);
  assert.equal(directSet.verified, true);
  assert.equal(directSet.blockHeight, 88);

  const direct404Urls = [];
  await assert.rejects(networkObservationState.loadCurrentValidatorSet(directReference, 'chain-a', async (url) => {
    direct404Urls.push(url);
    if (url.includes('/validators?')) throw new Error('404');
    return referenceStatusResponse;
  }), /does not support pinned validator queries/);
  assert.deepEqual(direct404Urls, [
    'https://node0.gonka-dev.net/chain-rpc/validators?height=88&page=1&per_page=100',
  ]);

  await assert.rejects(networkObservationState.loadCurrentValidatorSet(directReference, 'chain-a', async (url) => {
    if (url.includes('/validators?')) return currentSetResponse;
    if (url.startsWith('https://node0.gonka-dev.net/')) return {...referenceStatusResponse, result: {
      ...referenceStatusResponse.result,
      node_info: {...referenceStatusResponse.result.node_info, id: 'b'.repeat(40)},
    }};
    return referenceStatusResponse;
  }), /fresh same-peer chain status/);

  for (const malformedHeight of [undefined, 'not-a-height', 'Infinity']) {
    const malformedStatus = {...referenceStatusResponse, result: {
      ...referenceStatusResponse.result,
      sync_info: {...referenceStatusResponse.result.sync_info},
    }};
    if (malformedHeight === undefined)
      delete malformedStatus.result.sync_info.latest_block_height;
    else malformedStatus.result.sync_info.latest_block_height = malformedHeight;
    await assert.rejects(networkObservationState.loadCurrentValidatorSet(directReference, 'chain-a', async (url) =>
      url.includes('/validators?') ? currentSetResponse : malformedStatus,
    ), /fresh same-peer chain status/);
  }

  const fallbackUrls = [];
  const fallbackSet = await networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    fallbackUrls.push(url);
    if (url.includes('/validators?height=')) throw new Error('404');
    return url.endsWith('/chain-rpc/status') ? referenceStatusResponse : currentSetResponse;
  });
  assert.deepEqual(fallbackUrls, [
    '/215/status/node0/chain-rpc/validators?height=88&page=1&per_page=100',
    '/215/status/node0/chain-rpc/validators?per_page=100',
    '/215/status/node0/chain-rpc/status',
  ]);
  assert.equal(fallbackSet.verified, true);
  assert.equal(networkObservationState.currentVotingPower('A'.repeat(40), fallbackSet), '7');

  const loadLegacyFallback = (legacyResponse, statusResponse) => networkObservationState.loadCurrentValidatorSet(
    currentReference, 'chain-a', async (url) => {
      if (url.includes('/validators?height=')) throw new Error('404');
      return url.endsWith('/chain-rpc/status') ? statusResponse : legacyResponse;
    },
  );
  await assert.rejects(loadLegacyFallback(currentSetResponse, {...referenceStatusResponse, result: {
    ...referenceStatusResponse.result, node_info: {...referenceStatusResponse.result.node_info, id: 'b'.repeat(40)},
  }}));
  await assert.rejects(loadLegacyFallback(currentSetResponse, {...referenceStatusResponse, result: {
    ...referenceStatusResponse.result, node_info: {...referenceStatusResponse.result.node_info, network: 'other-chain'},
  }}));
  await assert.rejects(loadLegacyFallback(currentSetResponse, {...referenceStatusResponse, result: {
    ...referenceStatusResponse.result, sync_info: {...referenceStatusResponse.result.sync_info, catching_up: true},
  }}));
  await assert.rejects(loadLegacyFallback(currentSetResponse, {...referenceStatusResponse, result: {
    ...referenceStatusResponse.result, sync_info: {...referenceStatusResponse.result.sync_info,
      latest_block_time: new Date(Date.now() - 90001).toISOString()},
  }}));

  let fallbackAfterServerError = false;
  await assert.rejects(networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    if (url.includes('/validators?height=')) throw new Error('503');
    fallbackAfterServerError = true;
    return currentSetResponse;
  }));
  assert.equal(fallbackAfterServerError, false);

  await assert.rejects(networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    if (url.includes('/validators?height=')) throw new Error('404');
    if (url.includes('/validators?per_page=')) return {...currentSetResponse, result: {...currentSetResponse.result, block_height: '89'}};
    return {...referenceStatusResponse, result: {...referenceStatusResponse.result,
      sync_info: {...referenceStatusResponse.result.sync_info, latest_block_height: '89'}}};
  }));
  await assert.rejects(networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    if (url.includes('/validators?height=')) throw new Error('404');
    return url.endsWith('/chain-rpc/status')
      ? {...referenceStatusResponse, result: {...referenceStatusResponse.result,
        sync_info: {...referenceStatusResponse.result.sync_info, latest_block_height: '89'}}}
      : currentSetResponse;
  }));
  assert.equal(networkObservationState.currentVotingPower('B'.repeat(40), null), null);

  const duplicateResponse = {result: {block_height: '88', count: '2', total: '2',
    validators: [{address: 'a'.repeat(40), voting_power: '7'}, {address: 'a'.repeat(40), voting_power: '9'}]}};
  await assert.rejects(networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    if (url.includes('/validators?height=')) throw new Error('404');
    return url.endsWith('/chain-rpc/status') ? referenceStatusResponse : duplicateResponse;
  }));
  const incompleteLegacyResponse = {result: {block_height: '88', count: '100', total: '101',
    validators: Array.from({length: 100}, (_, index) => ({address: index.toString(16).padStart(40, '0').toUpperCase(), voting_power: '1'}))}};
  await assert.rejects(networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    if (url.includes('/validators?height=')) throw new Error('404');
    return url.endsWith('/chain-rpc/status') ? referenceStatusResponse : incompleteLegacyResponse;
  }));

  const paginatedEntries = Array.from({length: 101}, (_, index) => ({address: index.toString(16).padStart(40, '0').toUpperCase(), voting_power: '1'}));
  const paginatedUrls = [];
  const paginatedSet = await networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    paginatedUrls.push(url);
    if (url.endsWith('/chain-rpc/status')) return referenceStatusResponse;
    const page = Number(new URL(`https://preview.example${url}`).searchParams.get('page'));
    const entries = paginatedEntries.slice((page - 1) * 100, page * 100);
    return {result: {block_height: '88', count: String(entries.length), total: '101', validators: entries}};
  });
  assert.deepEqual(paginatedUrls, [
    '/215/status/node0/chain-rpc/validators?height=88&page=1&per_page=100',
    '/215/status/node0/chain-rpc/validators?height=88&page=2&per_page=100',
  ]);
  assert.equal(paginatedSet.verified, true);
  assert.equal(paginatedSet.validators.length, 101);
  const noFallbackAfterPartialPagination = [];
  await assert.rejects(networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    noFallbackAfterPartialPagination.push(url);
    if (url.includes('page=2')) throw new Error('404');
    const entries = paginatedEntries.slice(0, 100);
    return {result: {block_height: '88', count: '100', total: '101', validators: entries}};
  }));
  assert.deepEqual(noFallbackAfterPartialPagination, [
    '/215/status/node0/chain-rpc/validators?height=88&page=1&per_page=100',
    '/215/status/node0/chain-rpc/validators?height=88&page=2&per_page=100',
  ]);
  await assert.rejects(networkObservationState.loadCurrentValidatorSet(currentReference, 'chain-a', async (url) => {
    if (url.endsWith('/chain-rpc/status')) return referenceStatusResponse;
    const page = new URL(`https://preview.example${url}`).searchParams.get('page');
    return {result: {block_height: page === '1' ? '88' : '89', count: '1', total: '2', validators: [{address: page === '1' ? 'a'.repeat(40) : 'b'.repeat(40), voting_power: '1'}]}};
  }));
  process.env.NODE_GUARD_NO_LISTEN = '1';
  const guard = require('../../ops/preview/node-observation-guard.mjs');
  assert.equal(guard.validPath(new URL('https://node0.gonka-dev.net/chain-rpc/validators?per_page=100')), true);
  assert.equal(guard.validPath(new URL('https://node0.gonka-dev.net/chain-rpc/validators?height=88&page=1&per_page=100')), true);
  assert.equal(guard.validPath(new URL('https://node0.gonka-dev.net/chain-rpc/validators?per_page=100&page=2&height=88')), true);
  for (const query of [
    'height=88&per_page=100', 'height=88&page=0&per_page=100', 'height=88&page=101&per_page=100',
    'height=88&page=2&per_page=50', 'height=88&page=2&per_page=100&extra=1',
    'height=88&height=89&page=1&per_page=100', 'height=0&page=1&per_page=100', 'height=88&page=2&per_page=100&',
  ]) assert.equal(guard.validPath(new URL(`https://node0.gonka-dev.net/chain-rpc/validators?${query}`)), false, query);
  await assert.rejects(networkObservationState.loadCurrentValidatorSet({...currentReference, height: 87}, 'chain-a', async (url) => {
    if (url.endsWith('/chain-rpc/status')) return {...referenceStatusResponse, result: {...referenceStatusResponse.result,
      sync_info: {...referenceStatusResponse.result.sync_info, latest_block_height: '87'}}};
    return currentSetResponse;
  }));
  let invalidReferenceFetched = false;
  await assert.rejects(networkObservationState.loadCurrentValidatorSet({...currentReference, height: 0}, 'chain-a', async () => { invalidReferenceFetched = true; return currentSetResponse; }));
  assert.equal(invalidReferenceFetched, false);
  const verifiedSet = networkObservationState.validatorSet(currentSetResponse, 88, 'chain-a', 'chain-a');
  const healthyPeer = hostState.classify({...observedPeer, validatorKnown: true,
    votingPower: networkObservationState.currentVotingPower('A'.repeat(40), verifiedSet)});
  const stalePeer = hostState.classify({...observedPeer, validatorKnown: true,
    votingPower: networkObservationState.currentVotingPower('B'.repeat(40), verifiedSet),
    blocksBehind: 24, referenceAgrees: false, blockAgeSeconds: 300, progressing: false});
  assert.equal(healthyPeer.primaryLabel, 'Validating');
  assert.equal(stalePeer.primaryLabel, 'Active');
  assert.equal(networkObservationState.effectiveValidatorCount([healthyPeer, stalePeer]), 1);
  const noReferencePower = networkObservationState.currentVotingPower('A'.repeat(40), null);
  const unverifiedPeer = hostState.classify({...observedPeer,
    validatorKnown: noReferencePower !== null, votingPower: noReferencePower,
    referenceKnown: false, referenceAgrees: false});
  assert.equal(unverifiedPeer.syncLabel, 'Pending observation');
  assert.equal(networkObservationState.effectiveValidatorCount([unverifiedPeer]), 0);
  const wrongChainPeer = hostState.classify({...observedPeer,
    validatorKnown: false, votingPower: undefined,
    referenceKnown: false, referenceAgrees: false,
    chainDiagnostic: 'Configured chain mismatch: expected chain-a, observed chain-b'});
  assert.equal(wrongChainPeer.primaryLabel, 'Active');
  assert.equal(wrongChainPeer.votingPower, 'Unavailable');
  assert.equal(wrongChainPeer.syncLabel, 'Pending observation');
  assert.match(wrongChainPeer.reason, /Configured chain mismatch/);
  assert.equal(networkObservationState.effectiveValidatorCount([wrongChainPeer]), 0);
  assert.equal(hostState.classify({...observedPeer, validatorKnown: true,
    votingPower: observation.status.result.validator_info.voting_power}).votingPower, '42');
  await assert.rejects(networkObservationState.observeRpc('/status/node', id,
    async () => { throw new Error('HTTP 503'); }), /HTTP 503/);
  await assert.rejects(networkObservationState.observeRpc('/status/node', 'd'.repeat(40),
    async () => status), /identity mismatch/);
  const failedEndpoint = hostState.classify({networkObserved: true,
    endpointState: 'unavailable', endpointDiagnostic: 'HTTP 503'});
  assert.equal(failedEndpoint.primaryLabel, 'Unavailable');
  const recoveredEndpoint = hostState.classify({...observedPeer,
    validatorKnown: true, votingPower: '42'});
  assert.equal(recoveredEndpoint.primaryLabel, 'Validating');
  assert.equal(recoveredEndpoint.syncLabel, 'Synced');
}
testRpcObservation().then(() => {
  childProcess.execFileSync(process.execPath,
    [path.join(__dirname, 'test-node-activity.js'), siteBuild], {stdio: 'inherit'});
  childProcess.execFileSync(
    process.execPath,
    [path.join(__dirname, 'test-site-current-voting-power-browser.mjs'), siteBuild],
    { cwd: path.join(__dirname, '..'), stdio: 'inherit' },
  );
  fs.rmSync(siteBuild, { recursive: true, force: true });
  console.log('PASS gateway public-site state contract');
}).catch((error) => { console.error(error); process.exitCode = 1; });
