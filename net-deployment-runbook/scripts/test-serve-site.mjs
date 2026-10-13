#!/usr/bin/env node
import assert from "node:assert/strict";
import { chmod, mkdtemp, writeFile } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import { randomBytes } from "node:crypto";
import os from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";

function listen(handler) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(handler);
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

function port(server) {
  const address = server.address();
  assert.equal(typeof address, "object");
  return address.port;
}

function rawRequest(localPort, path, options = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request({ hostname: "127.0.0.1", port: localPort, path, ...options }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString() }));
      response.once("error", reject);
    });
    request.once("error", reject);
    request.end();
  });
}

function websocketSnapshot(localPort) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: "127.0.0.1", port: localPort });
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("timed out waiting for network websocket snapshot"));
    }, 2_000);
    let data = Buffer.alloc(0);
    socket.on("connect", () => socket.write(
      "GET /status/network/ws?chainId=fixture-chain HTTP/1.1\r\n" +
      "Host: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      `Sec-WebSocket-Key: ${randomBytes(16).toString("base64")}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
    ));
    socket.on("data", (chunk) => {
      data = Buffer.concat([data, chunk]);
      const headerEnd = data.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      assert.match(data.subarray(0, headerEnd).toString(), /^HTTP\/1\.1 101 Switching Protocols/m);
      const frame = data.subarray(headerEnd + 4);
      if (frame.length < 2) return;
      let size = frame[1] & 0x7f;
      let offset = 2;
      if (size === 126) {
        if (frame.length < 4) return;
        size = frame.readUInt16BE(2);
        offset = 4;
      }
      if (frame.length < offset + size) return;
      clearTimeout(timeout);
      socket.end();
      resolve(JSON.parse(frame.subarray(offset, offset + size).toString()));
    });
    socket.once("error", reject);
  });
}

async function startServer(site, origin, env = {}) {
  const child = spawn(process.execPath, ["scripts/serve-site.mjs", site, "127.0.0.1", "0", origin], {
    cwd: new URL("..", import.meta.url),
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const output = [];
  child.stdout.on("data", (chunk) => output.push(String(chunk)));
  child.stderr.on("data", (chunk) => output.push(String(chunk)));
  const localPort = await new Promise((resolve, reject) => {
    const deadline = setTimeout(() => reject(new Error(output.join(""))), 5000);
    child.stdout.on("data", (chunk) => {
      const match = String(chunk).match(/Local site: http:\/\/127\.0\.0\.1:(\d+)\//);
      if (match) {
        clearTimeout(deadline);
        resolve(Number(match[1]));
      }
    });
    child.once("exit", (code) => reject(new Error(`server exited ${code}: ${output.join("")}`)));
  });
  return { child, port: localPort };
}

const directory = await mkdtemp(join(os.tmpdir(), "gdc-site-serve-"));
await writeFile(join(directory, "index.html"), "<main>local site</main>");
const observer = join(directory, "observer.sh");
await writeFile(observer, `#!/usr/bin/env bash
set -Eeuo pipefail
[[ "\${GDC_NETWORK_CHAIN_ID:-}" == fixture-chain ]]
printf '%s\\n' '{"schema_version":1,"chain_id":"fixture-chain","nodes":[]}'
`);
await chmod(observer, 0o755);
const unexpectedRequests = [];
const untrusted = await listen((request, response) => {
  unexpectedRequests.push(request.url);
  response.end("unexpected destination");
});
const untrustedOrigin = `http://127.0.0.1:${port(untrusted)}`;
const upstreamRequests = [];
const upstream = await listen((request, response) => {
  upstreamRequests.push({ path: request.url, host: request.headers.host, method: request.method });
  if (request.url === "/preview/215/status/redirect") {
    response.writeHead(302, { Location: `${untrustedOrigin}/private` });
    response.end();
    return;
  }
  if (request.url === "/preview/215/config.js") {
    response.writeHead(200, { "Content-Type": "text/javascript" });
    response.end("window.GDC_CONFIG = {chainId: 'fixture', statusBase: '/preview/215/status', chainRpcOrigin: '/preview/215/status/node0'};\n");
    return;
  }
  if (request.url === "/preview/215/status/participants?fresh=1") {
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end('{"participant":[]}\n');
    return;
  }
  response.writeHead(404);
  response.end();
});

const local = await startServer(
  directory,
  `http://127.0.0.1:${port(upstream)}/preview/215`,
  { GDC_SITE_OBSERVER_BIN: observer, GDC_SITE_DEFAULT_CHAIN_ID: "fixture-chain" },
);
try {
  assert.match(await (await fetch(`http://127.0.0.1:${local.port}/`)).text(), /local site/);
  assert.equal(
    await (await fetch(`http://127.0.0.1:${local.port}/config.js`)).text(),
    "window.GDC_CONFIG = {\"publicBootstrap\":true,chainId: 'fixture', statusBase: '/status', chainRpcOrigin: '/status/node0'};\n",
  );
  assert.equal(
    await (await fetch(`http://127.0.0.1:${local.port}/status/participants?fresh=1`)).text(),
    '{"participant":[]}\n',
  );
  assert.equal(
    await (await fetch(`http://127.0.0.1:${local.port}/preview/215/status/participants?fresh=1`)).text(),
    '{"participant":[]}\n',
  );
  const pending = await fetch(`http://127.0.0.1:${local.port}/status/network?chainId=fixture-chain`);
  assert.equal(pending.status, 202);
  assert.deepEqual(await pending.json(), { state: "observation_pending", chain_id: "fixture-chain" });
  const deadline = Date.now() + 2_000;
  let snapshot = null;
  while (Date.now() < deadline) {
    const response = await fetch(`http://127.0.0.1:${local.port}/status/network?chainId=fixture-chain`);
    if (response.status === 200) { snapshot = await response.json(); break; }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.deepEqual(snapshot, { schema_version: 1, chain_id: "fixture-chain", nodes: [] });
  const defaultPending = await fetch(`http://127.0.0.1:${local.port}/status/network`);
  assert.equal(defaultPending.status, 200);
  assert.deepEqual(await defaultPending.json(), { schema_version: 1, chain_id: "fixture-chain", nodes: [] });
  assert.deepEqual(await websocketSnapshot(local.port), {
    type: "network_snapshot",
    snapshot: { schema_version: 1, chain_id: "fixture-chain", nodes: [] },
  });
  assert.equal((await fetch(`http://127.0.0.1:${local.port}/bootstrap/gonka-testnet-devshards/bootstrap.json`)).status, 404);
  assert.equal((await fetch(`http://127.0.0.1:${local.port}/%2e%2e/Makefile`)).status, 404);

  const beforeRejected = upstreamRequests.length;
  for (const path of [
    `${untrustedOrigin}/status/participants?fresh=1`,
    `//127.0.0.1:${port(untrusted)}/status/participants?fresh=1`,
    "/status\\..\\private",
    "http://[",
  ]) assert.equal((await rawRequest(local.port, path)).status, 400, path);
  for (const path of [
    "/status/../../private",
    "/status/%2e%2e/%2e%2e/private",
    "/status/%2f..%2fprivate",
    "/preview/215/status/%5c..%5cprivate",
  ]) assert.equal((await rawRequest(local.port, path)).status, 404, path);
  assert.equal((await rawRequest(local.port, "/status/participants", { method: "POST" })).status, 405);
  assert.equal(upstreamRequests.length, beforeRejected, "rejected paths must not reach the configured origin");
  assert.equal((await rawRequest(local.port, "/status/participants?fresh=1", {
    headers: { Host: `127.0.0.1:${port(untrusted)}` },
  })).status, 200);
  assert.equal(upstreamRequests.at(-1).host, `127.0.0.1:${port(upstream)}`);
  const queryPath = `/status/participants?target=${encodeURIComponent(untrustedOrigin)}`;
  assert.equal((await rawRequest(local.port, queryPath)).status, 404);
  assert.equal(upstreamRequests.at(-1).path, `/preview/215${queryPath}`);
  assert.equal(upstreamRequests.at(-1).host, `127.0.0.1:${port(upstream)}`);
  assert.deepEqual(await rawRequest(local.port, "/status/participants?fresh=1", { method: "HEAD" }), {
    status: 200, body: "",
  });
  assert.equal(upstreamRequests.at(-1).method, "HEAD");
  assert.equal((await rawRequest(local.port, "/status/redirect")).status, 502);
  assert.deepEqual(unexpectedRequests, [], "neither browser input nor upstream redirects may change the destination");
  console.log("PASS local site serves checkout files and read-only public data");
} finally {
  local.child.kill();
  await new Promise((resolve) => local.child.once("exit", resolve));
  await new Promise((resolve) => upstream.close(resolve));
  await new Promise((resolve) => untrusted.close(resolve));
}
