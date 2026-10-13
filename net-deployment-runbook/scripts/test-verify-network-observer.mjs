import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { validateStatusPrefix, verifyNetworkObserver } from "./verify-network-observer.mjs";

let mode = "healthy";
let snapshot;
const upgradedSockets = new Set();
const requestedPaths = [];
const server = createServer((request, response) => {
  requestedPaths.push(request.url);
  if (mode === "http-timeout") return;
  response.setHeader("Content-Type", "application/json");
  if (mode === "http-404") {
    response.writeHead(404).end('{"error":"not_found"}');
    return;
  }
  if (mode === "http-bad-json") {
    response.end("{");
    return;
  }
  if (mode === "pending") {
    response.writeHead(202).end('{"state":"observation_pending","chain_id":"fixture-chain"}');
    return;
  }
  const body = mode === "legacy" ? { ...snapshot, chain: undefined } : snapshot;
  response.end(JSON.stringify(body));
});
server.on("upgrade", (request, socket) => {
  requestedPaths.push(request.url);
  upgradedSockets.add(socket);
  socket.on("close", () => upgradedSockets.delete(socket));
  if (mode === "ws-404") {
    socket.end("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
    return;
  }
  if (mode === "ws-timeout") return;
  const key = request.headers["sec-websocket-key"];
  const accept = awaitableAccept(key);
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const envelope = mode === "ws-bad-envelope"
    ? { type: "other", snapshot }
    : { type: "network_snapshot", snapshot: mode === "ws-older"
      ? { ...snapshot, chain: { ...snapshot.chain, observed_at: new Date(Date.now() - 1000).toISOString() } }
      : mode === "ws-newer"
        ? { ...snapshot, chain: { ...snapshot.chain, observed_at: new Date().toISOString() } }
      : snapshot };
  const payload = mode === "ws-bad-json" ? Buffer.from("{") : Buffer.from(JSON.stringify(envelope));
  const header = payload.length < 126
    ? Buffer.from([0x81, payload.length])
    : Buffer.concat([Buffer.from([0x81, 126, payload.length >> 8, payload.length & 0xff])]);
  socket.write(Buffer.concat([header, payload]));
});

function awaitableAccept(key) {
  return createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
}
function currentSnapshot() {
  const observedAt = new Date().toISOString();
  return {
    schema_version: 1,
    chain_id: "fixture-chain",
    observed_at: observedAt,
    nodes: [],
    chain: {
      state: "observed",
      observed_at: observedAt,
      reference: { node_id: "a".repeat(40), height: 123 },
      validators: [],
      participants: [],
      hardware_nodes: [],
      approved_devshards: [],
      activity: {
        epoch: { latest_epoch: { index: "7", poc_start_block_height: "1000" } }, cpoc: {}, finalized_epoch: {},
        commits: { commits: [] }, votes: { poc_validation: [] },
      },
    },
  };
}

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const baseUrl = `http://127.0.0.1:${server.address().port}`;
async function expectFailure(nextMode, pattern, options = {}) {
  mode = nextMode;
  await assert.rejects(verifyNetworkObserver({ baseUrl, timeoutMs: 100, ...options }), pattern);
}
function runCli(nextMode, timeoutMs = 1500) {
  mode = nextMode;
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [
      fileURLToPath(new URL("./verify-network-observer.mjs", import.meta.url)),
      "--base-url", baseUrl,
      "--chain-id", "fixture-chain",
    ], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let expired = false;
    child.stdout.setEncoding("utf8").on("data", (chunk) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => {
      expired = true;
      child.kill("SIGKILL");
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      if (expired) reject(new Error(`CLI failed to exit within ${timeoutMs}ms; killed child ${child.pid}`));
      else resolve({ code, signal, stdout, stderr });
    });
  });
}

try {
  snapshot = currentSnapshot();
  mode = "healthy";
  const result = await verifyNetworkObserver({ baseUrl, chainId: "fixture-chain" });
  assert.equal(result.chainId, "fixture-chain");
  assert.equal(result.observedAt, snapshot.chain.observed_at);
  requestedPaths.length = 0;
  await verifyNetworkObserver({ baseUrl, chainId: "fixture-chain", statusPrefix: "/172/status" });
  assert.equal(requestedPaths[0], "/172/status/network?chainId=fixture-chain");
  assert.equal(requestedPaths[1], "/172/status/network/ws?chainId=fixture-chain");
  for (const invalidPrefix of ["/172/status/../status", "/172/status/../../evil", "/0/status", "/01/status", "/status/../172/status", "//172/status"]) {
    assert.throws(() => validateStatusPrefix(invalidPrefix), /status prefix/);
  }
  assert.equal(validateStatusPrefix("/status"), "/status");
  assert.equal(validateStatusPrefix("/172/status"), "/172/status");

  const cliSuccess = await runCli("healthy");
  assert.equal(cliSuccess.code, 0, cliSuccess.stderr);
  assert.match(cliSuccess.stdout, /PASS production network observer/);
  const cliFailure = await runCli("ws-bad-envelope");
  assert.equal(cliFailure.code, 1, cliFailure.stdout);
  assert.match(cliFailure.stderr, /network_snapshot envelope/);

  await expectFailure("pending", /HTTP 202/);
  await expectFailure("http-404", /HTTP 404/);
  await expectFailure("http-bad-json", /invalid JSON/);
  await expectFailure("legacy", /full chain observation/);

  mode = "healthy";
  snapshot = currentSnapshot();
  snapshot.chain.observed_at = new Date(Date.now() - 91_000).toISOString();
  await assert.rejects(verifyNetworkObserver({ baseUrl }), /full chain observation/);

  snapshot = currentSnapshot();
  snapshot.observed_at = new Date(Date.now() - 91_000).toISOString();
  await assert.rejects(verifyNetworkObserver({ baseUrl }), /snapshot is absent or stale/);
  snapshot = currentSnapshot();
  snapshot.chain.activity.epoch.latest_epoch.index = "";
  await assert.rejects(verifyNetworkObserver({ baseUrl }), /full chain observation/);
  snapshot = currentSnapshot();
  await assert.rejects(verifyNetworkObserver({ baseUrl, chainId: "wrong-chain" }), /chain_id mismatch/);
  await expectFailure("ws-404", /WebSocket observer connection failed|closed before a snapshot/);
  await expectFailure("ws-bad-envelope", /network_snapshot envelope/);
  await expectFailure("ws-bad-json", /JSON|Unexpected/);
  await expectFailure("ws-older", /older than the HTTP snapshot/);
  snapshot.chain.observed_at = new Date(Date.now() - 1000).toISOString();
  mode = "ws-newer";
  const newer = await verifyNetworkObserver({ baseUrl });
  assert(new Date(newer.observedAt).getTime() > new Date(snapshot.chain.observed_at).getTime());
  await expectFailure("ws-timeout", /timed out/);
  await expectFailure("http-timeout", /timeout|timed out/);
  console.log("PASS bounded production HTTP/WebSocket observer verification, including stale, legacy, malformed, wrong-chain, unavailable, and timeout responses");
} finally {
  for (const socket of upgradedSockets) socket.destroy();
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
}
