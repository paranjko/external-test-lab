const assert = require('node:assert/strict');
const path = require('node:path');
const state = require(path.resolve(process.argv[2], 'network-observation-state.js'));

async function test() {
  const requests = [];
  const evidence = await state.loadActivity('/node', async (url) => {
    requests.push(url);
    if (url.endsWith('/epoch_info')) return {latest_epoch: {index: '7', poc_start_block_height: '100'},
      is_confirmation_poc_active: true, active_confirmation_poc_event: {
        generation_start_height: '130', phase: 'CONFIRMATION_POC_VALIDATION'}};
    if (url.endsWith('/all_poc_v2_store_commits/100')) return {commits: [{participant_address: 'alice', model_id: 'qwen', count: '32'}]};
    if (url.endsWith('/all_poc_v2_store_commits/130')) return {commits: []};
    if (url.endsWith('/poc_v2_validations_for_stage/100')) return {poc_validation: [{poc_validation: [
      {participant_address: 'alice', validator_participant_address: 'bob', validated_weight: '4', poc_stage_start_block_height: '100'},
      {participant_address: 'alice', validator_participant_address: 'charlie', validated_weight: '-1', poc_stage_start_block_height: '100'},
      {participant_address: 'alice', validated_weight: '9', poc_stage_start_block_height: '99'},
    ]}]};
    throw new Error('fixture unavailable');
  });
  assert.equal(requests.length, 5, 'one epoch and two reads per stage, shared by all cards');
  assert.equal(state.activityState(evidence, 'alice').poc.label, '1 accept · 1 reject');
  assert.match(state.activityState(evidence, 'alice').poc.detail, /votes are not the final chain decision/);
  assert.equal(state.activityState(evidence, 'alice').cpoc.label, 'No commit yet');
  assert.equal(state.activityState(evidence, 'bob').poc.label, 'No commit yet');
  assert.equal(state.activityState(evidence, null).poc.label, 'Not reported');
  assert.equal(state.activityState(evidence, 'alice', evidence.observedAt + 90001).poc.label, 'Not reported');
  assert.equal(state.activityState({...evidence, confirmationActive: false}, 'alice').cpoc.label, 'No active event');
  assert.equal(state.activityState({...evidence, poc: {height: '100', commits: null, votes: null}}, 'alice').poc.label, 'Not reported');
  assert.equal(state.activityState({...evidence, poc: {...evidence.poc, votes: null}}, 'alice').poc.label, 'Committed');
  assert.equal(state.inferenceState(null).label, 'Not reported');
  assert.equal(state.inferenceState({state: 'observed', runtimes: []}).label, 'No runtime');
  const running = state.inferenceState({state: 'observed', runtimes: [{name: 'v5', status: 'running'}]});
  assert.equal(running.label, 'Runtime running');
  assert.match(running.detail, /successful inference request are not verified/);
  const reference = {nodeId: 'a'.repeat(40), statusBase: '/node', identityVerified: true, chainId: 'test', height: 7,
    catchingUp: false, blockTimeMs: 1000};
  assert.equal(state.selectFreshReference([reference], 'test', 2000), reference);
  assert.equal(state.selectFreshReference([{...reference, chainId: 'wrong'}], 'test', 2000), null);
  assert.equal(state.selectFreshReference([{...reference, identityVerified: false}], 'test', 2000), null);
  assert.equal(state.selectFreshReference([reference], 'test', 92000), null);
  console.log('PASS shared PoC/cPoC stage observations, participant isolation, expiry, runtime/readiness distinction and first-load reference');
}
test().catch((error) => {console.error(error); process.exitCode = 1;});
