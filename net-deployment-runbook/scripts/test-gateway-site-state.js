#!/usr/bin/env node
const assert = require('node:assert/strict');
const state = require('../04-ops/site/gateway-state.js');
const now = Date.parse('2026-08-06T10:30:00Z');
const readyProbe = { state: 'READY', checked_at: '2026-08-06T10:29:50Z', http_status: 200 };
const failedProbe = { state: 'UNAVAILABLE', checked_at: '2026-08-06T10:29:50Z', http_status: 429 };

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
assert.equal(state.classify({ mode: 'gateway', runtimes: 1, devshards: [] }, 1, readyProbe, now).state, 'UNAVAILABLE');

const zeroCapacity = {
  mode: 'gateway',
  runtimes: 6,
  capacity: { total_weight: 0, baseline_weight: 438, lost_weight: 438, available_percent: 0 },
  devshards: [{ ...activeShard, chain_phase: 'PoCValidate', block_reason: 'poc' }],
};
assert.equal(state.classify(zeroCapacity, 1, failedProbe, now).state, 'UNAVAILABLE');
assert.equal(state.classify(zeroCapacity, 1, readyProbe, now).state, 'AVAILABLE');

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

console.log('PASS gateway public-site state contract');
