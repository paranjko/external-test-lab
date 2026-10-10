import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const state = await mkdtemp(path.join(tmpdir(), "gdc-network-observer-"));
const bin = path.join(state, "bin");
const seedId = "a".repeat(40);
await mkdir(bin);
await writeFile(path.join(bin, "curl"), `#!/usr/bin/env bash
set -Eeuo pipefail
[[ "\${GDC_FIXTURE_UNAVAILABLE:-false}" != true ]] || exit 22
url="\${!#}"
case "\$url" in
  https://fixture.test/bootstrap.json) printf '%s\\n' '{"seeds":[{"node_id":"${seedId}","rpc":"https://node0.gonka-dev.net/chain-rpc"}]}' ;;
  https://node0.gonka-dev.net/chain-rpc/net_info) printf '%s\\n' '{"result":{"peers":[]}}' ;;
  https://node0.gonka-dev.net/v1/versions) printf '%s\\n' '{"api_version":{"application_name":"decentralized-api","version":"v1","commit":"a"},"node_version":{"application_name":"inference-chain","version":"v1","commit":"b"},"mlnodes":[{"node_id":"model:account","version":"3.0.16"}],"timestamp":"2026-10-07T00:00:00Z"}' ;;
  https://node0.gonka-dev.net/chain-rpc/status) printf '%s\\n' '{"result":{"node_info":{"id":"${seedId}","network":"gonka-devnet-community","version":"0.38.19"},"validator_info":{"address":"${'b'.repeat(40)}"},"sync_info":{"latest_block_height":"42","latest_block_time":"2026-10-07T00:00:00Z","catching_up":false}}}' ;;
  https://node0.gonka-dev.net/chain-api/cosmos/base/tendermint/v1beta1/node_info) printf '%s\\n' '{"application_version":{"name":"inference-chain","version":"v1","git_commit":"b"}}' ;;
  https://node0.gonka-dev.net/devshard/healthz) printf '%s\\n' '[]' ;;
  *) exit 22 ;;
esac
`);
await chmod(path.join(bin, "curl"), 0o755);

function invoke(argument, unavailable = false) {
  return new Promise((resolve, reject) => {
    const child = spawn("/usr/bin/bash", [path.join(root, "04-ops/network-observer.sh"), argument], {
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        GDC_NETWORK_OBSERVATION_STATE_DIR: state,
        GDC_NETWORK_BOOTSTRAP_URL: "https://fixture.test/bootstrap.json",
        GDC_NETWORK_CHAIN_ID: "fixture-chain",
        GDC_FIXTURE_UNAVAILABLE: String(unavailable),
      },
      stdio: ["ignore", "pipe", "ignore"],
    });
    let stdout = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.on("error", reject);
    child.on("exit", (code) => resolve({ code, stdout }));
  });
}

try {
  const collected = await invoke("--collect");
  assert.equal(collected.code, 0);
  assert.equal(JSON.parse(collected.stdout).nodes[0].node_id, seedId);
  assert.equal((await invoke("--refresh")).code, 0);
  const snapshot = JSON.parse(await readFile(path.join(state, "network.json"), "utf8"));
  assert.equal(snapshot.schema_version, 1);
  assert.equal(snapshot.chain_id, "fixture-chain");
  assert.equal(snapshot.nodes.length, 1);
  assert.equal(snapshot.nodes[0].node_id, seedId);
  assert.equal(snapshot.nodes[0].active, true);
  assert.equal(snapshot.nodes[0].components.chain_rpc.latest_block_height, 42);
  assert.equal(snapshot.nodes[0].components.chain_rpc.validator_address, 'b'.repeat(40));
  assert.equal(snapshot.nodes[0].components.versions.node_version.version, "v1");
  assert.deepEqual(snapshot.nodes[0].components.versions.mlnodes, [{node_id:"model:account",version:"3.0.16"}]);
  assert.notEqual((await invoke("--refresh", true)).code, 0);
  assert.deepEqual(JSON.parse(await readFile(path.join(state, "network.json"), "utf8")), snapshot);
  console.log("PASS cached network observation derives nodes and component versions from bootstrap topology without participant registry");
} finally {
  await rm(state, { recursive: true, force: true });
}
