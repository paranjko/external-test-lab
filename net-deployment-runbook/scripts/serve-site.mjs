#!/usr/bin/env node
import http from "node:http";
import https from "node:https";
import { createHash } from "node:crypto";
import { createReadStream, statSync } from "node:fs";
import { basename, normalize, resolve, sep } from "node:path";
import { spawn } from "node:child_process";

const [siteDirectory, host, portInput, originInput = ""] = process.argv.slice(2);
const port = Number(portInput);

if (!siteDirectory || !host || !Number.isInteger(port) || port < 0 || port > 65535) {
  console.error("usage: serve-site.mjs SITE_DIRECTORY HOST PORT [STATUS_ORIGIN]");
  process.exit(2);
}

let origin = null;
if (originInput) {
  try {
    origin = new URL(originInput.endsWith("/") ? originInput : `${originInput}/`);
  } catch {
    console.error(`invalid status origin: ${originInput}`);
    process.exit(2);
  }
  if (!["http:", "https:"].includes(origin.protocol) || origin.username || origin.password) {
    console.error(`status origin must be an unauthenticated HTTP(S) URL: ${originInput}`);
    process.exit(2);
  }
}

const root = resolve(siteDirectory);
const observerScript = process.env.GDC_SITE_OBSERVER_BIN || new URL("../04-ops/network-observer.sh", import.meta.url).pathname;
const observedNetworks = new Map();
const observationJobs = new Map();
const observationSockets = new Map();
const maxObservedNetworks = 8;
const observationRefreshMilliseconds = 45_000;
const defaultChainId = process.env.GDC_SITE_DEFAULT_CHAIN_ID || "gonka-devnet-community";
const contentTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "application/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".woff2", "font/woff2"],
]);

function fileForRequest(url) {
  const pathname = decodeURIComponent(new URL(url, "http://localhost").pathname);
  const requested = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
  const file = resolve(root, normalize(requested));
  if (file !== root && !file.startsWith(`${root}${sep}`)) return null;
  return file;
}

function upstreamPath(requestUrl) {
  if (!origin) return null;
  const parsed = new URL(requestUrl, "http://localhost");
  const originPrefix = origin.pathname.replace(/\/+$/, "");
  const prefixedStatus = originPrefix && parsed.pathname.startsWith(`${originPrefix}/status/`);
  if (parsed.pathname !== "/config.js" && !parsed.pathname.startsWith("/status/") && !prefixedStatus)
    return null;
  const pathname = prefixedStatus
    ? parsed.pathname.slice(originPrefix.length)
    : parsed.pathname;
  // Status routes have plain path segments. Reject encoded separators and
  // traversal instead of relying on each upstream proxy to normalize them.
  if (!/^\/(?:config\.js|status\/[A-Za-z0-9._~/-]*)$/.test(pathname)) return null;
  return `${originPrefix}${pathname}${parsed.search}`;
}

function selectedChainId(requestUrl) {
  const parsed = new URL(requestUrl, "http://localhost");
  if (parsed.pathname !== "/status/network") return null;
  const entries = [...parsed.searchParams.entries()];
  if (entries.length !== 1 || entries[0][0] !== "chainId") return null;
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(entries[0][1]) ? entries[0][1] : null;
}

function networkRequest(requestUrl) {
  const parsed = new URL(requestUrl, "http://localhost");
  return parsed.pathname === "/status/network" && [...parsed.searchParams.keys()].length === 0;
}

function queueObservation(chainId) {
  if (observationJobs.has(chainId)) return true;
  const replacingCachedSnapshot = observedNetworks.has(chainId) ? 1 : 0;
  if (
    observedNetworks.size + observationJobs.size - replacingCachedSnapshot >=
    maxObservedNetworks
  )
    return false;
  const child = spawn("/usr/bin/bash", [observerScript, "--collect"], {
    env: {
      ...process.env,
      GDC_NETWORK_CHAIN_ID: chainId,
      GDC_NETWORK_BOOTSTRAP_URL: `https://gonka-dev.net/${chainId}/bootstrap.json`,
    },
    stdio: ["ignore", "pipe", "ignore"],
  });
  observationJobs.set(chainId, child);
  let output = "";
  const timeout = setTimeout(() => child.kill("SIGTERM"), 60_000);
  child.stdout.on("data", (chunk) => {
    output += String(chunk);
    if (output.length > 16 * 1024 * 1024) child.kill("SIGTERM");
  });
  child.once("exit", (code) => {
    clearTimeout(timeout);
    observationJobs.delete(chainId);
    if (code !== 0 || output.length > 16 * 1024 * 1024) return;
    try {
      const snapshot = JSON.parse(output);
      if (snapshot?.schema_version !== 1 || snapshot?.chain_id !== chainId || !Array.isArray(snapshot?.nodes)) return;
      observedNetworks.set(chainId, { body: output, collectedAt: Date.now() });
      publishObservation(chainId, snapshot);
    } catch {}
  });
  child.once("error", () => {
    clearTimeout(timeout);
    observationJobs.delete(chainId);
  });
  return true;
}

function socketFrame(value) {
  const body = Buffer.from(JSON.stringify(value));
  if (body.length > 16 * 1024 * 1024) return null;
  if (body.length < 126) return Buffer.concat([Buffer.from([0x81, body.length]), body]);
  if (body.length <= 0xffff) {
    const header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
    return Buffer.concat([header, body]);
  }
  const header = Buffer.alloc(10);
  header[0] = 0x81;
  header[1] = 127;
  header.writeBigUInt64BE(BigInt(body.length), 2);
  return Buffer.concat([header, body]);
}

function sendObservation(socket, snapshot) {
  const frame = socketFrame({ type: "network_snapshot", snapshot });
  if (frame && !socket.destroyed) socket.write(frame);
}

function publishObservation(chainId, snapshot) {
  for (const socket of observationSockets.get(chainId) || [])
    sendObservation(socket, snapshot);
}

function websocketChainId(requestUrl) {
  const parsed = new URL(requestUrl, "http://localhost");
  if (parsed.pathname !== "/status/network/ws") return null;
  const entries = [...parsed.searchParams.entries()];
  if (entries.length > 1 || (entries.length === 1 && entries[0][0] !== "chainId")) return null;
  const chainId = entries.length ? entries[0][1] : defaultChainId;
  return /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(chainId) ? chainId : null;
}

function requestUpstream(request, path) {
  return new Promise((resolve, reject) => {
    const client = origin.protocol === "https:" ? https : http;
    // The operator-selected origin owns the entire connection authority.
    // Browser input is only an origin-form path, never a URL or Host header.
    const outgoing = client.request({
      protocol: origin.protocol,
      hostname: origin.hostname.replace(/^\[|\]$/g, ""),
      port: origin.port,
      method: request.method,
      path,
      headers: { Accept: request.headers.accept || "*/*" },
      timeout: 15_000,
    }, resolve);
    outgoing.once("timeout", () => outgoing.destroy(new Error("status origin timed out")));
    outgoing.once("error", reject);
    outgoing.end();
  });
}

async function proxy(request, response, path) {
  try {
    const upstream = await requestUpstream(request, path);
    const status = upstream.statusCode || 502;
    if (status >= 300 && status < 400) {
      upstream.resume();
      throw new Error("status origin redirects are not allowed");
    }
    const contentType = upstream.headers["content-type"] || "application/octet-stream";
    response.writeHead(status, {
      "Content-Type": contentType,
      "Cache-Control": "no-store",
    });
    if (request.method === "HEAD") {
      upstream.resume();
      response.end();
      return;
    }
    // Local development has no preview number in its URL. Keep the public
    // configuration's remote preview path private to this proxy, so the
    // browser itself always requests local /status routes.
    if (new URL(request.url || "/", "http://localhost").pathname === "/config.js" &&
        contentType.includes("javascript")) {
      const remotePrefix = origin?.pathname.replace(/\/+$/, "") || "";
      const chunks = [];
      for await (const chunk of upstream) chunks.push(chunk);
      const source = Buffer.concat(chunks).toString("utf8");
      let localConfig = remotePrefix
        ? source.replaceAll(`${remotePrefix}/status`, "/status")
        : source;
      // The local observer supplies the complete, same-chain snapshot. Mark
      // this config as bootstrap-driven so the renderer does not overwrite it
      // with individual preview proxy requests.
      if (/"publicBootstrap"\s*:/.test(localConfig))
        localConfig = localConfig.replace(/"publicBootstrap"\s*:\s*false/g, "\"publicBootstrap\":true");
      else
        localConfig = localConfig.replace(
          /(window\.GDC_CONFIG\s*=\s*\{)/,
          "$1\"publicBootstrap\":true,",
        );
      response.end(localConfig);
      return;
    }
    for await (const chunk of upstream) response.write(chunk);
    response.end();
  } catch {
    if (response.headersSent) {
      response.destroy();
      return;
    }
    response.writeHead(502, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    });
    response.end("Public status data is unavailable\n");
  }
}

const server = http.createServer(async (request, response) => {
  if (request.method !== "GET" && request.method !== "HEAD") {
    response.writeHead(405, { Allow: "GET, HEAD" });
    response.end();
    return;
  }

  // This is a local site server, not a forward proxy. Reject absolute-form
  // targets, network-path references and backslashes before URL parsing.
  const requestUrl = request.url || "/";
  if (!requestUrl.startsWith("/") || requestUrl.startsWith("//") || requestUrl.includes("\\")) {
    response.writeHead(400);
    response.end();
    return;
  }

  const selectedChain = selectedChainId(request.url || "/");
  const chainId = selectedChain || (networkRequest(request.url || "/") ? defaultChainId : null);
  if (chainId) {
    const snapshot = observedNetworks.get(chainId);
    if (
      !snapshot ||
      Date.now() - snapshot.collectedAt >= observationRefreshMilliseconds
    )
      queueObservation(chainId);
    if (snapshot) {
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(request.method === "HEAD" ? "" : snapshot.body);
    } else if (observationJobs.has(chainId)) {
      response.writeHead(202, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(request.method === "HEAD" ? "" : JSON.stringify({ state: "observation_pending", chain_id: chainId }));
    } else {
      response.writeHead(429, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      response.end(request.method === "HEAD" ? "" : '{"error":"network_observation_capacity_reached"}');
    }
    return;
  }

  const path = upstreamPath(requestUrl);
  if (path) {
    await proxy(request, response, path);
    return;
  }

  let file;
  try {
    file = fileForRequest(request.url || "/");
  } catch {
    response.writeHead(400);
    response.end();
    return;
  }
  if (!file) {
    response.writeHead(404);
    response.end();
    return;
  }

  let metadata;
  try {
    metadata = statSync(file);
  } catch {
    response.writeHead(404);
    response.end();
    return;
  }
  if (!metadata.isFile()) {
    response.writeHead(404);
    response.end();
    return;
  }

  const extension = basename(file).match(/\.[^.]+$/)?.[0] || "";
  response.writeHead(200, {
    "Content-Length": metadata.size,
    "Content-Type": contentTypes.get(extension) || "application/octet-stream",
    "Cache-Control": "no-store",
  });
  if (request.method === "HEAD") {
    response.end();
    return;
  }
  createReadStream(file).pipe(response);
});

server.on("upgrade", (request, socket) => {
  const chainId = websocketChainId(request.url || "");
  const key = request.headers["sec-websocket-key"];
  if (!chainId || typeof key !== "string" || request.headers.upgrade?.toLowerCase() !== "websocket") {
    socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    return;
  }
  const accept = createHash("sha1")
    .update(`${key.trim()}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  const sockets = observationSockets.get(chainId) || new Set();
  sockets.add(socket);
  observationSockets.set(chainId, sockets);
  socket.on("error", () => {});
  socket.on("close", () => {
    sockets.delete(socket);
    if (!sockets.size) observationSockets.delete(chainId);
  });
  const cached = observedNetworks.get(chainId);
  if (cached) {
    try { sendObservation(socket, JSON.parse(cached.body)); } catch {}
  }
  queueObservation(chainId);
});

const observationTimer = setInterval(() => {
  for (const chainId of observationSockets.keys()) {
    const snapshot = observedNetworks.get(chainId);
    if (!snapshot || Date.now() - snapshot.collectedAt >= observationRefreshMilliseconds)
      queueObservation(chainId);
  }
}, 1000);
observationTimer.unref();

server.once("error", (error) => {
  console.error(`cannot serve local site on ${host}:${port}: ${error.message}`);
  process.exit(1);
});

server.listen(port, host, () => {
  const address = server.address();
  const boundPort = typeof address === "object" && address ? address.port : port;
  console.log(`Local site: http://${host}:${boundPort}/`);
  if (origin) console.log(`Public data: ${origin}`);
});
