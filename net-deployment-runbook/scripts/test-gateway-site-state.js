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
const networkObservationState = require(path.join(siteBuild, 'network-observation-state.js'));
const softwareVersions = require(path.join(siteBuild, 'software-versions.js'));
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
  state: 'unknown', stateLabel: 'Wait',
  reason: 'Current validator membership is not verified',
  primaryLabel: 'Wait', primaryClass: 'status unknown',
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
  [{...observedPeer, networkActive: false}, 'Wait'],
  [{...observedPeer, endpointState: 'unavailable'}, 'Wait'],
  [{...observedPeer, observationComplete: true}, 'Wait'],
  [{...observedPeer, endpointState: 'unknown'}, 'Wait'],
  [{networkObserved: true, networkActive: true}, 'Wait'],
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
const noAssignedMlNode = softwareVersions.selectMlNodes({mlnodes: []}, {state: 'observed', nodes: []});
assert.equal(softwareVersions.emptyMlNodeLabel(noAssignedMlNode), 'Not assigned');
const missingMlVersion = softwareVersions.selectMlNodes({mlnodes: [{node_id: 'model:account'}]}, {state: 'observed', nodes: [{local_id: 'stale'}]});
assert.equal(softwareVersions.emptyMlNodeLabel(missingMlVersion), 'Version unavailable');
const unavailableMlInventory = softwareVersions.selectMlNodes(null, {state: 'unavailable', nodes: []});
assert.equal(softwareVersions.emptyMlNodeLabel(unavailableMlInventory), 'Not reported');
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
}).primaryLabel, 'Wait');
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
  [{state: 'observed'}, 'Wait'],
  [{state: 'unavailable', error: 'HTTP 502'}, 'Wait'],
  [{state: 'not_exposed'}, 'Wait'],
  [undefined, 'Wait'],
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
assert.match(siteApp, /function renderEpochOverview\(epoch, reference, cpoc\)/);
assert.match(siteApp, /estimated_remaining_seconds/);
assert.match(siteApp, /recent_events/);
assert.match(siteApp, /function normalizedCpocEvents\(cpoc/);
assert.match(siteApp, /function renderFinalizedEpochResults\(result\)/);
assert.match(siteApp, /effective_block_height/);
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
assert.match(siteApp, /function refreshHardwareInventory/);
assert.match(siteApp, /function reportedSoftwareMetadata/);
assert.match(siteApp, /function softwareInventoryKeys/);
assert.match(siteApp, /\^\(\?:gdc-\)\?\(node\[0-9\]\+\)/);
assert.match(siteApp, /keys\.add\(`gdc-\$\{match\[1\]\}`\)/);
assert.match(siteApp, /reportedSoftwareMetadata\(node, component\)\n\s*\? "Version unavailable"/);
assert.match(siteApp, /hostState\.classify/);
assert.match(siteApp, /data-k="vp"/);
assert.match(siteApp, /<span>voting power<\/span>/);
assert.match(siteApp, /class="metric inferenced" data-k-row="inferenced"/);
assert.match(siteApp, /class="metric dapi" data-k-row="dapi"/);
assert.match(siteApp, /class="metric devshard" data-k-row="devshard"/);
assert.match(siteApp, /function updateDevShards/);
assert.match(siteApp, /function updateMlNodes/);
assert.match(siteApp, /\$\("devshard-versions"\)/);
assert.match(siteApp, /refreshDevShardVersions/);
assert.match(siteApp, /approved_versions/);
assert.match(
  fs.readFileSync(path.join(__dirname, '..', '04-ops/site/src/host-state.js'), 'utf8'),
  /Public endpoint unavailable/,
);
assert.match(siteApp, /class="node-toggle"/);
assert.match(siteApp, /aria-expanded="false"/);
assert.match(siteApp, /class="node-details"/);
assert.match(siteApp, /event.key === "ArrowRight"/);
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
const siteIndex = fs.readFileSync(
  path.join(__dirname, '..', '04-ops', 'site', 'index.html'),
  'utf8',
);
assert.match(siteIndex, /id="epoch-overview"/);
assert.match(siteIndex, /id="epoch-progress-track"[^>]*role="progressbar"/);
assert.match(siteIndex, /id="epoch-cpoc-state"/);
assert.match(siteIndex, /id="epoch-cpoc-detail"/);
assert.match(siteIndex, /id="verification-results"/);
assert.match(siteIndex, /id="verification-poc-result-rows"/);
assert.match(siteIndex, /id="verification-consensus-result-rows"/);
assert.match(readability, /\.epoch-overview \{[\s\S]*grid-template-columns: minmax\(104px, max-content\) minmax\(180px, 1fr\) minmax\(172px, max-content\);/);
assert.match(readability, /\.epoch-progress-track > span \{[\s\S]*background: linear-gradient/);
assert.match(readability, /\.epoch-protocol-state \{[\s\S]*grid-column: 1 \/ -1;/);
assert.match(readability, /\.verification-results-table-shell \{[\s\S]*overflow-x: auto;/);
assert.match(readability, /\.verification-evidence-grid \{[\s\S]*grid-template-columns: repeat\(2, minmax\(0, 1fr\)\);/);
assert.doesNotMatch(readability, /validator-map-encoding-note/);
assert.match(readability, /\.validator-marker-face[\s\S]*background: var\(--validator-marker-fill\)/);
assert.match(readability, /\.validator-map-tooltip li \{[\s\S]*grid-template-columns: minmax\(0,1fr\) max-content;/);
assert.match(readability, /\.validator-map-location-evidence dl \{[\s\S]*grid-template-columns: max-content minmax\(0,1fr\);/);
assert.match(readability, /footer \{[\s\S]*grid-template-columns: max-content minmax\(180px, 1fr\) repeat\(5, max-content\);/);
assert.match(readability, /\.footer-github \{[\s\S]*justify-self: end;[\s\S]*align-self: center;/);
assert.doesNotMatch(readability, /validator-marker-number/);
assert.match(readability, /\.nodes\.compact \.node-toggle:focus-visible \{[\s\S]*outline: 2px solid var\(--lime\);/);
assert.match(readability, /\.nodes\.compact \.metric \{\s*box-sizing: border-box;[\s\S]*max-height: none;[\s\S]*align-items: flex-start;/);
assert.match(readability, /\.nodes\.compact \.metric\.account:not\(\[hidden\]\) \{[\s\S]*grid-template-columns: 72px minmax\(0, 1fr\);/);
assert.match(readability, /@media \(prefers-reduced-motion: reduce\) \{[\s\S]*transition: none;/);

async function testSharedTelegramProjection() {
  const elements = new Map();
  const element = (id) => {
    if (!elements.has(id)) elements.set(id, { dataset: {}, children: [], removeAttribute() {} });
    return elements.get(id);
  };
  let timestamp = 1000000;
  let read = async () => ({ status: 'ok', readiness_projection: snapshot });
  const start = siteApp.indexOf('let telegramStatusFetch =');
  const source = siteApp.slice(start, siteApp.indexOf('const cards', start));
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
  const inferenceTarget = {};
  const card = {querySelector: (selector) => selector.includes('inference') ? inferenceTarget : target};
  const node = {name:'fixture',devShardHealth:{state:'observed',runtimes:[{name:'v5',status:'running',binary_version:'nominal-only',sha256:'claimed-archive'},{name:'v4',status:'running'}]}};
  let timestamp = 1001000;
  let read = async () => ({status:'success',data:{resultType:'vector',result:[observedRuntime]}});
  const source = siteApp.slice(siteApp.indexOf('function updateDevShards('),siteApp.indexOf('function updateMlNodes('));
  const fleet = new Function('GDC_SOFTWARE_VERSIONS','softwareInventoryKeys','Date','json','statusUrl','observedNodes','cards','nodeKey','GDC_NETWORK_OBSERVATION','set',
    `let cardDevShardInventory = new Map(); let devShardInventoryRequest = 0; let devShardInventoryWatermarks = new Map(); ${source}; return {refreshDevShardInventory,renderDevShardInventory};`)(
    softwareIdentity,(item) => [item.name],{now:() => timestamp},(...args) => read(...args),(item) => '/status'+item,
    [node],new Map([['fixture',card]]),(item) => item.name,networkObservationState,
    (item, field, value) => { item.querySelector(`[data-k="${field}"]`).textContent = value; });
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
    if (url.includes('/validators?height=')) throw new Error('HTTP 404');
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
  assert.equal(wrongChainPeer.primaryLabel, 'Wait');
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
  assert.equal(failedEndpoint.primaryLabel, 'Wait');
  const recoveredEndpoint = hostState.classify({...observedPeer,
    validatorKnown: true, votingPower: '42'});
  assert.equal(recoveredEndpoint.primaryLabel, 'Validating');
  assert.equal(recoveredEndpoint.syncLabel, 'Synced');
}
testSharedTelegramProjection().then(testObservedFleetIdentity).then(testRpcObservation).then(() => {
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
