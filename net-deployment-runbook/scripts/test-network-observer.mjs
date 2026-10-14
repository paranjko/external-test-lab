import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const state = await mkdtemp(path.join(tmpdir(), "gdc-network-observer-"));
const bin = path.join(state, "bin");
const livePeerId = "c".repeat(40);
await mkdir(bin);
await writeFile(path.join(bin, "curl"), `#!/usr/bin/env bash
set -Eeuo pipefail
[[ "\${GDC_FIXTURE_UNAVAILABLE:-false}" != true ]] || exit 22
url="\${!#}"
if [[ "\${GDC_FIXTURE_HTTP_SEED:-false}" == true ]]; then
  url="$(printf '%s' "$url" | sed 's#http://node0.gonka-dev.net:8000#https://node0.gonka-dev.net#')"
fi
printf '%s\\n' "\$url" >>"\${GDC_FIXTURE_LOG}"
if [[ "\$url" == https://api.fixture.test/chain-rpc/status ]]; then
  printf '{"result":{"node_info":{"network":"%s"}}}\\n' "\${GDC_FIXTURE_API_CHAIN_ID:-fixture-chain}"
  exit 0
fi
if [[ "\$url" == https://api.fixture.test/* ]]; then
  url="https://node0.gonka-dev.net\${url#https://api.fixture.test}"
fi
case "\$url" in
  */current_epoch_group_data)
    [[ "$*" == *'x-cosmos-block-height: 42'* ]] || exit 96
    if [[ "\${GDC_FIXTURE_MODELS:-}" == unavailable ]]; then exit 22; fi
    printf '%s\\n' '{"epoch_group_data":{"epoch_index":"6","effective_block_height":"35","sub_group_models":["Qwen/Fixture","Qwen/Empty"]}}' ;;
  *'/epoch_group_data/6?model_id=Qwen%2FFixture')
    [[ "$*" == *'x-cosmos-block-height: 42'* ]] || exit 96
    case "\${GDC_FIXTURE_MODELS:-}" in
      partial) exit 22 ;;
      mismatch) printf '%s\\n' '{"epoch_group_data":{"epoch_index":"7","model_id":"Wrong","validation_weights":[]}}' ;;
      *) printf '%s\\n' '{"epoch_group_data":{"epoch_index":"6","model_id":"Qwen/Fixture","effective_block_height":"0","validation_weights":[{"member_address":"gonka1fixtureaccount","weight":"31"},{"member_address":"gonka1zero","weight":"0"}]}}' ;;
    esac ;;
  *'/epoch_group_data/6?model_id=Qwen%2FEmpty') printf '%s\\n' '{"epoch_group_data":{"epoch_index":"6","model_id":"Qwen/Empty","validation_weights":[]}}' ;;
  https://fixture.test/bootstrap.json|https://fixture.test/fixture-chain/bootstrap.json) if [[ "\${GDC_FIXTURE_HTTP_SEED:-false}" == true ]]; then printf '%s\\n' '{"chain_id":"fixture-chain","seeds":[{"node_id":"stale-bootstrap-id","rpc":"http://node0.gonka-dev.net:8000/chain-rpc"}]}'; else printf '%s\\n' '{"chain_id":"fixture-chain","seeds":[{"node_id":"stale-bootstrap-id","rpc":"https://node0.gonka-dev.net/chain-rpc"}]}'; fi ;;
  https://node0.gonka-dev.net/chain-rpc/net_info) printf '%s\\n' '{"result":{"n_peers":"1","peers":[{"node_info":{"id":"${livePeerId}","listen_addr":"tcp://node0.gonka-dev.net:26656"},"remote_ip":"203.0.113.11"}]}}' ;;
  https://ipwho.is/203.0.113.11) printf '%s\\n' '{"success":true,"city":"Fixture City","country":"Fixtureland","latitude":48.15,"longitude":17.11,"connection":{"isp":"Fixture ISP"}}' ;;
  https://node0.gonka-dev.net/v1/versions) printf '%s\\n' '{"api_version":{"application_name":"decentralized-api","version":"v1","commit":"a"},"node_version":{"application_name":"inference-chain","version":"v1","commit":"b"},"mlnodes":[{"node_id":"model:account","version":"3.0.16"}],"timestamp":"2026-10-07T00:00:00Z"}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/models_all) printf '%s\\n' '{"model":[{"id":"Qwen/Fixture","v_ram":"24"}]}' ;;
  https://node0.gonka-dev.net/chain-rpc/status) printf '%s\\n' '{"result":{"node_info":{"id":"${livePeerId}","network":"fixture-chain","version":"0.38.19"},"validator_info":{"address":"${'b'.repeat(40)}"},"sync_info":{"latest_block_height":"42","latest_block_time":"2026-10-07T00:00:00Z","catching_up":false}}}' ;;
  'https://node0.gonka-dev.net/chain-rpc/block?height=22') printf '%s\\n' '{"result":{"block":{"header":{"chain_id":"fixture-chain","height":"22","time":"2026-10-06T23:59:40Z"}}}}' ;;
  'https://node0.gonka-dev.net/chain-rpc/validators?height=35&page=1&per_page=100') printf '%s\\n' '{"result":{"block_height":"35","count":"1","total":"1","validators":[{"address":"${'b'.repeat(40).toUpperCase()}","voting_power":"29","pub_key":{"value":"fixture"}}]}}' ;;
  'https://node0.gonka-dev.net/chain-rpc/validators?height=25&page=1&per_page=100') printf '%s\\n' '{"result":{"block_height":"25","count":"1","total":"1","validators":[{"address":"${'b'.repeat(40).toUpperCase()}","voting_power":"27","pub_key":{"value":"fixture"}}]}}' ;;
  'https://node0.gonka-dev.net/chain-rpc/validators?height=42&page=1&per_page=100') printf '%s\\n' '{"result":{"block_height":"42","count":"1","total":"1","validators":[{"address":"${'b'.repeat(40).toUpperCase()}","voting_power":"32"}]}}' ;;
  'https://node0.gonka-dev.net/chain-api/productscience/inference/inference/participant?pagination.limit=100') printf '%s\\n' '{"pagination":{"next_key":null},"participant":[{"address":"gonka1fixtureaccount","inference_url":"https://node0.gonka-dev.net","status":"ACTIVE","validator_key":"fixture"}]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/devshard_approved_versions) printf '%s\\n' '{"versions":[{"name":"v3","sha256":"${'d'.repeat(64)}"}]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/hardware_nodes/gonka1fixtureaccount) printf '%s\\n' '{"nodes":{"participant":"gonka1fixtureaccount","hardware_nodes":[{"local_id":"model:account","host":"inference","port":"8080","version":"3.0.16","hardware":[{"type":"Fixture GPU | 24GB","count":1}]}]}}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/epoch_info) printf '%s\\n' '{"latest_epoch":{"index":"7","poc_start_block_height":"40"},"params":{"epoch_params":{"epoch_length":"100"}},"is_confirmation_poc_active":false}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/6) printf '%s\\n' '{"epoch_group_data":{"epoch_index":"6","poc_start_block_height":"30","effective_block_height":"35","validation_weights":[{"member_address":"gonka1fixtureaccount","weight":"31","confirmation_weight":"29","reputation":100}]}}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/epoch_group_data/5) printf '%s\\n' '{"epoch_group_data":{"epoch_index":"5","poc_start_block_height":"20","effective_block_height":"25","validation_weights":[{"member_address":"gonka1fixtureaccount","weight":"27","confirmation_weight":"27","reputation":100}]}}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/active_confirmation_poc_event) if [[ "\${GDC_FIXTURE_CPOC_ACTIVE:-false}" == true ]]; then printf '%s\\n' '{"is_active":true,"event":{"epoch_index":"7","event_sequence":"2","trigger_height":"41","generation_start_height":"42","phase":"CONFIRMATION_POC_VALIDATION"}}'; else printf '%s\\n' '{"is_active":false,"event":null}'; fi ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/confirmation_poc_events/7) printf '%s\\n' '{"events":[]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/confirmation_poc_events/6) printf '%s\\n' '{"events":[{"epoch_index":"6","event_sequence":"0","trigger_height":"31","generation_start_height":"32","phase":"CONFIRMATION_POC_COMPLETED"}]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/confirmation_poc_events/5|https://node0.gonka-dev.net/chain-api/productscience/inference/inference/confirmation_poc_events/4) printf '%s\\n' '{"events":[]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/all_poc_v2_store_commits/40) printf '%s\\n' '{"commits":[{"participant_address":"gonka1fixtureaccount","count":1}]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/all_poc_v2_store_commits/30) printf '%s\\n' '{"commits":[{"participant_address":"gonka1fixtureaccount","count":11,"model_id":"fixture-model"}]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/all_poc_v2_store_commits/41) printf '%s\\n' '{"commits":[{"participant_address":"gonka1fixtureaccount","count":2,"model_id":"cpoc-model"}]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/poc_v2_validations_for_stage/40) printf '%s\\n' '{"poc_validation":[]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/poc_v2_validations_for_stage/30) printf '%s\\n' '{"poc_validation":[{"participant":"gonka1fixtureaccount","poc_validation":[{"participant_address":"gonka1fixtureaccount","validator_participant_address":"gonka1fixtureaccount","poc_stage_start_block_height":"30","validated_weight":"31","model_id":"fixture-model"},{"participant_address":"gonka1fixtureaccount","validator_participant_address":"gonka1fixtureaccount","poc_stage_start_block_height":"30","validated_weight":"-1","model_id":"fixture-model"}]}]}' ;;
  https://node0.gonka-dev.net/chain-api/productscience/inference/inference/poc_v2_validations_for_stage/41) printf '%s\\n' '{"poc_validation":[{"participant":"gonka1fixtureaccount","poc_validation":[{"participant_address":"gonka1fixtureaccount","validator_participant_address":"gonka1fixtureaccount","poc_stage_start_block_height":"41","validated_weight":"32","model_id":"cpoc-model"}]}]}' ;;
  https://node0.gonka-dev.net/chain-api/cosmos/base/tendermint/v1beta1/node_info) if [[ "\${GDC_FIXTURE_NODE_INFO_UNAVAILABLE:-false}" == true ]]; then printf '%s\\n' 'curl: (22) The requested URL returned error: 403' >&2; exit 22; else printf '%s\\n' '{"application_version":{"name":"inference-chain","version":"v1","git_commit":"b"}}'; fi ;;
  https://node0.gonka-dev.net/devshard/healthz)
    if [[ "\${GDC_FIXTURE_DEVSHARD:-}" == v3 ]]; then
      printf '%s\\n' '[{"name":"v3","status":"running","sha256":"${'d'.repeat(64)}"},{"name":"v4.1","status":"stopped"}]'
    else
      printf '%s\\n' '[{"name":"v3","status":"running","sha256":"${'d'.repeat(64)}","binary_version":"v3"},{"name":"v4.1","status":"running","sha256":"${'e'.repeat(64)}","binary_version":"v4.1.3"}]'
    fi ;;
  https://node0.gonka-dev.net/devshard/stats/shards)
    case "\${GDC_FIXTURE_DEVSHARD:-}" in
      unavailable) printf '%s\\n' 'curl: (22) The requested URL returned error: 404' >&2; exit 22 ;;
      malformed) printf '%s\\n' '{"active_escrows":null}' ;;
      *) printf '%s\\n' '{"protocol_version":"v4.1","binary_version":"v4.1.3","current_epoch_id":7,"cached_at":1791870297,"cache_ttl_seconds":60,"active_escrows":["52"],"shards":[{"escrow_id":"52","epoch_id":7}]}' ;;
    esac ;;
  *) exit 22 ;;
esac
`);
await chmod(path.join(bin, "curl"), 0o755);

function invoke(argument, unavailable = false, request = "", cpocActive = false, httpSeed = false, devshard = "", options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn("/usr/bin/bash", [path.join(root, "04-ops/network-observer.sh"), argument], {
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        GDC_NETWORK_OBSERVATION_STATE_DIR: state,
        GDC_NETWORK_BOOTSTRAP_URL: "https://fixture.test/bootstrap.json",
        GDC_NETWORK_BOOTSTRAP_ORIGIN: "https://fixture.test",
        GDC_NETWORK_CHAIN_ID: "fixture-chain",
        GDC_NETWORK_CHAIN_API_ORIGIN: options.chainApiOrigin ?? "",
        GDC_FIXTURE_LOG: path.join(state, "curl.log"),
        GDC_FIXTURE_MODELS: options.models ?? "",
        GDC_FIXTURE_UNAVAILABLE: String(unavailable),
        GDC_FIXTURE_CPOC_ACTIVE: String(cpocActive),
        GDC_FIXTURE_HTTP_SEED: String(httpSeed),
        GDC_FIXTURE_DEVSHARD: devshard,
        GDC_FIXTURE_API_CHAIN_ID: options.apiChainId ?? "fixture-chain",
        GDC_FIXTURE_NODE_INFO_UNAVAILABLE: String(options.nodeInfoUnavailable ?? false),
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.stdin.end(request);
    child.on("error", reject);
    child.on("exit", (code) => resolve({ code, stdout, stderr }));
  });
}

try {
  const pending = await invoke("--serve", false, "GET /status/network?chainId=fixture-chain HTTP/1.1\r\nHost: fixture\r\n\r\n");
  assert.equal(pending.code, 0, pending.stderr);
  assert.match(pending.stdout, /^HTTP\/1\.1 202 Accepted\r?\n/);
  assert.equal(
    JSON.parse(pending.stdout.split(/\r?\n\r?\n/, 2)[1]).state,
    "observation_pending",
  );
  assert.equal(await readFile(path.join(state, "curl.log"), "utf8").catch(() => ""), "");
  assert.equal((await invoke("--refresh-requested")).code, 0);
  const collected = await invoke("--collect");
  assert.equal(collected.code, 0, collected.stderr);
  assert.equal(JSON.parse(collected.stdout).nodes[0].node_id, livePeerId);
  assert.equal((await invoke("--refresh")).code, 0);
  const snapshot = JSON.parse(await readFile(path.join(state, "network.json"), "utf8"));
  assert.equal(snapshot.schema_version, 1);
  assert.equal(snapshot.chain_id, "fixture-chain");
  assert.equal(snapshot.nodes.length, 1);
  assert.equal(snapshot.nodes[0].node_id, livePeerId);
  assert.equal(snapshot.nodes[0].active, true);
  assert.equal(snapshot.nodes[0].components.chain_rpc.latest_block_height, 42);
  assert.equal(snapshot.nodes[0].components.chain_rpc.validator_address, 'b'.repeat(40));
  assert.deepEqual(snapshot.nodes[0].components.peers, {
    state: "observed", source_endpoint: "https://node0.gonka-dev.net/chain-rpc/net_info",
    observed_at: snapshot.nodes[0].components.peers.observed_at, count: 1,
  });
  assert.equal(snapshot.nodes[0].components.versions.node_version.version, "v1");
  assert.deepEqual(snapshot.nodes[0].components.versions.mlnodes, [{node_id:"model:account",version:"3.0.16"}]);
  assert.deepEqual(snapshot.nodes[0].components.models.models, [{id:"Qwen/Fixture",v_ram:"24"}]);
  assert.deepEqual(snapshot.nodes[0].components.devshard, {
    state: "observed", source_endpoint: "https://node0.gonka-dev.net/devshard/healthz",
    observed_at: snapshot.nodes[0].components.devshard.observed_at,
    runtimes: [
      {name: "v3", status: "running", sha256: 'd'.repeat(64), binary_version: "v3"},
      {name: "v4.1", status: "running", sha256: 'e'.repeat(64), binary_version: "v4.1.3"},
    ],
    stats: {
      state: "observed", source_endpoint: "https://node0.gonka-dev.net/devshard/stats/shards",
      observed_at: snapshot.nodes[0].components.devshard.stats.observed_at,
      protocol_version: "v4.1", binary_version: "v4.1.3", current_epoch_id: 7,
      cached_at: 1791870297, cache_ttl_seconds: 60, active_escrows: ["52"],
      shards: [{escrow_id: "52", epoch_id: 7}],
    },
  });
  for (const [scenario, statsState, error] of [
    ["v3", "not_exposed", "stats_requires_v4_or_newer_runtime"],
    ["unavailable", "unavailable", "HTTP 404"],
    ["malformed", "unavailable", "invalid_devshard_stats_response"],
  ]) {
    const before = (await readFile(path.join(state, "curl.log"), "utf8")).length;
    const observation = await invoke("--collect", false, "", false, false, scenario);
    assert.equal(observation.code, 0, observation.stderr);
    const health = JSON.parse(observation.stdout).nodes[0].components.devshard;
    assert.equal(health.state, "observed", "a stats error must preserve the health inventory");
    assert.equal(health.stats.state, statsState);
    assert.equal(health.stats.error, error);
    assert.equal(health.stats.active_escrows, undefined, "missing stats must not turn into an empty escrow list");
    if (scenario === "v3") {
      const requests = (await readFile(path.join(state, "curl.log"), "utf8")).slice(before);
      assert.doesNotMatch(requests, /\/devshard\/stats\/shards/, "a stopped v4 runtime must not enable v4 stats requests");
    }
  }
  assert.deepEqual(snapshot.chain.validators, [{address: 'b'.repeat(40).toUpperCase(), voting_power: "32"}]);
  assert.deepEqual(snapshot.chain.model_assignments, {
    state: "observed", epoch_index: "6", effective_block_height: "35", reference_height: 42,
    groups: [
      {model_id: "Qwen/Fixture", state: "observed", participants: [{address: "gonka1fixtureaccount", weight: "31"}]},
      {model_id: "Qwen/Empty", state: "observed", participants: []},
    ],
  }, "effective allocations must exclude zero weight and not use the latest PoC epoch");
  for (const models of ["partial", "mismatch", "unavailable"]) {
    const result = await invoke("--collect", false, "", false, false, "", {models});
    assert.equal(result.code, 0, result.stderr);
    const allocation = JSON.parse(result.stdout).chain.model_assignments;
    assert.equal(allocation.state, models === "unavailable" ? "unavailable" : "partial");
    if (models !== "unavailable") {
      assert.deepEqual(allocation.groups[0], {model_id: "Qwen/Fixture", state: "unavailable"});
      assert.deepEqual(allocation.groups[1].participants, []);
    }
  }
  assert.deepEqual(snapshot.chain.approved_devshards, [{name: "v3", sha256: 'd'.repeat(64)}]);
  assert.deepEqual(snapshot.chain.hardware_nodes, [{
    address: "gonka1fixtureaccount",
    nodes: [{local_id:"model:account",host:"inference",port:"8080",version:"3.0.16",hardware:[{type:"Fixture GPU | 24GB",count:1}]}],
  }]);
  assert.deepEqual(snapshot.chain.activity.epoch, {
    latest_epoch: {index: "7", poc_start_block_height: "40", end_height: "140", blocks_remaining: "98"},
    block_interval_seconds: 1,
    estimated_remaining_seconds: 98,
    is_confirmation_poc_active: false,
    active_confirmation_poc_event: null,
  });
  assert.deepEqual(snapshot.chain.activity.cpoc, {
    state: "observed", active: false, event: null, commits: null, votes: null,
    recent_events_state: "observed",
    recent_events: [{
      epoch_index: "6", event_sequence: "0", trigger_height: "31",
      generation_start_height: "32", phase: "CONFIRMATION_POC_COMPLETED",
    }],
  });
  assert.deepEqual(snapshot.chain.activity.finalized_epoch, {
    state: "observed",
    epoch_index: "6",
    poc_start_block_height: "30",
    effective_block_height: "35",
    previous_epoch_index: "5",
    previous_effective_block_height: "25",
    poc_commits: [{participant_address: "gonka1fixtureaccount", count: "11", model_id: "fixture-model"}],
    poc_votes: [
      {participant_address: "gonka1fixtureaccount", validator_participant_address: "gonka1fixtureaccount", poc_stage_start_block_height: "30", validated_weight: "31", model_id: "fixture-model"},
      {participant_address: "gonka1fixtureaccount", validator_participant_address: "gonka1fixtureaccount", poc_stage_start_block_height: "30", validated_weight: "-1", model_id: "fixture-model"},
    ],
    cpoc_events: [{event_sequence: "0", trigger_height: "31", phase: "CONFIRMATION_POC_COMPLETED"}],
    participants: [{
      participant_address: "gonka1fixtureaccount",
      validation_weight: "31",
      confirmation_weight: "29",
      reputation: 100,
      effective_validator: {state: "observed", voting_power: "29"},
      previous_effective_validator: {state: "observed", voting_power: "27"},
    }],
  });
  const activeCpoc = await invoke("--collect", false, "", true);
  assert.equal(activeCpoc.code, 0, activeCpoc.stderr);
  assert.deepEqual(JSON.parse(activeCpoc.stdout).chain.activity.cpoc, {
    state: "observed",
    active: true,
    event: {
      epoch_index: "7", event_sequence: "2", trigger_height: "41",
      generation_start_height: "42", phase: "CONFIRMATION_POC_VALIDATION",
    },
    commits: {commits: [{participant_address: "gonka1fixtureaccount", count: 2, model_id: "cpoc-model"}]},
    votes: {poc_validation: [{
      participant: "gonka1fixtureaccount",
      poc_validation: [{
        participant_address: "gonka1fixtureaccount", validator_participant_address: "gonka1fixtureaccount",
        poc_stage_start_block_height: "41", validated_weight: "32", model_id: "cpoc-model",
      }],
    }]},
    recent_events_state: "observed",
    recent_events: [{
      epoch_index: "6", event_sequence: "0", trigger_height: "31",
      generation_start_height: "32", phase: "CONFIRMATION_POC_COMPLETED",
    }],
  });
  const httpSeed = await invoke("--collect", false, "", false, true);
  assert.equal(httpSeed.code, 0, httpSeed.stderr);
  assert.equal(JSON.parse(httpSeed.stdout).nodes[0].dapi_url, "http://node0.gonka-dev.net:8000");
  const centralLogOffset = (await readFile(path.join(state, "curl.log"), "utf8")).length;
  const central = await invoke("--collect", false, "", false, false, "", {
    chainApiOrigin: "https://api.fixture.test",
    nodeInfoUnavailable: true,
  });
  assert.equal(central.code, 0, central.stderr);
  const centralSnapshot = JSON.parse(central.stdout);
  assert.equal(centralSnapshot.chain.api_source_endpoint, "https://api.fixture.test");
  assert.equal(centralSnapshot.chain.source_endpoint, "https://node0.gonka-dev.net",
    "the chain reference and per-node RPC source must retain peer provenance");
  assert.equal(centralSnapshot.nodes[0].components.models.source_endpoint,
    "https://api.fixture.test/chain-api/productscience/inference/inference/models_all");
  assert.deepEqual(centralSnapshot.nodes[0].components.inferenced, {
    state: "observed",
    source_endpoint: "https://node0.gonka-dev.net/v1/versions",
    observed_at: centralSnapshot.nodes[0].components.inferenced.observed_at,
    application_name: "inference-chain",
    version: "v1",
    commit: "b",
    go_version: null,
  }, "blocked node_info must fall back to that peer's own version response");
  assert.equal(centralSnapshot.nodes[0].components.chain_rpc.source_endpoint,
    "https://node0.gonka-dev.net/chain-rpc/status");
  assert.equal(centralSnapshot.nodes[0].components.peers.source_endpoint,
    "https://node0.gonka-dev.net/chain-rpc/net_info");
  assert.deepEqual(centralSnapshot.chain.validators, snapshot.chain.validators,
    "validator identity and power must continue to come from per-node RPC");
  const centralRequests = (await readFile(path.join(state, "curl.log"), "utf8")).slice(centralLogOffset);
  assert.match(centralRequests, /https:\/\/api\.fixture\.test\/chain-rpc\/status/,
    "the central API chain must be validated before its data is used");
  assert.match(centralRequests, /https:\/\/api\.fixture\.test\/chain-api\/productscience\/inference\/inference\/epoch_info/);
  assert.match(centralRequests, /https:\/\/api\.fixture\.test\/chain-rpc\/block\?height=22/,
    "block interval sampling must use the configured central RPC origin");
  assert.match(centralRequests, /https:\/\/node0\.gonka-dev\.net\/chain-rpc\/validators\?height=42/,
    "per-node validator snapshots must stay on the peer RPC origin");
  assert.match(centralRequests, /https:\/\/node0\.gonka-dev\.net\/chain-api\/cosmos\/base\/tendermint\/v1beta1\/node_info/,
    "node identity/version APIs must not be redirected to the central host");
  const mismatchLogOffset = (await readFile(path.join(state, "curl.log"), "utf8")).length;
  const mismatch = await invoke("--collect", false, "", false, false, "", {
    chainApiOrigin: "https://api.fixture.test",
    apiChainId: "other-chain",
  });
  assert.notEqual(mismatch.code, 0, "a central chain ID mismatch must reject collection");
  const mismatchRequests = (await readFile(path.join(state, "curl.log"), "utf8")).slice(mismatchLogOffset);
  assert.match(mismatchRequests, /https:\/\/api\.fixture\.test\/chain-rpc\/status/);
  assert.doesNotMatch(mismatchRequests, /\/chain-api\/|\/chain-rpc\/block/,
    "no global chain data may be accepted after a chain ID mismatch");
  assert.deepEqual(snapshot.nodes[0].geo, {
    latitude: 48.15,
    longitude: 17.11,
    city: "Fixture City",
    country: "Fixtureland",
    isp: "Fixture ISP",
    source: "ip-geolocation",
    observedAt: snapshot.nodes[0].geo.observedAt,
    accuracy: "city",
    resolvedIp: "203.0.113.11",
    locationLabel: "Fixture City, Fixtureland",
  });
  const served = await invoke("--serve", false, "GET /status/network?chainId=fixture-chain HTTP/1.1\r\nHost: fixture\r\n\r\n");
  assert.equal(served.code, 0, served.stderr);
  assert.match(served.stdout, /^HTTP\/1\.1 200 OK\r?\n/, await readFile(path.join(state, "curl.log"), "utf8"));
  assert.equal(JSON.parse(served.stdout.split(/\r?\n\r?\n/, 2)[1]).chain_id, "fixture-chain");
  const invalid = await invoke("--serve", false, "GET /status/network?chainId=bad%2Fchain HTTP/1.1\r\nHost: fixture\r\n\r\n");
  assert.match(invalid.stdout, /^HTTP\/1\.1 404 Not Found\r?\n/);
  for (let index = 2; index <= 8; index += 1) {
    const queued = await invoke("--serve", false, `GET /status/network?chainId=queue-${index} HTTP/1.1\r\nHost: fixture\r\n\r\n`);
    assert.match(queued.stdout, /^HTTP\/1\.1 202 Accepted\r?\n/);
  }
  const saturated = await invoke("--serve", false, "GET /status/network?chainId=queue-9 HTTP/1.1\r\nHost: fixture\r\n\r\n");
  assert.match(saturated.stdout, /^HTTP\/1\.1 429 Too Many Requests\r?\n/);
  assert.notEqual((await invoke("--refresh", true)).code, 0);
  assert.deepEqual(JSON.parse(await readFile(path.join(state, "network.json"), "utf8")), snapshot);
  console.log("PASS cached network observation derives nodes and component versions from bootstrap topology without participant registry");
} finally {
  await rm(state, { recursive: true, force: true });
}
