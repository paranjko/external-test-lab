import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = await mkdtemp(path.join(tmpdir(), "gdc-network-observer-http-"));
const server = net.createServer((connection) => {
  liveSockets.add(connection);
  connection.on("close", () => liveSockets.delete(connection));
  const child = spawn("/usr/bin/python3", [path.join(root, "04-ops/network-observer-http.py")], {
    env: {
      ...process.env,
      GDC_NETWORK_OBSERVATION_STATE_DIR: state,
      GDC_NETWORK_OBSERVER_COLLECTOR: path.join(root, "04-ops/network-observer.sh"),
      GDC_NETWORK_CHAIN_ID: "default-chain",
      GDC_NETWORK_DEFAULT_CHAIN_ID: "default-chain",
    },
    stdio: [connection, "ignore", "pipe"],
  });
  child.stderr.on("data", (chunk) => { diagnostics += chunk; });
  child.on("exit", () => connection.end());
});
let diagnostics = "";
const liveSockets = new Set();
const state = path.join(temporary, "state");
await mkdir(path.join(state, "networks"), { recursive: true });
const selected = { schema_version: 1, chain_id: "fixture-chain", observed_at: "2026-10-13T00:00:00Z", nodes: [{ node_id: "peer" }] };
await writeFile(path.join(state, "networks/fixture-chain.json"), JSON.stringify(selected));
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();

function httpRequest(target, method = "GET") {
  return new Promise((resolve, reject) => {
    const request = http.request({ host: "127.0.0.1", port: address.port, path: target, method, agent: false }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => resolve({ status: response.statusCode, headers: response.headers, body }));
    });
    request.setTimeout(8000, () => request.destroy(new Error("fixture HTTP timeout")));
    request.on("error", reject);
    request.end();
  });
}

function rawHttpRequest(request) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection({ host: "127.0.0.1", port: address.port });
    let buffer = Buffer.alloc(0);
    client.setTimeout(8000, () => client.destroy(new Error("fixture raw HTTP timeout")));
    client.on("connect", () => client.write(request));
    client.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      const end = buffer.indexOf("\r\n\r\n");
      if (end < 0) return;
      const status = Number(buffer.subarray(0, end).toString("ascii").split(" ")[1]);
      client.end();
      resolve({ status, body: buffer.subarray(end + 4).toString("utf8") });
    });
    client.on("error", reject);
  });
}

function connectWebSocket(target, origin = "http://fixture", extraHeaders = "") {
  return new Promise((resolve, reject) => {
    const client = net.createConnection({ host: "127.0.0.1", port: address.port });
    let buffer = Buffer.alloc(0);
    const key = Buffer.from("fixture-key-1234").toString("base64");
    client.on("connect", () => client.write(
      `GET ${target} HTTP/1.1\r\nHost: fixture\r\nOrigin: ${origin}\r\n${extraHeaders}Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
    ));
    client.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      const end = buffer.indexOf("\r\n\r\n");
      if (end < 0) return;
      const headers = buffer.subarray(0, end).toString();
      if (!headers.startsWith("HTTP/1.1 101")) {
        reject(new Error(headers));
        client.destroy();
        return;
      }
      resolve({ client, headers, remainder: buffer.subarray(end + 4) });
    });
    client.on("error", reject);
  });
}

function readServerFrame(client, initial = Buffer.alloc(0)) {
  return new Promise((resolve, reject) => {
    let buffer = initial;
    const consume = () => {
      if (buffer.length < 2) return false;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return false;
        length = buffer.readUInt16BE(2); offset = 4;
      } else if (length === 127) {
        reject(new Error("unexpected large frame")); return true;
      }
      if (buffer.length < offset + length) return false;
      resolve({ opcode: buffer[0] & 0x0f, payload: buffer.subarray(offset, offset + length) });
      return true;
    };
    if (consume()) return;
    const onData = (chunk) => { buffer = Buffer.concat([buffer, chunk]); if (consume()) client.off("data", onData); };
    client.on("data", onData);
    client.once("error", reject);
  });
}

try {
  const response = await httpRequest("/status/network?chainId=fixture-chain");
  assert.equal(response.status, 200, diagnostics);
  assert.deepEqual(JSON.parse(response.body), selected);
  assert.equal(response.headers["cache-control"], "no-store");
  const stale = { ...selected, observed_at: "2020-01-01T00:00:00Z" };
  await writeFile(path.join(state, "networks/fixture-chain.json"), JSON.stringify(stale));
  const staleResponse = await httpRequest("/status/network?chainId=fixture-chain");
  assert.equal(JSON.parse(staleResponse.body).observed_at, stale.observed_at,
    "the transport must preserve stale timestamps instead of presenting them as fresh");
  await rm(path.join(state, "networks/fixture-chain.json"));
  const pending = await httpRequest("/status/network?chainId=fixture-chain");
  assert.equal(pending.status, 202);
  assert.deepEqual(JSON.parse(pending.body), { state: "observation_pending", chain_id: "fixture-chain" });
  assert.equal(await readFile(path.join(state, "requests/fixture-chain"), "utf8").then(() => true), true,
    "missing selected-chain data must enqueue only the selected network");
  await writeFile(path.join(state, "networks/fixture-chain.json"), JSON.stringify(selected));
  const absent = await httpRequest("/status/network");
  assert.equal(absent.status, 503);
  const defaultSnapshot = { ...selected, chain_id: "default-chain" };
  await writeFile(path.join(state, "network.json"), JSON.stringify(defaultSnapshot));
  const defaultResponse = await httpRequest("/status/network");
  assert.equal(defaultResponse.status, 200);
  assert.deepEqual(JSON.parse(defaultResponse.body), defaultSnapshot);
  const badMethod = await httpRequest("/status/network", "POST");
  assert.equal(badMethod.status, 405);
  for (const target of ["/wrong", "/status/network?chainId=bad%2Fid", "/status/network?other=x",
    "http://attacker/status/network?chainId=fixture-chain"]) {
    assert.equal((await httpRequest(target)).status, 404, target);
  }
  const malformedAbsoluteTarget = await rawHttpRequest(
    "GET http://[ HTTP/1.1\r\nHost: fixture\r\n\r\n",
  );
  assert.equal(malformedAbsoluteTarget.status, 404,
    "malformed absolute targets must receive a fail-closed HTTP response");
  assert.deepEqual(JSON.parse(malformedAbsoluteTarget.body), { error: "not_found" });
  const caddyDoubleProxyRequest = await rawHttpRequest(
    "GET /status/network HTTP/1.1\r\n"
      + "Host: 127.0.0.1:20463\r\n"
      + "User-Agent: curl/8.5.0\r\n"
      + "Accept: */*\r\n"
      + "Accept-Encoding: gzip\r\n"
      + "Via: 1.1 Caddy\r\n"
      + "Via: 1.1 Caddy\r\n"
      + "X-Forwarded-For: 172.27.0.3\r\n"
      + "X-Forwarded-Host: 127.0.0.1:20463\r\n"
      + "X-Forwarded-Proto: http\r\n\r\n",
  );
  assert.equal(caddyDoubleProxyRequest.status, 200,
    "the captured double-Caddy request with repeated Via headers must be accepted");
  assert.deepEqual(JSON.parse(caddyDoubleProxyRequest.body), defaultSnapshot);
  for (const duplicateHeaders of [
    "Host: fixture\r\nHost: fixture\r\n",
    "Origin: http://fixture\r\nOrigin: http://fixture\r\n",
  ]) {
    const duplicateSingleton = await rawHttpRequest(
      `GET /status/network/ws?chainId=fixture-chain HTTP/1.1\r\n${duplicateHeaders}`
        + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Key: Zml4dHVyZS1rZXktMTIzNA==\r\n"
        + "Sec-WebSocket-Version: 13\r\n\r\n",
    );
    assert.equal(duplicateSingleton.status, 400,
      "duplicate Host and Origin headers must remain rejected");
  }
  await assert.rejects(connectWebSocket("/status/network/ws?chainId=fixture-chain", "http://attacker"), /426 Upgrade Required/);
  const ws = await connectWebSocket("/status/network/ws?chainId=fixture-chain");
  assert.match(ws.headers, /Sec-WebSocket-Accept:/);
  const frame = await readServerFrame(ws.client, ws.remainder);
  assert.equal(frame.opcode, 1);
  assert.deepEqual(JSON.parse(frame.payload.toString()), { type: "network_snapshot", snapshot: selected });
  const doubleViaWs = await connectWebSocket(
    "/status/network/ws?chainId=fixture-chain",
    "http://fixture",
    "Via: 1.1 Caddy\r\nVia: 1.1 Caddy\r\n",
  );
  const doubleViaFrame = await readServerFrame(doubleViaWs.client, doubleViaWs.remainder);
  assert.equal(doubleViaFrame.opcode, 1);
  assert.deepEqual(JSON.parse(doubleViaFrame.payload.toString()), {
    type: "network_snapshot", snapshot: selected,
  });
  doubleViaWs.client.destroy();
  const changed = { ...selected, observed_at: "2026-10-13T00:00:05Z", nodes: [{ node_id: "peer" }, { node_id: "peer-2" }] };
  const changedFramePromise = readServerFrame(ws.client);
  // The production collector publishes by rename, so a concurrent WebSocket
  // reader must never observe the fixture's intermediate truncated file.
  const nextSnapshot = path.join(state, "networks/fixture-chain.next");
  await writeFile(nextSnapshot, JSON.stringify(changed));
  await rename(nextSnapshot, path.join(state, "networks/fixture-chain.json"));
  await new Promise((resolve) => setTimeout(resolve, 5300));
  const changedFrame = await changedFramePromise;
  assert.deepEqual(JSON.parse(changedFrame.payload.toString()), { type: "network_snapshot", snapshot: changed });
  ws.client.destroy();
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(JSON.parse(await readFile(path.join(state, "networks/fixture-chain.json"), "utf8")).observed_at,
    changed.observed_at, "WebSocket must reflect a later cache snapshot through the real collector");
  const malformed = await connectWebSocket("/status/network/ws?chainId=fixture-chain");
  await readServerFrame(malformed.client, malformed.remainder);
  const closed = once(malformed.client, "close");
  malformed.client.write(Buffer.from([0x81]));
  let closeTimer;
  await Promise.race([
    closed,
    new Promise((_, reject) => { closeTimer = setTimeout(() => reject(new Error("partial WebSocket frame was not bounded")), 6500); }),
  ]);
  clearTimeout(closeTimer);
  const caddy = await readFile(path.join(root, "04-ops/Caddyfile"), "utf8");
  assert.match(caddy, /handle \/status\/network\/ws \{\s+reverse_proxy 127\.0\.0\.1:18094\s+\}/);
  const renderer = await readFile(path.join(root, "04-ops/render-ops.sh"), "utf8");
  assert.match(renderer, /handle \/status\/network\/ws \{\s+reverse_proxy 127\.0\.0\.1:18094\s+\}/);
  const unit = await readFile(path.join(root, "04-ops/gdc-network-observer@.service"), "utf8");
  assert.match(unit, /ExecStart=\/usr\/bin\/python3 \/usr\/local\/lib\/gonka-devnet\/network-observer-http\.py/);
  assert.match(unit, /RuntimeMaxSec=330/);
  const install = await readFile(path.join(root, "04-ops/install-ops.sh"), "utf8");
  assert.match(install, /network-observer-http\.py.*\/usr\/local\/lib\/gonka-devnet\/network-observer-http\.py/);
  console.log("PASS socket-activated cached HTTP/WebSocket observer transport and routing contract");
} finally {
  for (const connection of liveSockets) connection.destroy();
  await new Promise((resolve) => server.close(resolve));
  await rm(temporary, { recursive: true, force: true });
}
