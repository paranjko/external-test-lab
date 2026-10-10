#!/usr/bin/env node
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname, resolve } from "node:path";
import { startChromeDevTools, stopChromeDevTools } from "./chrome-devtools.mjs";

const generatedSite = resolve(process.argv[2] || "");
if (!generatedSite) throw new Error("generated site directory is required");
const sourceSite = resolve(new URL("../04-ops/site", import.meta.url).pathname);
const profile = await mkdtemp(join(tmpdir(), "gdc-current-vp-browser-"));
const NODE0 = "071be53dde41cd019182ba23636b9033b2402bcc";
const NODE1 = "1e26515bd34f01c6d11a1dfE649a640bb3da2c41".toLowerCase();
const NODE4 = "4e26515bd34f01c6d11a1dfE649a640bb3da2c44".toLowerCase();
const ACCOUNT0 = "gonka1aaaaaaaaaaaaaaaaaaaaaaaaaa";
const ACCOUNT1 = "gonka1bbbbbbbbbbbbbbbbbbbbbbbbbb";
const ACCOUNT4 = "gonka1dddddddddddddddddddddddddd";
const validatorSets = [];
const heights = new Map([
  ["node0", 1000],
  ["node1", 900],
  ["node4", 950],
]);
const statusCounts = new Map([
  ["node0", 0],
  ["node1", 0],
  ["node4", 0],
]);
const requests = [];
const fixtureEvents = [];
const previewCanonicalChainApiRequests = [];
let holdValidatorSets = false;
let versionScenario = "fresh";
let participantScenario = "complete";
let hardwareScenario = "matching";
let approvalScenario = "empty";
let holdDetails = true;
const heldDetails = [];
const activityFixture = (pathname) => {
  if (pathname.endsWith('/epoch_info')) return {latest_epoch: {index: '7', poc_start_block_height: '100'}, is_confirmation_poc_active: false};
  if (pathname.endsWith('/all_poc_v2_store_commits/100')) return {commits: [{participant_address: ACCOUNT1, count: '32', model_id: 'qwen'}]};
  if (pathname.endsWith('/poc_v2_validations_for_stage/100')) return {poc_validation: []};
  return null;
};
const softwareVersionTime = () => new Date(
  Date.now() - (versionScenario === "fresh" ? 1000 : 600_000),
).toISOString();
const softwareVersionsFixture = () => ({
  timestamp: softwareVersionTime(),
  node_version: { application_name: "inference-chain", commit: "4d687ed6782bcea3931d2d9135bf322f84e190ab", version: "v0.2.15" },
  api_version: { application_name: "decentralized-api", commit: "5dbb53ddf3ddc42655fc04dc39d96003169bdbb0", version: "v0.2.15-post3" },
});
const mimeTypes = {
  ".css": "text/css",
  ".js": "text/javascript",
  ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
};
const configObject = {
  chainId: "gonka-devnet-community",
  model: "Qwen/Qwen3-0.6B",
  apiBase: "/preview/215/status",
  contact: "",
  grafanaNetwork: "/",
  grafanaInference: "/",
  statusBase: "/preview/215/status",
  gatewayNode: "node4",
  chainRpcHost: "node0.gonka-dev.net",
  chainRpcOrigin: "/preview/215/status/node0",
  nodes: [],
  nodeCatalog: [
    {
      name: "node0",
      publicHost: "node0.gonka-dev.net",
      statusBase: "/preview/215/status/node0",
      ip: "192.0.2.10",
      geo: { latitude: 0, longitude: 0, city: "test", country: "test", source: "operator" },
    },
    {
      name: "node1",
      publicHost: "node1.gonka-dev.net",
      statusBase: "/preview/215/status/node1",
      ip: "192.0.2.11",
      geo: { latitude: 20, longitude: 20, city: "test", country: "test", source: "operator" },
    },
    {
      name: "node4",
      publicHost: "node4.gonka-dev.net",
      statusBase: "/preview/215/status/node4",
      ip: "192.0.2.14",
      geo: { latitude: 40, longitude: 40, city: "test", country: "test", source: "operator" },
    },
  ],
};
const makeConfig = (value) =>
  `window.GDC_CONFIG = ${JSON.stringify(value)}; window.setInterval = (callback) => { window.__refresh = async () => { await callback(); await detailsInFlight; await activityInFlight; }; return 1; };`;
const config = makeConfig(configObject);
const configForBase = (base, nodeCatalog = configObject.nodeCatalog) =>
  makeConfig({
    ...configObject,
    apiBase: base,
    statusBase: base,
    chainRpcOrigin: `${base}/node0`,
    nodeCatalog: nodeCatalog.map((node) => ({
      ...node,
      statusBase: `${base}/${node.name}`,
    })),
  });
const localConfig = configForBase("/local/status");
const ambiguousConfig = configForBase("/ambiguous/status", [
  ...configObject.nodeCatalog,
  { ...configObject.nodeCatalog[0] },
]);
const missingConfig = configForBase(
  "/missing/status",
  configObject.nodeCatalog.filter((node) => node.name !== "node0"),
);

const jsonResponse = (response, status, value) => {
  response.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  response.end(JSON.stringify(value));
};
const server = createServer(async (request, response) => {
  const url = new URL(request.url || "/", "http://127.0.0.1");
  requests.push(url.pathname + url.search);
  if (holdDetails && /\/(?:v1\/versions|chain-rpc\/net_info|devshard\/healthz)$/.test(url.pathname)) {
    heldDetails.push(() => server.emit('request', request, response));
    return;
  }
  const activity = activityFixture(url.pathname);
  if (activity) { jsonResponse(response, 200, activity); return; }
  if (
    url.pathname === "/preview/215/" ||
    url.pathname === "/preview/215/index.html" ||
    url.pathname === "/local/" ||
    url.pathname === "/local/index.html" ||
    url.pathname === "/ambiguous/" ||
    url.pathname === "/ambiguous/index.html" ||
    url.pathname === "/missing/" ||
    url.pathname === "/missing/index.html"
  ) {
    const html = await readFile(join(sourceSite, "index.html"), "utf8");
    response.writeHead(200, { "content-type": "text/html" }).end(html);
    return;
  }
  if (url.pathname === "/preview/215/config.js") {
    response.writeHead(200, { "content-type": "text/javascript" }).end(config);
    return;
  }
  if (url.pathname === "/local/config.js") {
    response.writeHead(200, { "content-type": "text/javascript" }).end(localConfig);
    return;
  }
  if (url.pathname === "/ambiguous/config.js") {
    response.writeHead(200, { "content-type": "text/javascript" }).end(ambiguousConfig);
    return;
  }
  if (url.pathname === "/missing/config.js") {
    response.writeHead(200, { "content-type": "text/javascript" }).end(missingConfig);
    return;
  }
  if (/^\/(?:preview\/215|local|ambiguous|missing)\/status\/network$/.test(url.pathname)) {
    const observedAt = new Date(
      Date.now() - (versionScenario === "stale" ? 600_000 : 1000),
    ).toISOString();
    jsonResponse(response, 200, {
      nodes: [
        ...[["node0", NODE0], ["node1", NODE1], ["node4", NODE4]].map(([name, id]) => ({
          node_id: id,
          node_name: name,
          dapi_url: `https://${name}.gonka-dev.net`,
          active: true,
          components: {
            chain_rpc: {
              state: "observed",
              p2p_node_id: versionScenario === "mismatch" && name === "node0" ? NODE1 : id,
              chain_id: "gonka-devnet-community",
              observed_at: new Date().toISOString(),
              latest_block_height: heights.get(name),
              catching_up: false,
            },
            versions: {
              state: "observed",
              source_timestamp: softwareVersionTime(),
              observed_at: new Date().toISOString(),
              ...softwareVersionsFixture(),
            },
            inferenced: {
              state: "observed",
              source_endpoint: `https://${name}.gonka-dev.net/chain-api/cosmos/base/tendermint/v1beta1/node_info`,
              observed_at: observedAt,
              application_name: "inference-chain",
              version: "v0.2.16-post1",
              commit: "136041c81ea8ff38e7620d76af66a7c7fe7eec50",
            },
          },
        })),
      ],
    });
    return;
  }
  if (["/preview/215/status/software", "/local/status/software", "/ambiguous/status/software", "/missing/status/software"].includes(url.pathname)) {
    const observedSeconds = Math.floor(Date.now() / 1000);
    jsonResponse(response, 200, {
      data: { result: [
        { metric: { host: "node0", component: "chain", version: "v0.2.15" }, value: [observedSeconds, String(observedSeconds)] },
        { metric: { host: "node0", component: "api", version: "v0.2.15-post3" }, value: [observedSeconds, String(observedSeconds)] },
        { metric: { host: "node1", component: "chain", version: "v0.2.15" }, value: [observedSeconds, String(observedSeconds)] },
        { metric: { host: "node1", component: "api", version: "v0.2.15-post3" }, value: [observedSeconds, String(observedSeconds)] },
      ] },
    });
    return;
  }
  if (/^\/(?:preview\/215|local|ambiguous|missing)\/status\/node[014](?:\.gonka-dev\.net)?\/v1\/versions$/.test(url.pathname)) {
    jsonResponse(response, 200, softwareVersionsFixture());
    return;
  }
  if (/^\/(?:local|ambiguous|missing)\/status\/node[014](?:\.gonka-dev\.net)?\/devshard\/healthz$/.test(url.pathname)) {
    jsonResponse(response, 200, []);
    return;
  }
  const statusMatch = url.pathname.match(
    /\/status\/(node0|node1|node4)(?:\.gonka-dev\.net)?\/chain-rpc\/status$/,
  );
  if (statusMatch) {
    const name = statusMatch[1];
    statusCounts.set(name, statusCounts.get(name) + 1);
    const height = Math.max(
      heights.get(name) + 1,
      Number(validatorSets.at(-1)?.height || 0),
    );
    heights.set(name, height);
    const nodeId = name === "node0" ? NODE0 : name === "node1" ? NODE1 : NODE4;
    jsonResponse(response, 200, {
      result: {
        node_info: { id: nodeId, network: "gonka-devnet-community" },
        sync_info: {
          latest_block_height: String(height),
          latest_block_time: new Date().toISOString(),
          catching_up: false,
        },
        validator_info: {
          address: nodeId.toUpperCase(),
          voting_power: name === "node1" ? "32" : "63",
        },
      },
    });
    return;
  }
  if (/\/chain-rpc\/net_info$/.test(url.pathname)) {
    jsonResponse(response, 200, { result: { n_peers: "2" } });
    return;
  }
  if (/^\/(?:preview\/215|local|ambiguous|missing)\/status\/gpus$/.test(url.pathname)) {
    jsonResponse(response, 200, { data: { result: [] } });
    return;
  }
  if (url.pathname.endsWith("/chain-rpc/validators")) {
    const height = new URL(request.url || "/", "http://127.0.0.1").searchParams.get("height") || "1000";
    const result = {
      result: {
        block_height: height,
        count: "1",
        total: "1",
        validators: [{ address: NODE0.toUpperCase(), voting_power: "63" }],
      },
    };
    if (!holdValidatorSets) {
      jsonResponse(response, 200, result);
      return;
    }
    const fulfill = (value, { status = 200 } = {}) => jsonResponse(response, status, value);
    validatorSets.push({
      url: url.pathname + url.search,
      height: Number(height),
      fulfill,
    });
    fixtureEvents.push(`status validators request ${url.pathname}${url.search}`);
    return;
  }
  if (url.pathname.endsWith("/chain-api/productscience/inference/inference/participant")) {
    jsonResponse(response, 200, {
      block_height: "1000",
      participant: [
        { address: ACCOUNT0, index: ACCOUNT0, inference_url: "https://node0.gonka-dev.net" },
        { address: ACCOUNT1, index: ACCOUNT1, inference_url: "https://node1.gonka-dev.net" },
        { address: ACCOUNT4, index: ACCOUNT4, inference_url: "https://node4.gonka-dev.net" },
      ],
      pagination: { next_key: null },
    });
    fixtureEvents.push(`local participant page ${url.pathname}`);
    return;
  }
  const localHardwareMatch = url.pathname.match(/\/chain-api\/productscience\/inference\/inference\/hardware_nodes\/([^/]+)$/);
  if (localHardwareMatch) {
    const account = decodeURIComponent(localHardwareMatch[1]);
    fixtureEvents.push(`local hardware query ${account}`);
    jsonResponse(response, 200, { nodes: { participant: account, hardware_nodes: [] } });
    return;
  }
  if (url.pathname.endsWith("/chain-api/productscience/inference/inference/devshard_approved_versions")) {
    fixtureEvents.push(`local approved versions query ${url.pathname}`);
    jsonResponse(response, 200, { versions: [] });
    return;
  }
  if (url.pathname.endsWith("/chain-api/productscience/inference/inference/params")) {
    fixtureEvents.push(`local deprecated params query ${url.pathname}`);
    jsonResponse(response, 200, { params: { devshard_escrow_params: { approved_versions: [
      { name: "v3", binary: "https://example.test/deprecated-v3.zip", sha256: "c".repeat(64) },
    ] } } });
    return;
  }
  const relative = url.pathname
    .replace(/^\/preview\/215\//, "")
    .replace(/^\/(?:local|ambiguous|missing)\//, "");
  const generated = [
    "app.js",
    "gateway-state.js",
    "host-state.js",
    "network-observation-state.js",
    "software-versions.js",
    "site-build.js",
  ];
  const file = generated.includes(relative)
    ? join(generatedSite, relative)
    : join(sourceSite, relative);
  if (
    !file.startsWith(`${sourceSite}/`) &&
    !file.startsWith(`${generatedSite}/`)
  ) {
    response.writeHead(404).end();
    return;
  }
  try {
    const bytes = await readFile(file);
    response
      .writeHead(200, {
        "content-type": mimeTypes[extname(file)] || "application/octet-stream",
      })
      .end(bytes);
  } catch {
    response.writeHead(404).end();
  }
});

let browser;
let socket;
let sequence = 0;
let sessionId = "";
const pending = new Map();
try {
  await new Promise((resolvePromise, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolvePromise);
  });
  const port = server.address().port;
  const chromeSession = await startChromeDevTools({
    chrome: process.env.CHROME_BIN || "google-chrome",
    profile,
    context: "current validator voting power refresh behavior",
    readyTimeoutMilliseconds: 60_000,
  });
  browser = chromeSession.browser;
  const version = await chromeSession.waitForEndpoint();
  socket = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolvePromise, reject) => {
    socket.addEventListener("open", resolvePromise, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.sessionId && message.sessionId !== sessionId) return;
    if (message.method === "Runtime.exceptionThrown") {
      fixtureEvents.push(JSON.stringify(message.params.exceptionDetails));
    }
    if (message.method === "Fetch.requestPaused") {
      const request = message.params;
      const requestUrl = new URL(request.request.url);
      if (requestUrl.hostname === "cloudflare-dns.com") {
        // Location discovery is not under test. Keep this fixture offline,
        // including the missing-catalog scenario, and use operator locations.
        const release = () => call("Fetch.fulfillRequest", {
          requestId: request.requestId,
          responseCode: 200,
          responseHeaders: [{name:"Content-Type",value:"application/json"}, {name:"Access-Control-Allow-Origin",value:"*"}],
          body: Buffer.from(JSON.stringify({Status:0, Answer:[]})).toString("base64"),
        });
        if (holdDetails) heldDetails.push(release);
        else void release();
        return;
      }
      if (requestUrl.hostname === "preview.gonka-dev.net") {
        const hostPreviewPath = requestUrl.pathname.replace(
          /^\/([1-9][0-9]*)(?=\/|$)/,
          "/preview/$1",
        );
        void fetch(`http://127.0.0.1:${port}${hostPreviewPath}${requestUrl.search}`)
          .then(async (proxied) => {
            const contentType = proxied.headers.get("content-type") || "application/octet-stream";
            const body = Buffer.from(await proxied.arrayBuffer()).toString("base64");
            return call("Fetch.fulfillRequest", {
              requestId: request.requestId,
              responseCode: proxied.status,
              responseHeaders: [
                { name: "Content-Type", value: contentType },
                { name: "Access-Control-Allow-Origin", value: "*" },
              ],
              body,
            });
          })
          .catch(() => call("Fetch.failRequest", {
            requestId: request.requestId,
            errorReason: "Failed",
          }));
        return;
      }
      const match = requestUrl.hostname.match(/^(node[0-8])\.gonka-dev\.net$/);
      if (!match) return;
      const name = match[1];
      const fulfill = async (value, { status = 200 } = {}) => {
        const responseHeaders = [
          { name: "Content-Type", value: "application/json" },
          { name: "Access-Control-Allow-Origin", value: "*" },
        ];
        await call("Fetch.fulfillRequest", {
          requestId: request.requestId,
          responseCode: status,
          responseHeaders,
          body: Buffer.from(JSON.stringify(value)).toString("base64"),
        });
      };
      const activity = activityFixture(requestUrl.pathname);
      if (activity) { void fulfill(activity); return; }
      if (requestUrl.pathname.endsWith("/chain-api/productscience/inference/inference/participant")) {
        if (name === "node0") previewCanonicalChainApiRequests.push(request.request.url);
        fixtureEvents.push(`participant page ${request.request.url}`);
        const participants = [
          { address: ACCOUNT0, index: ACCOUNT0, inference_url: "https://node0.gonka-dev.net" },
          { address: ACCOUNT1, index: ACCOUNT1, inference_url: participantScenario === "duplicate" ? "https://node0.gonka-dev.net" : "https://node1.gonka-dev.net" },
          { address: ACCOUNT4, index: ACCOUNT4, inference_url: "https://node4.gonka-dev.net" },
        ];
        void fulfill(participantScenario === "malformed"
          ? { block_height: "1000", participants, pagination: { next_key: null } }
          : { block_height: "1000", participant: participants, pagination: { next_key: null } });
        return;
      }
      const hardwareMatch = requestUrl.pathname.match(/\/chain-api\/productscience\/inference\/inference\/hardware_nodes\/([^/]+)$/);
      if (hardwareMatch) {
        if (name === "node0") previewCanonicalChainApiRequests.push(request.request.url);
        const account = decodeURIComponent(hardwareMatch[1]);
        fixtureEvents.push(`hardware query ${account}`);
        const participant = hardwareScenario === "mismatch" && account === ACCOUNT1 ? ACCOUNT0 : account;
        void fulfill({ nodes: { participant, hardware_nodes: [] } });
        return;
      }
      if (requestUrl.pathname.endsWith("/chain-api/productscience/inference/inference/params")) {
        if (name === "node0") previewCanonicalChainApiRequests.push(request.request.url);
        fixtureEvents.push("deprecated params query");
        void fulfill({ params: { devshard_escrow_params: { approved_versions: [
          { name: "v3", binary: "https://example.test/deprecated-v3.zip", sha256: "c".repeat(64) },
        ] } } });
        return;
      }
      if (requestUrl.pathname.endsWith("/chain-api/productscience/inference/inference/devshard_approved_versions")) {
        if (name === "node0") previewCanonicalChainApiRequests.push(request.request.url);
        fixtureEvents.push("approved versions query");
        if (approvalScenario === "error") {
          void fulfill({ error: "temporarily unavailable" }, { status: 503 });
        } else if (approvalScenario === "malformed") {
          void fulfill({ versions: "none" });
        } else if (approvalScenario === "malformed-entry") {
          void fulfill({ versions: [{ name: "v4.1", sha256: "a".repeat(64) }] });
        } else if (approvalScenario === "nonempty") {
          void fulfill({ versions: [
            { name: "v4.1", binary: "https://example.test/v4.1.zip", sha256: "a".repeat(64) },
            { name: "v5", binary: "https://example.test/v5.zip", sha256: "b".repeat(64) },
          ] });
        } else {
          void fulfill({ versions: [] });
        }
        return;
      }
      if (requestUrl.pathname.endsWith("/chain-rpc/status")) {
        const nodeId = name === "node0" ? NODE0 : name === "node1" ? NODE1 : NODE4;
        void fulfill({
          result: {
            node_info: { id: nodeId, network: "gonka-devnet-community" },
            sync_info: {
              latest_block_height: String(heights.get(name)),
              latest_block_time: new Date().toISOString(),
              catching_up: false,
            },
          },
        });
        return;
      }
      // Every external route is synthetic; new optional probes must never
      // escape this browser fixture to the live network.
      void fulfill({error: "fixture route unavailable"}, {status: 404});
      return;
    }
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    message.error
      ? waiter.reject(new Error(message.error.message))
      : waiter.resolve(message.result);
  });
  const call = (method, params = {}) =>
    new Promise((resolvePromise, reject) => {
      const id = ++sequence;
      pending.set(id, { resolve: resolvePromise, reject });
      socket.send(
        JSON.stringify({
          id,
          method,
          params,
          ...(sessionId ? { sessionId } : {}),
        }),
      );
    });
  const { targetId } = await call("Target.createTarget", {
    url: "about:blank",
  });
  ({ sessionId } = await call("Target.attachToTarget", {
    targetId,
    flatten: true,
  }));
  await call("Page.enable");
  await call("Runtime.enable");
  await call("Fetch.enable", {
    patterns: [
      { urlPattern: "https://cloudflare-dns.com/*", requestStage: "Request" },
      {
        urlPattern: "https://preview.gonka-dev.net/*",
        requestStage: "Request",
      },
      {
        urlPattern: "https://node*.gonka-dev.net/*",
        requestStage: "Request",
      },
    ],
  });
  await call("Page.navigate", { url: `http://127.0.0.1:${port}/preview/215/` });
  const evaluate = async (expression) => {
    const result = await call("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  };
  const waitFor = async (expression, label) => {
    const deadline = Date.now() + 20_000;
    let lastValue;
    while (Date.now() < deadline) {
      lastValue = await evaluate(expression);
      if (lastValue) return;
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
    }
    throw new Error(
      `timed out waiting for ${label}; last value: ${JSON.stringify(lastValue)}; events: ${fixtureEvents.slice(-10).join('; ')}; fixture requests: ${requests.slice(-35).join(", ")}`,
    );
  };
  const waitForNode = async (predicate, label) => {
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      if (predicate()) return;
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
    }
    throw new Error(
      `timed out waiting for ${label}; fixture requests: ${requests.join(", ")}`,
    );
  };
  const waitForValue = async (expression, expected, label) => {
    const deadline = Date.now() + 20_000;
    let lastValue;
    while (Date.now() < deadline) {
      lastValue = await evaluate(expression);
      if (lastValue === expected) return;
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
    }
    const diagnosticValue = await evaluate(cardValue);
    const cardText = await evaluate(
      `document.querySelector('.node[data-node-key="${NODE1}"]')?.innerText`,
    );
    const appDiagnostics = await evaluate(
      `JSON.stringify({set:window.__vpSet,error:window.__vpError,applied:window.__vpApplied})`,
    );
    throw new Error(
      `timed out waiting for ${label}; got ${JSON.stringify(lastValue)}; card=${JSON.stringify(diagnosticValue)}; text=${JSON.stringify(cardText)}; app=${appDiagnostics}; events=${fixtureEvents.join("; ")}; requests ${requests.filter((path) => path.includes("validators") || path.includes("chain-rpc/status")).join(", ")}`,
    );
  };
  const cardValue = `document.querySelector('[data-node-key="${NODE1}"] [data-k="vp"]')?.textContent?.trim()`;
  const assertStatus = async (nodeId, label, color) => {
    // Exercise the actual card and map popup, not a source-text assertion.
    await waitFor("document.querySelectorAll('.validator-marker').length === 3", "all observed map markers");
    const actual = await evaluate(`(() => {
      const node = observedNodes.find(n => n.address === '${nodeId}');
      const card = document.querySelector('[data-node-key="${nodeId}"] [data-k="status"]');
      const marker = [...document.querySelectorAll('.validator-marker')].find(m =>
        m.getAttribute('aria-label').startsWith(maidenheadLocator(node.geo.latitude, node.geo.longitude) + ';'));
      marker?.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true, cancelable:true}));
      const row = [...document.querySelectorAll('.leaflet-popup li')].find(r => r.querySelector('span')?.textContent === node.name);
      const state = row?.querySelector('.validator-map-member-state');
      return {card:card?.textContent.trim(), cardColor:card && getComputedStyle(card).color,
        map:state?.textContent.split(' · ')[0], mapColor:state && getComputedStyle(state).color,
        markerLabel:marker?.getAttribute('aria-label'), markerColor:marker?.querySelector('.validator-marker-face') && getComputedStyle(marker.querySelector('.validator-marker-face')).backgroundImage};
    })()`);
    assert.equal(actual.card, label, JSON.stringify(actual));
    assert.equal(actual.map, label, JSON.stringify(actual));
    assert.equal(actual.cardColor, color, JSON.stringify(actual));
    assert.equal(actual.mapColor, color, JSON.stringify(actual));
    assert.ok(actual.markerColor.includes(color), JSON.stringify(actual));
    assert.ok(actual.markerLabel.includes(`1 ${label}`), JSON.stringify(actual));
    await evaluate("document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true})); true");
  };
  await waitFor(
    `Boolean(window.__refresh && document.querySelector('[data-node-key="${NODE1}"]'))`,
    "first node cards",
  );
  await waitFor(
    `/^Updated /.test(document.querySelector('#updated')?.textContent || '')`,
    "initial refresh",
  );
  assert.equal(await evaluate(cardValue), "0", "validator membership must resolve on the first poll while versions, peers and DNS are still held");
  await assertStatus(NODE0, "Validating", "rgb(120, 184, 61)");
  await assertStatus(NODE1, "Active", "rgb(255, 157, 74)");
  assert.ok(heldDetails.length > 0, "slow optional endpoints must actually be held");
  holdDetails = false;
  for (const release of heldDetails.splice(0)) release();
  await evaluate("detailsInFlight");
  await evaluate("activityInFlight");
  await waitForValue(`document.querySelector('[data-node-key="${NODE1}"] [data-k="poc"]')?.textContent`, "Committed", "participant-specific PoC");
  assert.equal(await evaluate(`document.querySelector('[data-node-key="${NODE1}"] [data-k="cpoc"]')?.textContent`), "No active event");
  assert.equal(await evaluate(`document.querySelector('[data-node-key="${NODE0}"] [data-k="poc"]')?.textContent`), "No commit yet");
  await waitForValue(
    `document.querySelector('#devshard-versions')?.textContent?.trim()`,
    "None approved",
    "valid empty DevShard approvals",
  );
  assert.ok(fixtureEvents.includes("approved versions query"),
    "current approved versions must use the dedicated chain query");
  assert.ok(!fixtureEvents.includes("deprecated params query"),
    "deprecated params projection must not be used as current approval state");
  assert.equal(await evaluate("document.querySelectorAll('.node').length"), 3,
    "participant records annotate only the existing observed cards");
  assert.equal(await evaluate("GDC_CONFIG.gatewayNode"), "node4");
  assert.equal(await evaluate("GDC_CONFIG.chainRpcHost"), "node0.gonka-dev.net");
  assert.equal(await evaluate("GDC_CONFIG.nodes.length"), 0);
  assert.equal(await evaluate("GDC_CONFIG.nodeCatalog.length"), 3);
  assert.ok(fixtureEvents.includes(`hardware query ${ACCOUNT0}`));
  assert.ok(fixtureEvents.includes(`hardware query ${ACCOUNT1}`));
  assert.ok(fixtureEvents.includes(`hardware query ${ACCOUNT4}`));
  assert.ok(!fixtureEvents.some((event) => event.includes(`hardware query ${NODE0}`) || event.includes(`hardware query ${NODE1}`)),
    "hardware queries must use participant account identities, never P2P IDs");
  assert.equal(await evaluate(`cardHardwareInventory.get("${NODE0}")?.state`), "observed");
  assert.equal(await evaluate(`cardHardwareInventory.get("${NODE1}")?.state`), "observed");
  assert.equal(await evaluate(`cardHardwareInventory.get("${NODE4}")?.state`), "observed");
  await evaluate("window.__originalLoadCurrentValidatorSet=GDC_NETWORK_OBSERVATION.loadCurrentValidatorSet; GDC_NETWORK_OBSERVATION.loadCurrentValidatorSet=async()=>({state:'unavailable',verified:false,complete:false,validators:[]}); true");
  participantScenario = "duplicate";
  await evaluate("window.__refresh()");
  await waitForNode(() => fixtureEvents.filter((event) => event.startsWith("participant page ")).length >= 2,
    "ambiguous participant-origin response");
  await waitForValue(`cardHardwareInventory.get("${NODE0}")?.state`, "unavailable", "ambiguous mapping refusal");
  assert.equal(fixtureEvents.filter((event) => event === `hardware query ${ACCOUNT0}`).length, 1,
    "ambiguous participants must not trigger arbitrary hardware requests");
  participantScenario = "complete";
  hardwareScenario = "mismatch";
  await evaluate("window.__refresh()");
  await waitForNode(() => fixtureEvents.filter((event) => event.startsWith("participant page ")).length >= 3,
    "hardware response identity mismatch");
  await waitForValue(`cardHardwareInventory.get("${NODE1}")?.state`, "unavailable", "mismatched hardware participant refusal");
  hardwareScenario = "matching";
  participantScenario = "malformed";
  await evaluate("window.__refresh()");
  await waitForNode(() => fixtureEvents.filter((event) => event.startsWith("participant page ")).length >= 4,
    "malformed participant response");
  await waitForValue(`cardHardwareInventory.get("${NODE0}")?.state`, "unavailable", "malformed participant inventory refusal");
  participantScenario = "complete";
  approvalScenario = "nonempty";
  let approvalQueryCount = fixtureEvents.filter((event) => event === "approved versions query").length;
  await evaluate("window.__refresh()");
  assert.equal(fixtureEvents.filter((event) => event === "approved versions query").length, approvalQueryCount + 1);
  assert.equal(await evaluate(`document.querySelector('#devshard-versions')?.textContent?.trim()`), "v4.1 · v5",
    "dedicated approvals must win when the deprecated params field is empty");
  assert.ok(!fixtureEvents.includes("deprecated params query"),
    "the deprecated params endpoint must not be queried as a fallback");
  approvalScenario = "malformed";
  approvalQueryCount += 1;
  await evaluate("window.__refresh()");
  assert.equal(fixtureEvents.filter((event) => event === "approved versions query").length, approvalQueryCount + 1);
  assert.equal(await evaluate(`document.querySelector('#devshard-versions')?.textContent?.trim()`), "Unavailable",
    "malformed approved-version payload must remain unavailable");
  approvalScenario = "malformed-entry";
  approvalQueryCount += 1;
  await evaluate("window.__refresh()");
  assert.equal(fixtureEvents.filter((event) => event === "approved versions query").length, approvalQueryCount + 1);
  assert.equal(await evaluate(`document.querySelector('#devshard-versions')?.textContent?.trim()`), "Unavailable",
    "incomplete approved-version records must remain unavailable");
  approvalScenario = "error";
  approvalQueryCount += 1;
  await evaluate("window.__refresh()");
  assert.equal(fixtureEvents.filter((event) => event === "approved versions query").length, approvalQueryCount + 1);
  assert.equal(await evaluate(`document.querySelector('#devshard-versions')?.textContent?.trim()`), "Unavailable",
    "failed approved-version request must remain unavailable");
  approvalScenario = "empty";
  approvalQueryCount += 1;
  await evaluate("window.__refresh()");
  assert.equal(fixtureEvents.filter((event) => event === "approved versions query").length, approvalQueryCount + 1);
  assert.equal(await evaluate(`document.querySelector('#devshard-versions')?.textContent?.trim()`), "None approved",
    "valid empty approval list must not become an error");
  await evaluate("GDC_NETWORK_OBSERVATION.loadCurrentValidatorSet=window.__originalLoadCurrentValidatorSet; true");
  await evaluate("window.__refresh()");
  const node0Inference = `document.querySelector('[data-node-key="${NODE0}"] [data-k="inferenced"]')?.textContent?.trim()`;
  const node0Dapi = `document.querySelector('[data-node-key="${NODE0}"] [data-k="dapi"]')?.textContent?.trim()`;
  await waitForValue(node0Inference, "0.2.16-post1", "fresh node-info chain version");
  assert.equal(await evaluate(node0Dapi), "0.2.15-post3", "DAPI version must remain sourced independently");
  await waitForNode(
    () => statusCounts.get("node0") >= 1 && statusCounts.get("node1") >= 1,
    "first RPC reads",
  );
  assert.equal(
    await evaluate(cardValue),
    "0",
    "first refresh must use the current set, never local stale node1 power",
  );
  holdValidatorSets = true;
  await evaluate(
    `window.__vpApplied=[]; const __load=GDC_NETWORK_OBSERVATION.loadCurrentValidatorSet; GDC_NETWORK_OBSERVATION.loadCurrentValidatorSet=async(...a)=>{try{const v=await __load(...a);window.__vpSet=v;return v}catch(e){window.__vpError=String(e);throw e}}; const __apply=GDC_NETWORK_OBSERVATION.applyCurrentVotingPower; GDC_NETWORK_OBSERVATION.applyCurrentVotingPower=(n,s)=>{const v=__apply(n,s);window.__vpApplied.push([n.validatorAddress,v,s?.verified,s?.blockHeight]);return v};`,
  );
  await evaluate("window.__refresh(); true");
  await waitForNode(
    () => validatorSets.length >= 1,
    "held current validator-set request",
  );
  await assertStatus(NODE1, "Active", "rgb(255, 157, 74)");
  const readsWhileHeld = requests.filter(path => path.endsWith('/status/network')).length;
  await evaluate("window.__refresh(); true");
  assert.equal(requests.filter(path => path.endsWith('/status/network')).length, readsWhileHeld,
    "overlapping refresh must share the in-flight observation instead of racing it");
  assert.notEqual(
    await evaluate(cardValue),
    "32",
    "unverified local status power must never appear during reference load",
  );
  assert.match(
    validatorSets[0].url,
    /^\/preview\/215\/status\/node0\/chain-rpc\/validators\?height=\d+&page=1&per_page=100$/,
  );
  await validatorSets[0].fulfill({
    result: {
      block_height: String(validatorSets[0].height),
      count: "1",
      total: "1",
      validators: [{ address: NODE0.toUpperCase(), voting_power: "63" }],
    },
  });
  await waitForValue(
    cardValue,
    "0",
    "node1 absent from the verified current set",
  );
  await evaluate("refreshInFlight");
  await assertStatus(NODE0, "Validating", "rgb(120, 184, 61)");
  await assertStatus(NODE1, "Active", "rgb(255, 157, 74)");

  await evaluate("window.__refresh(); true");
  await waitForNode(
    () => validatorSets.length >= 2,
    "second held validator-set request",
  );
  await assertStatus(NODE0, "Validating", "rgb(120, 184, 61)");
  assert.equal(
    await evaluate(cardValue),
    "0",
    "refresh must retain fresh verified power while the next set is pending",
  );
  const appliedBeforeFailure = await evaluate("window.__vpApplied.length");
  await validatorSets[1].fulfill(
    {
      result: {
        block_height: String(validatorSets[1].height),
        count: "1",
        total: "1",
        validators: [{ address: NODE0.toUpperCase(), voting_power: "63" }],
      },
    },
    { status: 503 },
  );
  await waitFor(
    `Boolean(window.__vpError && window.__vpApplied.length > ${appliedBeforeFailure})`,
    "failed reference read and fail-closed card update",
  );
  assert.match(await evaluate("window.__vpError"), /503|fetch|network|TypeError/i);
  assert.equal(await evaluate(cardValue), "0");
  await evaluate("refreshInFlight");
  await assertStatus(NODE0, "Validating", "rgb(120, 184, 61)");
  await assertStatus(NODE1, "Active", "rgb(255, 157, 74)");
  await evaluate("validatorSetObservedAt=Date.now()-45001; for(const node of observedNodes) {applyRetainedMembership(node); renderHostState(cards.get(nodeKey(node)),node)}; true");
  assert.equal(await evaluate(cardValue), "Unavailable", "expired membership must not remain current");
  await assertStatus(NODE0, "Active", "rgb(255, 157, 74)");
  holdValidatorSets = false;
  for (const scenario of ["stale", "mismatch"]) {
    versionScenario = scenario;
    await evaluate("window.__refresh()");
    await waitForValue(node0Inference, "Unavailable", `${scenario} node-info must not expose inventory as current`);
    assert.notEqual(await evaluate(node0Inference), "0.2.15");
    assert.notEqual(await evaluate(node0Inference), "0.2.16-post1");
    assert.equal(await evaluate(node0Dapi), "0.2.15-post3", "chain node-info must not be reused for DAPI");
  }
  versionScenario = "fresh";
  await evaluate("window.__refresh()");
  await waitForValue(node0Inference, "0.2.16-post1", "fresh node-info recovery after invalid observations");
  await assertStatus(NODE0, "Validating", "rgb(120, 184, 61)");
  await assertStatus(NODE1, "Active", "rgb(255, 157, 74)");
  const hostPreviewRequestStart = previewCanonicalChainApiRequests.length;
  await call("Page.navigate", { url: "https://preview.gonka-dev.net/215/" });
  await waitFor(
    `Boolean(window.__refresh && document.querySelector('[data-node-key="${NODE0}"]'))`,
    "host-style HTTPS preview node cards",
  );
  const hostStyleLocation = await evaluate(
    "JSON.stringify({href:location.href,hostname:location.hostname,pathname:location.pathname})",
  );
  assert.deepEqual(JSON.parse(hostStyleLocation), {
    href: "https://preview.gonka-dev.net/215/",
    hostname: "preview.gonka-dev.net",
    pathname: "/215/",
  });
  await waitForNode(
    () => previewCanonicalChainApiRequests
      .slice(hostPreviewRequestStart)
      .some((url) => url.endsWith("/chain-api/productscience/inference/inference/devshard_approved_versions")),
    "host-style preview canonical approved-versions request",
  );
  try {
    await waitFor(
      `document.querySelector('#devshard-versions')?.textContent?.trim() === "None approved"`,
      "host-style HTTPS preview canonical approved-versions read",
    );
  } catch (error) {
    const hostDiagnostics = await evaluate(
      `JSON.stringify({text:document.querySelector('#devshard-versions')?.textContent,title:document.querySelector('#devshard-versions')?.title})`,
    );
    throw new Error(`host-style preview did not render valid empty current approvals; ${hostDiagnostics}; canonical requests: ${previewCanonicalChainApiRequests.slice(hostPreviewRequestStart).filter((url) => url.endsWith("/chain-api/productscience/inference/inference/devshard_approved_versions")).length}`);
  }
  assert.ok(previewCanonicalChainApiRequests.some((url) =>
    url.startsWith("https://node0.gonka-dev.net/chain-api/")),
  "host-style HTTPS preview uses the canonical catalog chain API origin");
  const localRequestStart = requests.length;
  const localEventStart = fixtureEvents.length;
  await call("Page.navigate", { url: `http://127.0.0.1:${port}/local/` });
  await waitFor(
    `Boolean(window.__refresh && document.querySelector('[data-node-key="${NODE0}"]'))`,
    "non-preview local-origin node cards",
  );
  await waitFor(
    `document.querySelector('#devshard-versions')?.textContent?.trim() === "None approved"`,
    "non-preview local-origin empty approval list",
  );
  const localLayout = JSON.parse(await evaluate(
    "JSON.stringify({href:location.href,chainRpcHost:GDC_CONFIG.chainRpcHost,gatewayNode:GDC_CONFIG.gatewayNode,chainRpcOrigin:GDC_CONFIG.chainRpcOrigin,nodes:GDC_CONFIG.nodes.length,nodeCatalog:GDC_CONFIG.nodeCatalog.length})",
  ));
  assert.equal(localLayout.href, `http://127.0.0.1:${port}/local/`);
  assert.equal(localLayout.chainRpcHost, "node0.gonka-dev.net");
  assert.equal(localLayout.gatewayNode, "node4");
  assert.equal(localLayout.chainRpcOrigin, "/local/status/node0");
  assert.equal(localLayout.nodes, 0);
  assert.equal(localLayout.nodeCatalog, 3);
  await waitForNode(
    () => requests.slice(localRequestStart).includes(
      "/local/status/node0/chain-api/productscience/inference/inference/devshard_approved_versions",
    ),
    "non-preview explicit local approved-versions origin",
  );
  await waitForNode(
    () => fixtureEvents.slice(localEventStart).includes(`local hardware query ${ACCOUNT0}`),
    "non-preview local hardware query by participant identity",
  );
  assert.ok(requests.slice(localRequestStart).includes("/local/status/node0/chain-rpc/status"),
    "selected node0 identity must be verified through the explicit local origin");
  assert.ok(!requests.slice(localRequestStart).some((path) => path.includes("/local/status/node4/chain-api/")),
    "gatewayNode must not override the selected chainRpcHost identity");
  assert.equal(await evaluate(`cardHardwareInventory.get("${NODE0}")?.state`), "observed");
  assert.equal(await evaluate(`cardHardwareInventory.get("${NODE1}")?.state`), "observed");
  assert.equal(await evaluate(`cardHardwareInventory.get("${NODE4}")?.state`), "observed");
  for (const scenario of [
    { path: "/ambiguous/", name: "duplicate selected catalog host" },
    { path: "/missing/", name: "missing selected catalog host" },
  ]) {
    const requestStart = requests.length;
    await call("Page.navigate", { url: `http://127.0.0.1:${port}${scenario.path}` });
    await waitFor(
      `Boolean(window.__refresh && document.querySelector('[data-node-key="${NODE0}"]'))`,
      `${scenario.name} node cards`,
    );
    await waitFor(
      `document.querySelector('#devshard-versions')?.textContent?.trim() === "Unavailable"`,
      `${scenario.name} fails closed for approved versions`,
    );
    await waitForNode(
      () => requests.slice(requestStart).some((path) => path.endsWith("/status/network")),
      `${scenario.name} observed network response`,
    );
    assert.equal(await evaluate(`cardHardwareInventory.get("${NODE0}")?.state`), "unavailable");
    assert.ok(!requests.slice(requestStart).some((path) => path.includes("/chain-api/")),
      `${scenario.name} must not issue unbound chain API requests`);
  }
  process.stdout.write(
    "PASS browser app binds preview and explicit non-preview origins to a unique catalog peer, fails closed on missing/duplicate host matches, and rejects stale/mismatched identity and local validator power\n",
  );
} finally {
  socket?.close();
  await stopChromeDevTools(browser);
  server.close();
  await rm(profile, { recursive: true, force: true });
}
