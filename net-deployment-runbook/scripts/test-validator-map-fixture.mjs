#!/usr/bin/env node
// Deterministic local browser contract for the same-origin Natural Earth SVG
// and validator markers. It never contacts a public DevNet or map provider.
import { createServer } from "node:http";
import { createReadStream } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize, resolve } from "node:path";
import {
  startChromeDevTools,
  stopChromeDevTools,
} from "./chrome-devtools.mjs";

const [siteRootText, evidenceDir] = process.argv.slice(2);
if (!siteRootText || !evidenceDir) {
  throw new Error(
    "usage: test-validator-map-fixture.mjs SITE_ROOT EVIDENCE_DIR",
  );
}
const siteRoot = resolve(siteRootText);
const now = new Date().toISOString();
const delay = (ms) =>
  new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
const mime = {
  ".css": "text/css",
  ".html": "text/html",
  ".js": "text/javascript",
  ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
};
const forbiddenMapRequest =
  /(?:cartocdn|unpkg\.com|openstreetmap|openfreemap|maplibre)/i;

function validateWorldSvg(svg) {
  if (
    !/^<\?xml version="1\.0"\?>\n<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" /u.test(
      svg,
    )
  ) {
    throw new Error("world-map.svg lacks the expected passive SVG root");
  }
  if (
    /<(?:script|foreignObject|image|use|style|animate)\b|\son[a-z]+\s*=|(?:href|src)\s*=|(?:xlink:|<!DOCTYPE|<!ENTITY)/iu.test(
      svg,
    )
  ) {
    throw new Error("world-map.svg contains an unsafe construct");
  }
  const tokens = svg.match(/<[^>]+>|[^<]+/gu) || [];
  const tags = tokens.filter((token) => token.startsWith("<"));
  const allowedTag = (tag) =>
    /^<\?xml version="1\.0"\?>$/u.test(tag) ||
    /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" version="1\.2" baseProfile="tiny" width="2000" height="1000" viewBox="0 0 2000 1000" stroke-linecap="round" stroke-linejoin="round">$/u.test(
      tag,
    ) ||
    tag === '<g id="land" fill="#292c39" stroke="#73788e" stroke-width="1.3">' ||
    /^<path d="[MLZ0-9 .-]+"(?: fill-rule="evenodd")?\/>$/u.test(tag) ||
    tag === "</g>" ||
    tag === "</svg>";
  if (
    tokens.join("") !== svg ||
    tags.length < 5 ||
    !tags.every(allowedTag) ||
    !tokens.every((token) => token.startsWith("<") || /^\s+$/u.test(token))
  ) {
    throw new Error("world-map.svg violates the passive path allowlist");
  }
}

const worldSvg = await readFile(join(siteRoot, "world-map.svg"), "utf8");
validateWorldSvg(worldSvg);
const worldMapProvenance = await readFile(join(siteRoot, "README.md"), "utf8");
for (const expected of [
  "north-up Plate Carree longitude `[-180, 180]`,\n  latitude `[-90, 90]`",
  "exact `2000×1000` (`2:1`) viewport",
  "Natural Earth `50m Land`",
  "build-world-map.sh",
]) {
  if (!worldMapProvenance.includes(expected))
    throw new Error(`world-map.svg provenance lacks ${expected}`);
}
for (const relative of ["index.html", "src/app.js", "readability.css"]) {
  const source = await readFile(join(siteRoot, relative), "utf8");
  if (forbiddenMapRequest.test(source)) {
    throw new Error(`forbidden map-provider reference in ${relative}`);
  }
}
const indexHtml = await readFile(join(siteRoot, "index.html"), "utf8");
for (const localLeafletAsset of [
  "vendor/leaflet/leaflet.css",
  "vendor/leaflet/leaflet.js",
]) {
  if (!indexHtml.includes(localLeafletAsset))
    throw new Error(`missing local Leaflet asset ${localLeafletAsset}`);
}
for (const invalid of [
  "<svg><script/></svg>",
  '<svg><image href="https://example.test/a.png"/></svg>',
  '<svg onclick="x()"/>',
  "<<script/></svg>",
]) {
  try {
    validateWorldSvg(invalid);
  } catch {
    continue;
  }
  throw new Error(`unsafe SVG sample was accepted: ${invalid}`);
}

const config = (port) =>
  `window.GDC_CONFIG = ${JSON.stringify({
    chainId: "fixture-chain",
    model: "Qwen/Qwen3-0.6B",
    chainRpcHost: "fixture.invalid",
    chainRpcOrigin: `http://127.0.0.1:${port}`,
    grafanaNetwork: "https://grafana.gonka-dev.net/d/gdc-network/fixture?kiosk",
    grafanaInference:
      "https://grafana.gonka-dev.net/d/gdc-inference/fixture?kiosk",
    nodes: [
      {
        name: "fixture-a",
        address: "gonka1fixturea",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.1",
        geo: {
          latitude: 48.15,
          longitude: 17.11,
          city: "<Bratislava>",
          country: "Slovakia",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-b",
        address: "gonka1fixtureb",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.2",
        geo: {
          latitude: 48.15,
          longitude: 17.11,
          city: "<Bratislava>",
          country: "Slovakia",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-clamped",
        address: "gonka1fixturec",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.3",
        geo: {
          latitude: 91,
          longitude: -200,
          city: "North edge",
          country: "Fixtureland",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-invalid",
        address: "gonka1fixtured",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.4",
        geo: {
          latitude: "NaN",
          longitude: 0,
          city: "Ignored",
          country: "Fixtureland",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-greenwich",
        address: "gonka1fixturegreenwich",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.5",
        geo: {
          latitude: 0,
          longitude: 0,
          city: "Greenwich",
          country: "UK",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-kansas",
        address: "gonka1fixturekansas",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.10",
        geo: {
          latitude: 39.0997285,
          longitude: -94.5785681,
          city: "Kansas City",
          country: "United States",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-south",
        address: "gonka1fixturesouth",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.6",
        geo: {
          latitude: -45,
          longitude: 90,
          city: "South east",
          country: "Fixtureland",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-antimeridian",
        address: "gonka1fixtureantimeridian",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.7",
        geo: {
          latitude: 45,
          longitude: 180,
          city: "Antimeridian",
          country: "Fixtureland",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-south-pole",
        address: "gonka1fixturesouthpole",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.8",
        geo: {
          latitude: -90,
          longitude: -180,
          city: "South pole",
          country: "Fixtureland",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-north-pole",
        address: "gonka1fixtureNorthPole",
        publicHost: "fixture.local",
        statusBase: `http://127.0.0.1:${port}`,
        ip: "127.0.0.9",
        geo: {
          latitude: 90,
          longitude: -180,
          city: "North pole",
          country: "Fixtureland",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      },
      {
        name: "fixture-dynamic",
        mode: "skip",
        reason: "fixture skip path",
        address: "gonka1fixturedynamic",
        publicHost: "geo-fixture.invalid",
        statusBase: `http://127.0.0.1:${port}`,
        gpuProfile: "a5000-24g",
      },
      ...Array.from({ length: 11 }, (_, index) => ({
        name: `fixture-overflow-${index + 1}`,
        mode: "skip",
        reason: "fixture dense Host deck",
        address: `gonka1fixtureoverflow${index + 1}`,
        publicHost: `overflow-${index + 1}.fixture.local`,
        statusBase: `http://127.0.0.1:${port}`,
        ip: `192.0.2.${index + 1}`,
        geo: {
          latitude: "NaN",
          longitude: 0,
          city: "Dense deck only",
          country: "Fixtureland",
          isp: "fixture",
        },
        gpuProfile: "a5000-24g",
      })),
    ],
  })};\n`;
const participantKeys = [
  "a",
  "b",
  "c",
  "d",
  "greenwich",
  "kansas",
  "south",
  "antimeridian",
  "southpole",
  "NorthPole",
  "dynamic",
  ...Array.from({ length: 11 }, (_, index) => `overflow${index + 1}`),
];
let participantLimit = 11;
const api = (port) => ({
  "/status/participants": {
    block_height: "424",
    participant: participantKeys.slice(0, participantLimit).map((key) => ({
      address: `gonka1fixture${key}`,
      inference_url:
        key === "dynamic"
          ? "https://geo-fixture.invalid"
          : `http://127.0.0.1:${port}`,
      validator_key: `fixture-key-${key}`,
      status: key === "a" ? "INACTIVE" : "ACTIVE",
    })),
  },
  "/status/gpus": {
    data: {
      result: [{ metric: { host: "fixture-a", gpu_name: "NVIDIA RTX A5000" } }],
    },
  },
  "/status/software": {
    data: {
      result: [
        {
          metric: { host: "fixture-a", component: "chain", version: "v1.2.3" },
        },
        { metric: { host: "fixture-a", component: "DAPI", version: "v2.3.4" } },
        {
          metric: { host: "fixture-a", component: "MLNode", version: "v3.4.5" },
        },
      ],
    },
  },
  "/status/telegram-consumer": { status: "ok", inference_ready: true },
  "/chain-rpc/status": {
    result: {
      sync_info: {
        latest_block_height: "424",
        catching_up: false,
        latest_block_time: now,
      },
    },
  },
  "/chain-rpc/validators": { result: { validators: [] } },
  "/chain-rpc/net_info": { result: { n_peers: "4" } },
  "/v1/versions": {},
  "/status/gateway/v1/status": {
    escrow_id: "fixture",
    active: true,
    phase: "active",
    requests_blocked: false,
  },
  "/status/gateway-health": {
    state: "READY",
    checked_at: now,
    curl_exit: 0,
    http_status: 200,
    latency_ms: 1,
    reason: "",
    admission: "dispatched_once",
    admission_id: "fixture",
    safe_generation: "fixture",
    arrival_height: 424,
    permit_height: 424,
    dispatch_height: 424,
    response_height: 424,
  },
});

const server = createServer(async (request, response) => {
  const pathname = new URL(
    request.url,
    `http://127.0.0.1:${server.address().port}`,
  ).pathname;
  if (pathname === "/config.js") {
    response.writeHead(200, { "content-type": "text/javascript" });
    response.end(config(server.address().port));
    return;
  }
  if (pathname === "/status/gateway/metrics") {
    response.writeHead(200, { "content-type": "text/plain" });
    response.end(
      "devshard_gateway_inflight_requests 0\ndevshard_gateway_inflight_input_tokens 0\ndevshard_gateway_requests_total 7\ndevshard_gateway_limit_rejections_total 0\ndevshard_gateway_capacity_scale 1\n",
    );
    return;
  }
  const state = api(server.address().port)[pathname];
  if (state) {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(state));
    return;
  }
  const relative = pathname === "/" ? "/index.html" : pathname;
  const file = resolve(siteRoot, `.${normalize(relative)}`);
  if (!file.startsWith(`${siteRoot}/`)) {
    response.writeHead(403);
    response.end();
    return;
  }
  try {
    await stat(file);
    response.writeHead(200, {
      "content-type": mime[extname(file)] || "application/octet-stream",
    });
    createReadStream(file).pipe(response);
  } catch {
    response.writeHead(404);
    response.end();
  }
});
await new Promise((resolvePromise, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolvePromise);
});
const profile = await mkdtemp(join(tmpdir(), "gdc-map-fixture-"));
let browser;
let socket;
let sequence = 0;
let sessionId;
const pending = new Map();
const requests = [];
const pageDiagnostics = [];
const call = (method, params = {}, target = sessionId) =>
  new Promise((resolvePromise, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve: resolvePromise, reject });
    socket.send(
      JSON.stringify({
        id,
        method,
        params,
        ...(target ? { sessionId: target } : {}),
      }),
    );
  });
const mapRestorationExpression =
  'JSON.stringify((()=>{const map=document.querySelector("#validator-map"),mr=map?.getBoundingClientRect(),world=document.querySelector(".validator-map-world")?.getBoundingClientRect(),covers=(value,bounds)=>Boolean(value&&bounds&&value.left<=bounds.left+1&&value.right>=bounds.right-1);return{worldCoversMap:covers(world,mr),popup:Boolean(document.querySelector(".leaflet-popup")),world:world&&{left:world.left,right:world.right,top:world.top,bottom:world.bottom},map:mr&&{left:mr.left,right:mr.right,top:mr.top,bottom:mr.bottom}}})())';
const waitForMapRestoration = async (context) => {
  let state;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const { result } = await call("Runtime.evaluate", {
      expression: mapRestorationExpression,
      returnByValue: true,
    });
    state = JSON.parse(result.value);
    if (state.worldCoversMap && !state.popup) return state;
    await delay(100);
  }
  throw new Error(`${context} failed: ${JSON.stringify(state)}`);
};
const dragMapRight = async (distance = 500) => {
  await call("Runtime.evaluate", {
    expression:
      'document.querySelector("#validator-map")?.scrollIntoView({behavior:"instant",block:"center"})',
  });
  await delay(80);
  const { result } = await call("Runtime.evaluate", {
    expression:
      'JSON.stringify((()=>{const rect=document.querySelector("#validator-map")?.getBoundingClientRect();return{x:(rect?.left||0)+(rect?.width||0)/2,y:(rect?.top||0)+(rect?.height||0)/2,right:innerWidth-2,map:rect&&{left:rect.left,top:rect.top,right:rect.right,bottom:rect.bottom},world:(()=>{const value=document.querySelector(".validator-map-world")?.getBoundingClientRect();return value&&{left:value.left,top:value.top,right:value.right,bottom:value.bottom}})()}})())',
    returnByValue: true,
  });
  const start = JSON.parse(result.value);
  const endX = Math.min(start.right, start.x + distance);
  const middleX = start.x + (endX - start.x) / 3;
  if (endX - start.x < 100)
    throw new Error(`map drag target is too narrow: ${JSON.stringify(start)}`);
  await call("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: start.x,
    y: start.y,
  });
  await call("Input.dispatchMouseEvent", {
    type: "mousePressed",
    x: start.x,
    y: start.y,
    button: "left",
    buttons: 1,
    clickCount: 1,
  });
  await delay(100);
  await call("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: middleX,
    y: start.y,
    button: "left",
    buttons: 1,
  });
  await delay(120);
  await call("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: endX,
    y: start.y,
    button: "left",
    buttons: 1,
  });
  await delay(120);
  await call("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x: endX,
    y: start.y,
    button: "left",
    clickCount: 1,
  });
  return { ...start, endX };
};
try {
  const chromeSession = await startChromeDevTools({
    chrome: process.env.CHROME_BIN || "google-chrome",
    profile,
    context: "validator-map fixture",
  });
  browser = chromeSession.browser;
  socket = new WebSocket(
    (await chromeSession.waitForEndpoint()).webSocketDebuggerUrl,
  );
  await new Promise((resolvePromise, reject) => {
    socket.addEventListener("open", resolvePromise, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const waiter = pending.get(message.id);
      if (!waiter) return;
      pending.delete(message.id);
      message.error
        ? waiter.reject(new Error(message.error.message))
        : waiter.resolve(message.result);
      return;
    }
    if (message.method === "Runtime.exceptionThrown") {
      const exception = message.params.exceptionDetails;
      pageDiagnostics.push(
        `page exception: ${exception.exception?.description || exception.text}`,
      );
      return;
    }
    if (message.method === "Log.entryAdded") {
      const entry = message.params.entry;
      pageDiagnostics.push(`browser ${entry.level}: ${entry.text}`);
      return;
    }
    if (message.method === "Network.requestWillBeSent")
      requests.push(message.params.request.url);
  });
  const { targetId } = await call(
    "Target.createTarget",
    { url: "about:blank" },
    undefined,
  );
  ({ sessionId } = await call(
    "Target.attachToTarget",
    { targetId, flatten: true },
    undefined,
  ));
  await call("Page.enable");
  await call("Network.enable");
  await call("Runtime.enable");
  await call("Log.enable");
  await call("Page.addScriptToEvaluateOnNewDocument", {
    source: `{
      const nativeFetch = window.fetch.bind(window);
      window.__fixtureGeoIpRequests = 0;
      window.fetch = (input, options) => {
        const url = String(input);
        if (url.startsWith("https://cloudflare-dns.com/dns-query?")) {
          return Promise.resolve(new Response(JSON.stringify({
            Answer: [
              { data: "203.0.113.10" },
              { data: "203.0.113.11" },
            ],
          }), { headers: { "content-type": "application/json" } }));
        }
        if (url.startsWith("https://ipwho.is/")) {
          window.__fixtureGeoIpRequests += 1;
          if (url.endsWith("203.0.113.11"))
            return Promise.reject(new Error("fixture GeoIP failure"));
          return Promise.resolve(new Response(JSON.stringify({
            success: true,
            latitude: 48.15,
            longitude: 17.11,
            city: "Bratislava",
            country: "Slovakia",
            connection: { isp: "fixture" },
          }), { headers: { "content-type": "application/json" } }));
        }
        return nativeFetch(input, options);
      };
    }`,
  });
  const reports = [];
  const mapStateExpression =
    'JSON.stringify((()=>{const map=document.querySelector("#validator-map"),rect=map?.getBoundingClientRect(),world=map?.querySelector(".validator-map-world"),worldRect=world?.getBoundingClientRect(),markers=[...map.querySelectorAll(".validator-marker")].map(marker=>{const r=marker.getBoundingClientRect();return{label:marker.getAttribute("aria-label")||"",classes:[...marker.classList],fill:marker.getAttribute("fill"),left:r.left+r.width/2,top:r.top+r.height/2,width:r.width,height:r.height}});return{world:Boolean(world?.complete&&world?.naturalWidth),worldRatio:worldRect?worldRect.width/worldRect.height:0,validators:Number(map?.dataset.validatorCount),markerCount:Number(map?.dataset.markerCount),hitTargetCount:map?.querySelectorAll(".validator-marker-hit").length||0,centersInside:markers.every(marker=>marker.left>=rect.left-.1&&marker.left<=rect.right+.1&&marker.top>=rect.top-.1&&marker.top<=rect.bottom+.1),markerNodes:markers,mapRect:rect&&{left:rect.left,top:rect.top,right:rect.right,bottom:rect.bottom},worldRect:worldRect&&{left:worldRect.left,top:worldRect.top,width:worldRect.width,height:worldRect.height},scrollWidth:document.documentElement.scrollWidth,width:innerWidth}})())';
  const hostGeometryExpression = `JSON.stringify((() => {
    const deck = document.querySelector("#nodes");
    const cards = [...document.querySelectorAll("#nodes .node")];
    const expandedCards = cards.filter(card => card.classList.contains("is-expanded"));
    const collapsedCards = cards.filter(card => card.classList.contains("is-collapsed"));
    const card = expandedCards[0];
    if (!deck || !card) return { pass: false, error: "no expanded Host card" };
    const setText = (selector, value) => {
      const element = card.querySelector(selector);
      if (element) element.textContent = value;
      return element;
    };
    const bounds = element => {
      const rect = element?.getBoundingClientRect();
      return rect && { top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right, width: rect.width, height: rect.height };
    };
    const geometrySnapshot = () => Object.fromEntries([
      ...cards.map((candidate, index) => [\`card-\${index}\`, bounds(candidate)]),
      ["header", bounds(card.querySelector("h3"))],
      ["host", bounds(card.querySelector('[data-k="host"]'))],
      ["status", bounds(card.querySelector('[data-k="status"]'))],
      ...[...(card.querySelector(".node-details")?.children || [])].map((element, index) => [\`detail-\${index}-\${element.dataset.kRow || element.dataset.k || element.tagName.toLowerCase()}\`, bounds(element)]),
    ]);
    const statusProbe = {
      participantKnown: true,
      participantState: "ACTIVE",
      validatorKnown: true,
      votingPower: "10",
      catchingUp: false,
      blocksBehind: 0,
      blockAgeSeconds: 0,
      progressing: true,
      referenceKnown: true,
      referenceAgrees: true,
    };
    renderHostState(card, { ...statusProbe, endpointState: "reachable" });
    const validatingGeometry = geometrySnapshot();
    renderHostState(card, { ...statusProbe, endpointState: "unavailable", endpointDiagnostic: "Network error" });
    const activeGeometry = geometrySnapshot();
    const statusLayoutShifts = Object.keys(validatingGeometry).flatMap(key => {
      const before = validatingGeometry[key];
      const after = activeGeometry[key];
      if (!before || !after) return [{ key, before, after }];
      return ["top", "left", "width", "height"].some(metric => Math.abs(before[metric] - after[metric]) > 0.1)
        ? [{ key, before, after }]
        : [];
    });
    setText('[data-k="host"]', "node0.example.test with a deliberately long hostname");
    setText('[data-k="status"]', "VALIDATING");
    setText('[data-k="status-reason"]', "Effective and synchronized validator with a long diagnostic reason");
    setText('[data-k="scope"]', "gonka1abcdefghijklmnopqrstuvwxyz0123456789");
    setText('[data-k="height"]', "123456789");
    setText('[data-k="vp"]', "9223372036854775807");
    setText('[data-k="sync"]', "Synced");
    setText('[data-k="endpoint"]', "Unavailable – Network error");
    setText('[data-k="peers"]', "123");
    setText('[data-k="versions"]', "chain v2026.09.02-extremely-long-build-identifier · DAPI v0.2.16-post999999999999 · MLNode v3.0.14-post2-with-another-extremely-long-build-identifier");
    const gpuRow = card.querySelector('[data-k-row="gpu"]');
    if (gpuRow) gpuRow.hidden = false;
    setText('[data-k="gpu"]', "RTX PRO 2000 Blackwell ×8 + GeForce RTX 4090 SUPER Extremely Long Vendor Edition ×8 + Accelerator Model With An UnbrokenIdentifier012345678901234567890123456789 – net");
    const textBounds = element => {
      if (!element) return null;
      const range = document.createRange();
      range.selectNodeContents(element);
      return bounds(range);
    };
    const fieldInfo = selector => {
      const element = card.querySelector(selector);
      const rect = bounds(element);
      const text = textBounds(element);
      const visible = Boolean(element && element.offsetParent !== null && rect && rect.right > rect.left && rect.bottom > rect.top && text && text.right > text.left && text.bottom > text.top);
      return {
        text: element?.textContent?.trim() || "",
        visible,
        clipped: Boolean(!visible || element.scrollWidth > element.clientWidth || element.scrollHeight > element.clientHeight || text.left < rect.left - 2 || text.right > rect.right + 2 || text.top < rect.top - 2 || text.bottom > rect.bottom + 2),
      };
    };
    const details = card.querySelector(".node-details");
    const rows = [card.querySelector("h3"), ...(details?.children || [])]
      .filter(row => row && row.offsetParent !== null)
      .map(element => ({
        key: element.dataset.kRow || element.dataset.k || element.tagName.toLowerCase(),
        bounds: bounds(element),
        textBounds: textBounds(element),
      }));
    const rowOverlaps = rows.slice(0, -1).flatMap((row, index) => {
      const next = rows[index + 1];
      return row.textBounds && next.bounds && row.textBounds.bottom > next.bounds.top + 0.5
        ? [{ from: row.key, to: next.key, textBottom: row.textBounds.bottom, nextTop: next.bounds.top }]
        : [];
    });
    const cardRect = card.getBoundingClientRect();
    const contentBottom = rows.reduce((bottom, row) => Math.max(bottom, row.textBounds?.bottom ?? -Infinity), -Infinity);
    const deckRect = deck.getBoundingClientRect();
    const cardRects = cards.map(candidate => candidate.getBoundingClientRect());
    const deckStyle = getComputedStyle(deck);
    const mobile = innerWidth <= 700;
    let expectedExpandedCount = Math.min(innerWidth <= 900 ? 1 : innerWidth < 1200 ? 2 : 4, cards.length);
    while (expectedExpandedCount > 1 && (deck.clientWidth - (cards.length - expectedExpandedCount) * 32) / expectedExpandedCount < 270) expectedExpandedCount -= 1;
    const oneRow = cardRects.every(rect => Math.abs(rect.top - cardRects[0].top) <= 0.5 && Math.abs(rect.bottom - cardRects[0].bottom) <= 0.5);
    const cardsInside = cardRects.every(rect => rect.left >= deckRect.left - 1 && rect.right <= deckRect.right + 1);
    const initialDeckScrollLeft = deck.scrollLeft;
    deck.scrollLeft = 0;
    const firstCardAtStart = (() => {
      const rect = cards[0]?.getBoundingClientRect();
      return Boolean(rect && rect.left >= deckRect.left - 1 && rect.right <= deckRect.right + 1);
    })();
    const maximumDeckScrollLeft = Math.max(0, deck.scrollWidth - deck.clientWidth);
    deck.scrollLeft = maximumDeckScrollLeft;
    const lastCardAtEnd = (() => {
      const rect = cards.at(-1)?.getBoundingClientRect();
      return Boolean(rect && rect.left >= deckRect.left - 1 && rect.right <= deckRect.right + 1);
    })();
    const appliedDeckScrollLeft = deck.scrollLeft;
    deck.scrollLeft = initialDeckScrollLeft;
    const deckOverflows = maximumDeckScrollLeft > 1;
    const minimumDeckWidth = mobile
      ? deck.clientWidth
      : expectedExpandedCount * 270 + (cards.length - expectedExpandedCount) * 32;
    const overflowExpected = !mobile && minimumDeckWidth > deck.clientWidth + 1;
    const cardsReachable = firstCardAtStart && (!deckOverflows || (appliedDeckScrollLeft > 1 && lastCardAtEnd));
    const expandedGeometry = expandedCards.every(candidate => {
      const rect = candidate.getBoundingClientRect();
      return mobile
        ? Math.abs(rect.width - deck.clientWidth) <= 1
        : Math.abs(rect.height - 424) <= 0.5 && rect.width >= 269;
    });
    const collapsedGeometry = collapsedCards.every(candidate => {
      const rect = candidate.getBoundingClientRect();
      return mobile
        ? Math.abs(rect.height - 52) <= 0.5 && Math.abs(rect.width - deck.clientWidth) <= 1
        : Math.abs(rect.height - 424) <= 0.5 && rect.width >= 31 && rect.width <= 33;
    });
    const collapsedSemantics = collapsedCards.every(candidate => {
      const host = candidate.querySelector('[data-k="host"]');
      const status = candidate.querySelector('[data-k="status"]');
      const candidateDetails = candidate.querySelector(".node-details");
      const button = candidate.querySelector(".node-toggle");
      if (status) status.textContent = "VALIDATING";
      return Boolean(host?.offsetParent && status?.offsetParent && status.scrollWidth <= status.clientWidth && status.scrollHeight <= status.clientHeight && candidateDetails?.hidden && button?.getAttribute("aria-expanded") === "false" && button?.getAttribute("aria-controls") === candidateDetails?.id);
    });
    const fields = {
      host: fieldInfo('[data-k="host"]'),
      status: fieldInfo('[data-k="status"]'),
      statusReason: fieldInfo('[data-k="status-reason"]'),
      scope: fieldInfo('[data-k="scope"]'),
      height: fieldInfo('[data-k="height"]'),
      votingPower: fieldInfo('[data-k="vp"]'),
      sync: fieldInfo('[data-k="sync"]'),
      endpoint: fieldInfo('[data-k="endpoint"]'),
      peers: fieldInfo('[data-k="peers"]'),
      software: fieldInfo('[data-k="versions"]'),
      gpu: fieldInfo('[data-k="gpu"]'),
    };
    const hiddenProbe = card.querySelector('[data-k="status-reason"]');
    const hiddenBefore = hiddenProbe?.style.display;
    if (hiddenProbe) hiddenProbe.style.display = "none";
    const hiddenRect = hiddenProbe?.getBoundingClientRect();
    const hiddenRange = hiddenProbe ? (() => { const range = document.createRange(); range.selectNodeContents(hiddenProbe); return range.getBoundingClientRect(); })() : null;
    const hiddenVisible = Boolean(hiddenProbe && hiddenProbe.offsetParent !== null && hiddenRect && hiddenRect.width > 0 && hiddenRect.height > 0 && hiddenRange && hiddenRange.width > 0 && hiddenRange.height > 0);
    const hiddenRejected = Boolean(hiddenProbe && (!hiddenVisible || getComputedStyle(hiddenProbe).display === "none"));
    if (hiddenProbe) hiddenProbe.style.display = hiddenBefore;
    const skippedCard = cards.find((candidate) => candidate.classList.contains("skip"));
    const skippedGpuRow = skippedCard?.querySelector('[data-k-row="gpu"]');
    const skippedGpuValue = skippedGpuRow?.querySelector('[data-k="gpu"]');
    const skippedGpu = {
      exists: Boolean(skippedCard),
      hidden: Boolean(skippedGpuRow?.hidden),
      display: skippedGpuRow ? getComputedStyle(skippedGpuRow).display : null,
      text: skippedGpuValue?.textContent?.trim() || "",
      clientHeight: skippedGpuRow?.clientHeight || 0,
    };
    const initialExpandedKey = expandedCards[0]?.dataset.nodeKey;
    const activatedCard = collapsedCards[0];
    const activatedKey = activatedCard?.dataset.nodeKey;
    activatedCard?.querySelector(".node-toggle")?.click();
    const afterExpanded = cards.filter(candidate => candidate.classList.contains("is-expanded"));
    const activated = cards.find(candidate => candidate.dataset.nodeKey === activatedKey);
    const evicted = cards.find(candidate => candidate.dataset.nodeKey === initialExpandedKey);
    const activationValid = Boolean(
      activated &&
      activated.classList.contains("is-expanded") &&
      activated.querySelector(".node-toggle")?.getAttribute("aria-expanded") === "true" &&
      !activated.querySelector(".node-details")?.hidden &&
      evicted &&
      evicted.classList.contains("is-collapsed") &&
      evicted.querySelector(".node-toggle")?.getAttribute("aria-expanded") === "false" &&
      evicted.querySelector(".node-details")?.hidden &&
      afterExpanded.length === expectedExpandedCount
    );
    const activatedButton = activated?.querySelector(".node-toggle");
    activatedButton?.focus();
    activatedButton?.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true }));
    const activatedIndex = cards.indexOf(activated);
    const expectedFocusedKey = cards[(activatedIndex + 1) % cards.length]?.dataset.nodeKey;
    const focusedKey = document.activeElement?.closest(".node")?.dataset.nodeKey;
    const keyboardValid = Boolean(activatedButton && focusedKey === expectedFocusedKey);
    const complete = Object.values(fields).every(field => field.text && field.visible && !field.clipped);
    const negativeTracking = [...document.querySelectorAll("body *")]
      .filter(element => {
        const spacing = getComputedStyle(element).letterSpacing;
        return spacing !== "normal" && Number.parseFloat(spacing) < 0;
      })
      .map(element => element.tagName + "." + element.className);
    const desktopLayout = !mobile && deckStyle.flexDirection === "row" && oneRow;
    const mobileLayout = mobile && deckStyle.flexDirection === "column" && !oneRow;
    return {
      pass: cards.length > 5 && expandedCards.length === expectedExpandedCount && collapsedCards.length === cards.length - expectedExpandedCount && Number(deck.dataset.expandedCount) === expectedExpandedCount && deck.getAttribute("role") === "list" && deck.getAttribute("aria-label")?.includes("Host accordion") && deckStyle.overflowX === (mobile ? "visible" : "auto") && deckOverflows === overflowExpected && cardsReachable && (deckOverflows || cardsInside) && expandedGeometry && collapsedGeometry && collapsedSemantics && (mobile ? mobileLayout : desktopLayout) && card.scrollHeight <= card.clientHeight && rowOverlaps.length === 0 && contentBottom <= cardRect.bottom + 0.5 && complete && negativeTracking.length === 0 && statusLayoutShifts.length === 0 && hiddenRejected && skippedGpu.exists && skippedGpu.hidden && skippedGpu.display === "none" && skippedGpu.text === "" && skippedGpu.clientHeight === 0 && activationValid && keyboardValid && document.documentElement.scrollWidth <= innerWidth,
      expectedExpandedCount,
      initialExpandedCount: expandedCards.length,
      collapsedCount: collapsedCards.length,
      layout: { mobile, flexDirection: deckStyle.flexDirection, oneRow, cardsInside, cardsReachable, firstCardAtStart, lastCardAtEnd, deckOverflows, overflowExpected, maximumDeckScrollLeft, appliedDeckScrollLeft, minimumDeckWidth, expandedGeometry, collapsedGeometry, clientWidth: deck.clientWidth, scrollWidth: deck.scrollWidth, cardWidths: cardRects.map(rect => rect.width), cardHeights: cardRects.map(rect => rect.height) },
      fields,
      negativeTracking,
      statusLayoutShifts,
      rowOverlaps,
      hiddenRequiredFieldRejected: hiddenRejected,
      skippedGpu,
      card: { height: cardRect.height, clientHeight: card.clientHeight, scrollHeight: card.scrollHeight, contentBottom },
      interaction: { initialExpandedKey, activatedKey, activationValid, expectedFocusedKey, focusedKey, keyboardValid },
      documentScrollWidth: document.documentElement.scrollWidth,
      viewportWidth: innerWidth,
    };
  })())`;
  const denseHostDeckExpression = `JSON.stringify((() => {
    const deck = document.querySelector("#nodes");
    const cards = [...document.querySelectorAll("#nodes .node")];
    if (!deck || cards.length !== 22) return { pass: false, error: "dense Host fixture did not render", count: cards.length };
    const mobile = innerWidth <= 700;
    const expanded = cards.filter(card => card.classList.contains("is-expanded"));
    const collapsed = cards.filter(card => card.classList.contains("is-collapsed"));
    const style = getComputedStyle(deck);
    const deckRect = deck.getBoundingClientRect();
    const cardRects = cards.map(card => card.getBoundingClientRect());
    let expectedExpandedCount = Math.min(innerWidth <= 900 ? 1 : innerWidth < 1200 ? 2 : 4, cards.length);
    while (expectedExpandedCount > 1 && (deck.clientWidth - (cards.length - expectedExpandedCount) * 32) / expectedExpandedCount < 270) expectedExpandedCount -= 1;
    deck.scrollLeft = 0;
    const firstRect = cards[0].getBoundingClientRect();
    const firstAtStart = firstRect.left >= deckRect.left - 1 && firstRect.right <= deckRect.right + 1;
    const maximumScrollLeft = Math.max(0, deck.scrollWidth - deck.clientWidth);
    deck.scrollLeft = maximumScrollLeft;
    const lastRect = cards.at(-1).getBoundingClientRect();
    const lastAtEnd = lastRect.left >= deckRect.left - 1 && lastRect.right <= deckRect.right + 1;
    const appliedScrollLeft = deck.scrollLeft;
    deck.scrollLeft = 0;
    const desktopGeometry = !mobile && style.flexDirection === "row" && cardRects.every(rect => Math.abs(rect.top - cardRects[0].top) <= 0.5 && Math.abs(rect.bottom - cardRects[0].bottom) <= 0.5) && expanded.every(card => card.getBoundingClientRect().width >= 269) && collapsed.every(card => { const rect = card.getBoundingClientRect(); return rect.width >= 31 && rect.width <= 33; });
    const mobileGeometry = mobile && style.flexDirection === "column" && deck.scrollWidth <= deck.clientWidth + 1 && expanded.every(card => Math.abs(card.getBoundingClientRect().width - deck.clientWidth) <= 1) && collapsed.every(card => { const rect = card.getBoundingClientRect(); return Math.abs(rect.width - deck.clientWidth) <= 1 && Math.abs(rect.height - 52) <= 0.5; });
    const desktopReachability = !mobile && style.overflowX === "auto" && maximumScrollLeft > 1 && appliedScrollLeft > 1 && firstAtStart && lastAtEnd;
    const mobileReachability = mobile && style.overflowX === "visible" && maximumScrollLeft <= 1 && firstAtStart && lastAtEnd;
    return {
      pass: expanded.length === expectedExpandedCount && collapsed.length === cards.length - expectedExpandedCount && Number(deck.dataset.expandedCount) === expectedExpandedCount && (mobile ? mobileGeometry && mobileReachability : desktopGeometry && desktopReachability) && document.documentElement.scrollWidth <= innerWidth,
      mobile,
      count: cards.length,
      expandedCount: expanded.length,
      collapsedCount: collapsed.length,
      expectedExpandedCount,
      overflowX: style.overflowX,
      clientWidth: deck.clientWidth,
      scrollWidth: deck.scrollWidth,
      maximumScrollLeft,
      appliedScrollLeft,
      firstAtStart,
      lastAtEnd,
      documentScrollWidth: document.documentElement.scrollWidth,
      viewportWidth: innerWidth,
    };
  })())`;
  const bubbleNodes = [1, 2, 4, 9].flatMap((count) =>
    Array.from({ length: count }, (_, index) => ({
      address: `bubble-${count}-${index}`,
      participantState: "ACTIVE",
      isOnline: true,
      geo: {
        latitude: 10 + count * 3,
        longitude: count,
        city: `Bubble ${count}`,
        country: "Fixtureland",
        isp: "fixture",
        locationId: `fixture-bubble-${count}`,
        locationLabel: `Fixture bubble ${count}`,
      },
    })),
  );
  const stableNodes = [
    ["a", 48.14, 17.14],
    ["b", 48.13, 17.13],
    ["c", 48.11, 17.11],
  ].map(([name, latitude, longitude]) => ({
    address: `stable-${name}`,
    participantState: "ACTIVE",
    isOnline: true,
    geo: {
      latitude,
      longitude,
      city: "Stable",
      country: "Fixtureland",
      isp: "fixture",
    },
  }));
  const overlappingEuropeanMarkers = [
    {
      address: "singleton",
      participantState: "ACTIVE",
      isOnline: true,
      geo: {
        latitude: 48.12345,
        longitude: 17.98765,
        city: "Singleton",
        country: "Slovakia",
        isp: "fixture",
      },
    },
    ...Array.from({ length: 4 }, (_, index) => ({
      address: `prague-${index}`,
      participantState: "ACTIVE",
      isOnline: true,
      geo: {
        latitude: 50.08,
        longitude: 14.44,
        city: "Prague",
        country: "Czechia",
        isp: "fixture",
        locationId: "fixture-prague",
        locationLabel: "Prague, Czechia",
      },
    })),
  ];
  const controlOverlapMarker = [
    {
      address: "control-overlap",
      participantState: "ACTIVE",
      isOnline: true,
      geo: {
        latitude: 33.5502959,
        longitude: -82.5443787,
        city: "Control overlap",
        country: "Fixtureland",
        isp: "fixture",
      },
    },
  ];
  const waitForInitialMap = async () => {
    for (let attempt = 0; attempt < 120; attempt += 1) {
      const { result } = await call("Runtime.evaluate", {
        expression:
          'Boolean(document.querySelector("#updated")?.dateTime && document.querySelector(".validator-map-world")?.complete && Number(document.querySelector("#validator-map")?.dataset.markerCount)===7 && (document.querySelector("#validator-map")?.getBoundingClientRect().height||0)>0)',
        returnByValue: true,
      });
      if (result.value) return;
      await delay(100);
    }
    throw new Error("fixture did not restore the initial boundary map");
  };
  for (const [width, height] of [
    [1280, 720],
    [1399, 720],
    [1321, 720],
    [1320, 720],
    [1101, 720],
    [1100, 720],
    [701, 720],
    [700, 720],
    [521, 720],
    [1400, 900],
    [1440, 900],
    [1920, 1080],
    [390, 844],
    [375, 667],
    [360, 640],
    [320, 568],
    [844, 390],
  ]) {
    await call("Emulation.setDeviceMetricsOverride", {
      width,
      height,
      deviceScaleFactor: 1,
      mobile: width < 500 || (width === 844 && height === 390),
    });
    await call("Page.navigate", {
      url: `http://127.0.0.1:${server.address().port}/`,
    });
    for (let attempt = 0; attempt < 120; attempt += 1) {
      const { result } = await call("Runtime.evaluate", {
        expression:
          'Boolean(document.querySelector("#updated")?.dateTime && document.querySelector(".validator-map-world")?.complete && Number(document.querySelector("#validator-map")?.dataset.markerCount)===7 && (document.querySelector("#validator-map")?.getBoundingClientRect().height||0)>0)',
        returnByValue: true,
      });
      if (result.value) break;
      if (attempt === 119) {
        const { result: mapResult } = await call("Runtime.evaluate", {
          expression:
            'JSON.stringify({text:document.querySelector("#validator-map")?.textContent,leaflet:typeof window.L,updated:document.querySelector("#updated")?.dateTime||"",nodes:document.querySelectorAll("#nodes .node").length,validators:document.querySelector("#validator-map")?.dataset.validatorCount||"",markers:document.querySelector("#validator-map")?.dataset.markerCount||"",mapRect:(()=>{const rect=document.querySelector("#validator-map")?.getBoundingClientRect();return rect?{width:rect.width,height:rect.height}:null})(),world:Boolean(document.querySelector(".validator-map-world")?.complete&&document.querySelector(".validator-map-world")?.naturalWidth)})',
          returnByValue: true,
        });
        throw new Error(
          `fixture did not render at ${width}x${height}: ${mapResult.value}; diagnostics=${JSON.stringify(pageDiagnostics)}`,
        );
      }
      await delay(100);
    }
    // Leaflet applies the fractional initial zoom asynchronously after its
    // image overlay has loaded. Measure the settled map, not that transition.
    await delay(500);
    const { result } = await call("Runtime.evaluate", {
      expression: mapStateExpression,
      returnByValue: true,
    });
    const state = JSON.parse(result.value);
    let hostGeometry = null;
    let denseHostGeometry = null;
    if (width === 1280) {
      const { result: geoIpResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify({requests:window.__fixtureGeoIpRequests,dynamicMarker:[...document.querySelectorAll(".validator-marker")].some(marker=>marker.getAttribute("aria-label")?.includes("geo-fixture"))})',
        returnByValue: true,
      });
      const geoIp = JSON.parse(geoIpResult.value);
      if (geoIp.requests !== 2 || geoIp.dynamicMarker)
        throw new Error(
          `partial GeoIP evidence contract failed: ${JSON.stringify(geoIp)}`,
        );
      await call("Runtime.evaluate", {
        expression: "refresh()",
        awaitPromise: true,
      });
      const { result: retryResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify({requests:window.__fixtureGeoIpRequests,dynamicMarker:[...document.querySelectorAll(".validator-marker")].some(marker=>marker.getAttribute("aria-label")?.includes("geo-fixture"))})',
        returnByValue: true,
      });
      const retry = JSON.parse(retryResult.value);
      if (retry.requests !== 2 || retry.dynamicMarker)
        throw new Error(
          `GeoIP failure backoff contract failed: ${JSON.stringify(retry)}`,
        );
    }
    const expectedCoordinates = {
      "<Bratislava>": [48.15, 17.11],
      "North edge": [90, -180],
      Greenwich: [0, 0],
      "Kansas City": [39.0997285, -94.5785681],
      "South east": [-45, 90],
      Antimeridian: [45, 180],
      "South pole": [-90, -180],
      "Multiple locations": [90, -180],
    };
    const geographyValid = (candidate) =>
      candidate.markerNodes.every((marker) => {
        const city = marker.label.split(":")[0].split(",")[0];
        if (!/^(?:<Bratislava>|Greenwich|Kansas City)$/.test(city)) return true;
        const coordinate = expectedCoordinates[city];
        if (!coordinate || !candidate.worldRect) return false;
        const [latitude, longitude] = coordinate;
        const expectedLeft =
          candidate.worldRect.left +
          ((longitude + 180) / 360) * candidate.worldRect.width;
        const expectedTop =
          candidate.worldRect.top +
          ((90 - latitude) / 180) * candidate.worldRect.height;
        if (
          expectedLeft < candidate.mapRect.left ||
          expectedLeft > candidate.mapRect.right ||
          expectedTop < candidate.mapRect.top ||
          expectedTop > candidate.mapRect.bottom
        )
          return true;
        return (
          Math.abs(marker.left - expectedLeft) < 2 &&
          Math.abs(marker.top - expectedTop) < 2
        );
      });
    const hasCompactMarkers = state.markerNodes.every((marker) => {
      const city = marker.label.split(":")[0].split(",")[0];
      const coordinate = expectedCoordinates[city];
      if (!coordinate) return false;
      const [latitude, longitude] = coordinate;
      const expectedLeft =
        state.worldRect.left + ((longitude + 180) / 360) * state.worldRect.width;
      const expectedTop =
        state.worldRect.top + ((90 - latitude) / 180) * state.worldRect.height;
      if (
        expectedLeft < state.mapRect.left ||
        expectedLeft > state.mapRect.right ||
        expectedTop < state.mapRect.top ||
        expectedTop > state.mapRect.bottom
      )
        return true;
      return (
        marker.width >= 5 &&
        marker.height >= 5 &&
        marker.width <= 21 &&
        marker.height <= 21
      );
    });
    const hasInactiveState = state.markerNodes.some(
        (marker) =>
          marker.classes.includes("validator-marker--inactive") &&
          marker.fill === "#ef6c65",
      );
    const coreMarkersInside = state.markerNodes
      .filter((marker) => /^(?:<Bratislava>|Greenwich|Kansas City),/.test(marker.label))
      .every(
        (marker) =>
          marker.left >= state.mapRect.left &&
          marker.left <= state.mapRect.right &&
          marker.top >= state.mapRect.top &&
          marker.top <= state.mapRect.bottom,
      );
    if (
      !state.world ||
      Math.abs(state.worldRatio - 2) > 0.01 ||
      state.validators !== 9 ||
      state.markerCount !== 7 ||
      state.hitTargetCount !== state.markerCount ||
      !coreMarkersInside ||
      !geographyValid(state) ||
      !hasCompactMarkers ||
      !hasInactiveState ||
      state.scrollWidth > state.width
    )
      throw new Error(
        `map projection or responsive contract failed at ${width}x${height}: ${JSON.stringify(state)}`,
      );
    const { result: landResult } = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify((()=>{const image=document.querySelector(".validator-map-world"),canvas=document.createElement("canvas"),points={"gdc-node0 region":[39.0997,-94.5786],"gdc-node1 region":[60.1695,24.9354],"gdc-node2 region":[52.3785,4.9],"gdc-node3 region":[51.5074,-0.1278],"gdc-node4 region":[45.4416,-122.749],Lisbon:[38.72,-9.14],Reykjavik:[64.15,-21.94],Tokyo:[35.68,139.69],Sydney:[-33.87,151.21]};if(!image?.naturalWidth)return{error:"world image unavailable"};canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;const context=canvas.getContext("2d");context.drawImage(image,0,0);const onLand=([lat,lon])=>{const x=Math.round((lon+180)/360*canvas.width),y=Math.round((90-lat)/180*canvas.height);for(let dy=-3;dy<=3;dy+=1)for(let dx=-3;dx<=3;dx+=1)if(context.getImageData(x+dx,y+dy,1,1).data[3]>0)return true;return false};return Object.fromEntries(Object.entries(points).map(([name,point])=>[name,onLand(point)]))})())',
      returnByValue: true,
    });
    const land = JSON.parse(landResult.value);
    if (Object.values(land).some((value) => value !== true))
      throw new Error(`known land locations are not visible: ${JSON.stringify(land)}`);
    if (width === 1280) {
      await call("Emulation.setDeviceMetricsOverride", {
        width: 390,
        height: 844,
        deviceScaleFactor: 1,
        mobile: true,
      });
      await delay(200);
      const { result: resizeResult } = await call("Runtime.evaluate", {
        expression: mapStateExpression,
        returnByValue: true,
      });
      const resized = JSON.parse(resizeResult.value);
      if (
        Math.abs(resized.worldRatio - 2) > 0.01 ||
        !resized.markerNodes
          .filter((marker) => /^(?:<Bratislava>|Greenwich|Kansas City),/.test(marker.label))
          .every(
            (marker) =>
              marker.left >= resized.mapRect.left &&
              marker.left <= resized.mapRect.right &&
              marker.top >= resized.mapRect.top &&
              marker.top <= resized.mapRect.bottom,
          ) ||
        !geographyValid(resized)
      )
        throw new Error(
          `resize without reload contract failed: ${JSON.stringify(resized)}`,
        );
      const { result: mobileHostResizeResult } = await call(
        "Runtime.evaluate",
        {
          expression:
            'JSON.stringify((()=>{const deck=document.querySelector("#nodes"),cards=[...document.querySelectorAll("#nodes .node")];return{layout:deck?.dataset.layout,flexDirection:getComputedStyle(deck).flexDirection,expanded:cards.filter(card=>card.classList.contains("is-expanded")).length,collapsed:cards.filter(card=>card.classList.contains("is-collapsed")).length}})())',
          returnByValue: true,
        },
      );
      const mobileHostResize = JSON.parse(mobileHostResizeResult.value);
      if (
        mobileHostResize.layout !== "mobile" ||
        mobileHostResize.flexDirection !== "column" ||
        mobileHostResize.expanded !== 1 ||
        mobileHostResize.collapsed !== 10
      )
        throw new Error(
          `Host accordion mobile resize failed: ${JSON.stringify(mobileHostResize)}`,
        );
      await call("Emulation.setDeviceMetricsOverride", {
        width,
        height,
        deviceScaleFactor: 1,
        mobile: false,
      });
      await delay(200);
      const { result: desktopHostResizeResult } = await call(
        "Runtime.evaluate",
        {
          expression:
            'JSON.stringify((()=>{const deck=document.querySelector("#nodes"),cards=[...document.querySelectorAll("#nodes .node")];return{layout:deck?.dataset.layout,flexDirection:getComputedStyle(deck).flexDirection,expanded:cards.filter(card=>card.classList.contains("is-expanded")).length,collapsed:cards.filter(card=>card.classList.contains("is-collapsed")).length}})())',
          returnByValue: true,
        },
      );
      const desktopHostResize = JSON.parse(desktopHostResizeResult.value);
      if (
        desktopHostResize.layout !== "rail" ||
        desktopHostResize.flexDirection !== "row" ||
        desktopHostResize.expanded !== 3 ||
        desktopHostResize.collapsed !== 8
      )
        throw new Error(
          `Host accordion desktop resize failed: ${JSON.stringify(desktopHostResize)}`,
        );
    }
    if (width === 390) {
      const { result: controlBaseResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify((()=>{const button=document.querySelector(".leaflet-control-zoom-in"),control=button?.getBoundingClientRect(),world=document.querySelector(".validator-map-world")?.getBoundingClientRect();return{control:{disabled:button?.classList.contains("leaflet-disabled"),x:control?.left+control?.width/2,y:control?.top+control?.height/2},world:{left:world?.left,top:world?.top,width:world?.width,height:world?.height}}})())',
        returnByValue: true,
      });
      const controlBase = JSON.parse(controlBaseResult.value);
      if (controlBase.control.disabled || !controlBase.world.width)
        throw new Error(
          `zoom-in control is unavailable: ${JSON.stringify(controlBase)}`,
        );
      const controlLatitude =
        90 -
        ((controlBase.control.y - controlBase.world.top) /
          controlBase.world.height) *
          180;
      const controlLongitude =
        ((controlBase.control.x - controlBase.world.left) /
          controlBase.world.width) *
          360 -
        180;
      await call("Runtime.evaluate", {
        expression: `validatorMapController.update(${JSON.stringify([
          {
            ...controlOverlapMarker[0],
            geo: {
              ...controlOverlapMarker[0].geo,
              latitude: controlLatitude,
              longitude: controlLongitude,
            },
          },
        ])})`,
      });
      await delay(80);
      const { result: controlResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify((()=>{const button=document.querySelector(".leaflet-control-zoom-in"),control=button?.getBoundingClientRect(),marker=[...document.querySelectorAll(".validator-marker")].find(item=>item.getAttribute("aria-label")?.startsWith("Control overlap,"))?.getBoundingClientRect(),world=document.querySelector(".validator-map-world")?.getBoundingClientRect();return{control:{disabled:button?.classList.contains("leaflet-disabled"),x:control?.left+control?.width/2,y:control?.top+control?.height/2},marker:{x:marker?.left+marker?.width/2,y:marker?.top+marker?.height/2},worldWidth:world?.width}})())',
        returnByValue: true,
      });
      const control = JSON.parse(controlResult.value);
      const controlDistance = Math.hypot(
        control.control.x - control.marker.x,
        control.control.y - control.marker.y,
      );
      if (control.control.disabled || controlDistance > 14)
        throw new Error(
          `fixture does not place the marker under an active control: ${JSON.stringify({ control, controlDistance })}`,
        );
      await call("Runtime.evaluate", {
        expression:
          'document.querySelector(".leaflet-control-zoom-in")?.dispatchEvent(new MouseEvent("mousemove",{bubbles:true}))',
      });
      await delay(40);
      const { result: controlHoverResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify(Boolean(document.querySelector(".leaflet-tooltip")))',
        returnByValue: true,
      });
      if (JSON.parse(controlHoverResult.value))
        throw new Error("map-control hover opened a validator tooltip");
      await call("Runtime.evaluate", {
        expression:
          'document.querySelector(".leaflet-control-zoom-in")?.dispatchEvent(new MouseEvent("click",{bubbles:true,cancelable:true,view:window,detail:1}))',
      });
      await delay(80);
      const { result: controlClickResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify((()=>{const world=document.querySelector(".validator-map-world")?.getBoundingClientRect();return{popup:Boolean(document.querySelector(".leaflet-popup")),tooltip:Boolean(document.querySelector(".leaflet-tooltip")),worldWidth:world?.width}})())',
        returnByValue: true,
      });
      const controlClick = JSON.parse(controlClickResult.value);
      if (controlClick.popup || controlClick.tooltip)
        throw new Error(
          `map-control dispatch contract failed: ${JSON.stringify({ control, controlClick })}`,
        );
      await call("Runtime.evaluate", {
        expression:
          'document.querySelector(".leaflet-control-zoom-out")?.dispatchEvent(new MouseEvent("click",{bubbles:true,cancelable:true,view:window,detail:1}))',
      });
      await delay(80);
      await call("Page.navigate", {
        url: `http://127.0.0.1:${server.address().port}/`,
      });
      for (let attempt = 0; attempt < 120; attempt += 1) {
        const { result: rerenderResult } = await call("Runtime.evaluate", {
          expression:
            'Boolean(document.querySelector("#updated")?.dateTime && document.querySelector(".validator-map-world")?.complete && Number(document.querySelector("#validator-map")?.dataset.markerCount)===7)',
          returnByValue: true,
        });
        if (rerenderResult.value) break;
        if (attempt === 119)
          throw new Error("control fixture did not restore the base map");
        await delay(100);
      }
      await delay(500);
    }
    await call("Runtime.evaluate", {
      expression: `validatorMapController.update(${JSON.stringify(bubbleNodes)})`,
    });
    await delay(80);
    const { result: bubbleResult } = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify([...document.querySelectorAll(".validator-marker")].map(marker=>{const label=marker.getAttribute("aria-label")||"",radius=Number(/a([0-9.]+),/.exec(marker.getAttribute("d")||"")?.[1]);return{label,radius}}))',
      returnByValue: true,
    });
    const bubbles = JSON.parse(bubbleResult.value);
    const bubbleRadius = (count) =>
      bubbles.find((bubble) =>
        bubble.label.startsWith(`Fixture bubble ${count}:`),
      )?.radius;
    const [r1, r2, r4, r9] = [1, 2, 4, 9].map(bubbleRadius);
    const areaRatio = (left, right) => left ** 2 / right ** 2;
    if (
      ![r1, r2, r4, r9].every(Number.isFinite) ||
      !(r1 < r2 && r2 < r4 && r4 < r9) ||
      r1 > 4 ||
      r9 > 9 ||
      areaRatio(r2, r1) < 1.5 ||
      areaRatio(r2, r1) > 2.5 ||
      areaRatio(r4, r1) < 2.5 ||
      areaRatio(r4, r1) > 5
    )
      throw new Error(
        `bubble size contract failed: ${JSON.stringify(bubbles)}`,
      );
    await call("Runtime.evaluate", {
      expression: `validatorMapController.update(${JSON.stringify(stableNodes)})`,
    });
    await delay(80);
    const stablePosition = async () => {
      const { result } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify((()=>{const marker=[...document.querySelectorAll(".validator-marker")].find(item=>item.getAttribute("aria-label")?.startsWith("Stable,")),rect=marker?.getBoundingClientRect(),world=document.querySelector(".validator-map-world")?.getBoundingClientRect();return{left:(rect?.left+rect?.width/2-world?.left)/world?.width,top:(rect?.top+rect?.height/2-world?.top)/world?.height}})())',
        returnByValue: true,
      });
      return JSON.parse(result.value);
    };
    const stableInitial = await stablePosition();
    await call("Runtime.evaluate", {
      expression: `validatorMapController.update(${JSON.stringify([...stableNodes].reverse())})`,
    });
    await delay(80);
    const stableReordered = await stablePosition();
    await call("Runtime.evaluate", {
      expression: `validatorMapController.update(${JSON.stringify(stableNodes.slice(1))})`,
    });
    await delay(80);
    const stableWithoutFirst = await stablePosition();
    if (
      ![stableInitial, stableReordered, stableWithoutFirst].every(
        (position) =>
          Number.isFinite(position.left) && Number.isFinite(position.top),
      ) ||
      Math.abs(stableInitial.left - stableReordered.left) > 0.1 ||
      Math.abs(stableInitial.top - stableReordered.top) > 0.1 ||
      Math.abs(stableInitial.left - stableWithoutFirst.left) > 8 ||
      Math.abs(stableInitial.top - stableWithoutFirst.top) > 8
    )
      throw new Error(
        `stable group position contract failed: ${JSON.stringify({ stableInitial, stableReordered, stableWithoutFirst })}`,
      );
    await call("Emulation.setDeviceMetricsOverride", {
      width: 1280,
      height: 5000,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await call("Emulation.setVisibleSize", { width: 1280, height: 5000 });
    await call("Runtime.evaluate", {
      expression: `validatorMapController.update(${JSON.stringify(overlappingEuropeanMarkers)})`,
    });
    await delay(80);
    await call("Runtime.evaluate", {
      expression:
        'document.querySelector("#validator-map")?.scrollIntoView({behavior:"instant",block:"center"})',
    });
    await delay(80);
    const { result: overlappingResult } = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify({markers:[...document.querySelectorAll(".validator-marker")].map(marker=>{const r=marker.getBoundingClientRect();return{label:marker.getAttribute("aria-label"),x:r.left+r.width/2,y:r.top+r.height/2}}),hits:[...document.querySelectorAll(".validator-marker-hit")].map(hit=>{const r=hit.getBoundingClientRect();return{className:hit.getAttribute("class"),x:r.left+r.width/2,y:r.top+r.height/2,width:r.width,height:r.height,pointerEvents:getComputedStyle(hit).pointerEvents,opacity:getComputedStyle(hit).opacity,parentPointerEvents:getComputedStyle(hit.parentElement).pointerEvents}})})',
      returnByValue: true,
    });
    const overlappingState = JSON.parse(overlappingResult.value);
    const singleton = overlappingState.markers.find((marker) =>
      marker.label?.startsWith("Singleton,"),
    );
    const prague = overlappingState.markers.find((marker) =>
      marker.label?.startsWith("Prague,"),
    );
    const hitFor = (marker) =>
      overlappingState.hits.find(
        (hit) => Math.hypot(hit.x - marker.x, hit.y - marker.y) < 0.1,
      );
    const singletonHit = singleton && hitFor(singleton);
    const pragueHit = prague && hitFor(prague);
    const hitDistance =
      singleton && prague
        ? Math.hypot(singleton.x - prague.x, singleton.y - prague.y)
        : NaN;
    const combinedHitRadius =
      singletonHit && pragueHit
        ? singletonHit.width / 2 + pragueHit.width / 2
        : NaN;
    if (!(hitDistance < combinedHitRadius))
      throw new Error(
        `fixture no longer exercises overlapping hit areas: ${JSON.stringify({ overlappingState, hitDistance, combinedHitRadius })}`,
      );
    const waitForSettledOverlappingMarker = async (expected) => {
      let previous = null;
      let stableSamples = 0;
      let observed = null;
      for (let attempt = 0; attempt < 40; attempt += 1) {
        const { result: markerResult } = await call(
          "Runtime.evaluate",
          {
            expression:
              'JSON.stringify((()=>({animating:Boolean(document.querySelector(".leaflet-pan-anim,.leaflet-zoom-anim")),markers:[...document.querySelectorAll(".validator-marker")].map(marker=>{const rect=marker.getBoundingClientRect();return{label:marker.getAttribute("aria-label")||"",x:rect.left+rect.width/2,y:rect.top+rect.height/2}})}))())',
            returnByValue: true,
          },
        );
        observed = JSON.parse(markerResult.value);
        const position = observed.markers.find((marker) =>
          marker.label.startsWith(expected),
        );
        if (
          position &&
          previous &&
          !observed.animating &&
          Math.hypot(position.x - previous.x, position.y - previous.y) <= 0.1
        )
          stableSamples += 1;
        else stableSamples = 0;
        if (stableSamples >= 3) return position;
        previous = position;
        await delay(50);
      }
      throw new Error(
        `overlapping marker did not settle ${JSON.stringify({ expected, observed })}`,
      );
    };
    const assertOverlappingPointers = async () => {
      for (const expected of ["Singleton,", "Prague,"]) {
        await call("Runtime.evaluate", {
          expression:
            'document.querySelector(".leaflet-popup-close-button")?.click()',
        });
        for (let attempt = 0; attempt < 20; attempt += 1) {
          const { result: closedResult } = await call("Runtime.evaluate", {
            expression: '!document.querySelector(".leaflet-popup")',
            returnByValue: true,
          });
          if (closedResult.value) break;
          if (attempt === 19)
            throw new Error("previous marker popup did not close");
          await delay(20);
        }
        // Leaflet can continue popup auto-pan after removing the popup DOM.
        // Bind the pointer coordinates to three stable geometry samples so a
        // slower runner cannot dispatch at a stale marker position.
        const marker = await waitForSettledOverlappingMarker(expected);
        await call("Input.dispatchMouseEvent", {
          type: "mouseMoved",
          x: marker.x,
          y: marker.y,
        });
        await call("Input.dispatchMouseEvent", {
          type: "mousePressed",
          x: marker.x,
          y: marker.y,
          button: "left",
          clickCount: 1,
        });
        await call("Input.dispatchMouseEvent", {
          type: "mouseReleased",
          x: marker.x,
          y: marker.y,
          button: "left",
          clickCount: 1,
        });
        await delay(80);
        const { result: pointerResult } = await call("Runtime.evaluate", {
          expression: `JSON.stringify({popup:document.querySelector(".leaflet-popup-content")?.textContent||"",tooltip:document.querySelector(".leaflet-tooltip")?.textContent||"",atPoint:document.elementFromPoint(${marker.x},${marker.y})?.getAttribute("class")||"",viewport:{width:innerWidth,height:innerHeight,scrollY}})`,
          returnByValue: true,
        });
        const pointer = JSON.parse(pointerResult.value);
        if (
          !pointer.popup.startsWith(expected) ||
          !pointer.tooltip.startsWith(expected)
        )
          throw new Error(
            `overlapping hit dispatch failed ${JSON.stringify({ expected, marker, pointer, overlappingState })}`,
          );
      }
    };
    await assertOverlappingPointers();
    await call("Runtime.evaluate", {
      expression: `validatorMapController.update(${JSON.stringify([...overlappingEuropeanMarkers].reverse())})`,
    });
    await delay(80);
    await assertOverlappingPointers();
    await call("Emulation.setDeviceMetricsOverride", {
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true,
    });
    await call("Emulation.setVisibleSize", { width: 390, height: 844 });
    await delay(160);
    const { result: mobileResizeResult } = await call("Runtime.evaluate", {
      expression: mapStateExpression,
      returnByValue: true,
    });
    const mobileResize = JSON.parse(mobileResizeResult.value);
    if (
      Math.abs(mobileResize.worldRatio - 2) > 0.01 ||
      !mobileResize.centersInside
    )
      throw new Error(
        `overlapping mobile resize geometry failed: ${JSON.stringify(mobileResize)}`,
      );
    await call("Emulation.setDeviceMetricsOverride", {
      width,
      height,
      deviceScaleFactor: 1,
      mobile: width < 500 || (width === 844 && height === 390),
    });
    await call("Emulation.setVisibleSize", { width, height });
    await delay(80);
    // A dynamic GeoIP point in open ocean must be omitted rather than moved
    // across a continent. This observes the same local SVG alpha mask that
    // the production renderer uses for its 80 km display-only bound.
    await call("Runtime.evaluate", {
      expression:
        'validatorMapController.update([{address:"fixture-unresolved",participantState:"ACTIVE",isOnline:false,geo:{latitude:0,longitude:0,rawLatitude:0,rawLongitude:0,city:"Open ocean",country:"Fixtureland",isp:"fixture",source:"ip-geolocation",observedAt:"2026-09-01T00:00:00Z",accuracy:"city"}}])',
    });
    await delay(80);
    const { result: unresolvedResult } = await call("Runtime.evaluate", {
      expression:
        'String(document.querySelectorAll(".validator-marker").length)',
      returnByValue: true,
    });
    if (Number(unresolvedResult.value) !== 0)
      throw new Error("unresolved GeoIP location was rendered as a precise marker");
    await call("Runtime.evaluate", {
      expression:
        'validatorMapController.update([{address:"fixture-validating",participantState:"ACTIVE",isOnline:true,geo:{latitude:48.15,longitude:17.11,city:"Bratislava",country:"Slovakia",isp:"fixture"}},{address:"fixture-active",participantState:"ACTIVE",isOnline:false,geo:{latitude:48.2,longitude:16.37,city:"Vienna",country:"Austria",isp:"fixture",source:"ip-geolocation",resolvedIp:"203.0.113.10",observedAt:"2026-08-31T12:00:00Z",accuracy:"city"}},{address:"fixture-inactive",participantState:"INACTIVE",isOnline:false,geo:{latitude:40.71,longitude:-74,city:"New York",country:"United States",isp:"fixture"}},{address:"fixture-unknown",participantKnown:false,isOnline:false,geo:{latitude:41.9,longitude:12.5,city:"Rome",country:"Italy",isp:"fixture"}},{address:"fixture-group-validating",participantState:"ACTIVE",isOnline:true,geo:{latitude:50.08,longitude:14.44,city:"Prague",country:"Czechia",isp:"fixture"}},{address:"fixture-group-active",participantState:"ACTIVE",isOnline:false,geo:{latitude:50.08,longitude:14.44,city:"Prague",country:"Czechia",isp:"fixture"}},{address:"fixture-group-inactive",participantState:"INACTIVE",isOnline:false,geo:{latitude:50.08,longitude:14.44,city:"Prague",country:"Czechia",isp:"fixture"}}])',
    });
    await delay(80);
    const { result: semanticsResult } = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify([...document.querySelectorAll(".validator-marker")].map(marker=>marker.getAttribute("aria-label")))',
      returnByValue: true,
    });
    const semantics = JSON.parse(semanticsResult.value);
    for (const [city, stateLabel] of [
      ["Bratislava", "Validating"],
      ["Vienna", "Active – not validating"],
      ["New York", "Inactive"],
      ["Rome", "Unknown – status unavailable"],
    ]) {
      if (
        !semantics.some(
          (label) => label.startsWith(`${city},`) && label.includes(stateLabel),
        )
      )
        throw new Error(
          `marker state text contract failed for ${city}: ${JSON.stringify(semantics)}`,
        );
    }
    const legend = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify([...document.querySelectorAll(".validator-map-legend li")].map(item=>item.textContent))',
      returnByValue: true,
    });
    const legendLabels = JSON.parse(legend.result.value);
    if (
      !legendLabels.includes("Validating") ||
      !legendLabels.includes("Active – not validating") ||
      !legendLabels.includes("Inactive") ||
      !legendLabels.includes("Unknown – status unavailable") ||
      !semantics.some(
        (label) =>
          label.startsWith("Prague,") &&
          label.includes(
            "1 validating · 1 active – not validating · 1 inactive",
          ),
      )
    )
      throw new Error(
        `marker legend/distribution contract failed: ${JSON.stringify({ legendLabels, semantics })}`,
      );
    await call("Runtime.evaluate", {
      expression:
        'validatorMapController.update([{address:"duplicate-west",participantState:"ACTIVE",isOnline:false,geo:{latitude:12.1,longitude:12.1,city:"Springfield",country:"Fixtureland",isp:"fixture"}},{address:"duplicate-east",participantState:"ACTIVE",isOnline:false,geo:{latitude:52.1,longitude:52.1,city:"Springfield",country:"Fixtureland",isp:"fixture"}}])',
    });
    await delay(80);
    const { result: duplicateLocationsResult } = await call("Runtime.evaluate", {
      expression:
        'String([...document.querySelectorAll(".validator-marker")].filter(marker=>marker.getAttribute("aria-label")?.startsWith("Springfield,")).length)',
      returnByValue: true,
    });
    if (Number(duplicateLocationsResult.value) !== 2)
      throw new Error("distant dynamic locations with identical labels collided");
    await call("Runtime.evaluate", {
      expression:
        'validatorMapController.update([{address:"fixture-active",participantState:"ACTIVE",isOnline:false,geo:{latitude:48.2,longitude:16.37,city:"Vienna",country:"Austria",isp:"fixture",source:"ip-geolocation",resolvedIp:"203.0.113.10",observedAt:"2026-08-31T12:00:00Z",accuracy:"city"}}])',
    });
    await delay(80);
    const { result: focusResult } = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify((()=>{const marker=[...document.querySelectorAll(".validator-marker")].find(item=>item.getAttribute("aria-label")?.startsWith("Vienna,"));marker?.focus();return{found:Boolean(marker),tabindex:marker?.getAttribute("tabindex"),focused:document.activeElement?.getAttribute("aria-label")||""}})())',
      returnByValue: true,
    });
    const focus = JSON.parse(focusResult.value);
    if (!focus.found || !focus.focused.startsWith("Vienna,"))
      throw new Error(`marker focus contract failed: ${JSON.stringify(focus)}`);
    await call("Runtime.evaluate", {
      expression:
        'document.activeElement?.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",bubbles:true,cancelable:true}))',
    });
    await delay(80);
    const { result: popupResult } = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify((()=>{const popups=[...document.querySelectorAll(".leaflet-popup-content")];const popup=popups.at(-1);return{open:Boolean(popup),text:popup?.textContent||"",all:popups.map(item=>item.textContent||""),unsafe:Boolean(popup?.querySelector("bratislava")),focused:document.activeElement?.getAttribute("aria-label")||""}})())',
      returnByValue: true,
    });
    const popup = JSON.parse(popupResult.value);
    if (
      !popup.open ||
      popup.all.length !== 1 ||
      !popup.text.includes("Active – not validating") ||
      !popup.text.includes("IP geolocation snapshot") ||
      !popup.text.includes("203.0.113.10") ||
      !popup.text.includes("observed 2026-08-31T12:00:00Z") ||
      popup.unsafe ||
      !popup.focused.startsWith("Vienna,")
    )
      throw new Error(
        `keyboard popup escaping contract failed: ${JSON.stringify(popup)}`,
      );
    await call("Runtime.evaluate", {
      expression:
        'validatorMapController.update([{address:"fixture-validating",participantState:"ACTIVE",isOnline:true,geo:{latitude:48.15,longitude:17.11,city:"Bratislava",country:"Slovakia",isp:"fixture"}},{address:"fixture-active",participantState:"ACTIVE",isOnline:false,geo:{latitude:48.2,longitude:16.37,city:"Vienna",country:"Austria",isp:"fixture"}},{address:"fixture-inactive",participantState:"INACTIVE",isOnline:false,geo:{latitude:40.71,longitude:-74,city:"New York",country:"United States",isp:"fixture"}}])',
    });
    await delay(80);
    const { result: retainedResult } = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify({popup:Boolean(document.querySelector(".leaflet-popup-content")),focused:document.activeElement?.getAttribute("aria-label")||""})',
      returnByValue: true,
    });
    const retained = JSON.parse(retainedResult.value);
    if (!retained.popup || !retained.focused.startsWith("Vienna,"))
      throw new Error(
        `popup/focus refresh contract failed: ${JSON.stringify(retained)}`,
      );
    await call("Runtime.evaluate", {
      expression:
        'window.__escapeObserved=false;document.addEventListener("keydown",event=>{if(event.key==="Escape")window.__escapeObserved=true},{once:true});',
    });
    await call("Runtime.evaluate", {
      expression:
        'document.querySelector("#validator-map")?.scrollIntoView({behavior:"instant",block:"center"})',
    });
    await delay(100);
    await call("Input.dispatchKeyEvent", {
      type: "keyDown",
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27,
    });
    await call("Input.dispatchKeyEvent", {
      type: "keyUp",
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27,
    });
    await delay(100);
    const { result: escapeResult } = await call("Runtime.evaluate", {
      expression:
        'JSON.stringify((()=>{const popup=document.querySelector(".leaflet-popup");return{popup:Boolean(popup),focused:document.activeElement?.getAttribute("aria-label")||"",observed:window.__escapeObserved}})())',
      returnByValue: true,
    });
    const escape = JSON.parse(escapeResult.value);
    if (
      escape.popup ||
      !escape.focused.startsWith("Vienna,") ||
      escape.observed
    )
      throw new Error(`Escape contract failed: ${JSON.stringify(escape)}`);
    if (width === 1280) {
      const dragStart = await dragMapRight();
      try {
        await waitForMapRestoration("Escape popup restoration");
      } catch (error) {
        throw new Error(
          `${error.message} drag=${JSON.stringify(dragStart)}`,
        );
      }
    }
    await call("Runtime.evaluate", {
      expression:
        'window.__escapeObserved=false;document.addEventListener("keydown",event=>{if(event.key==="Escape")window.__escapeObserved=true},{once:true});',
    });
    await call("Input.dispatchKeyEvent", {
      type: "keyDown",
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27,
    });
    await call("Input.dispatchKeyEvent", {
      type: "keyUp",
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27,
    });
    const { result: idleEscapeResult } = await call("Runtime.evaluate", {
      expression: "JSON.stringify(window.__escapeObserved)",
      returnByValue: true,
    });
    if (!JSON.parse(idleEscapeResult.value))
      throw new Error("Escape without a popup was consumed by the map");
    if (
      width < 500 ||
      (width === 844 && height === 390) ||
      (width === 1280 && height === 720)
    ) {
      if (width === 844 && height === 390) {
        await call("Page.navigate", {
          url: `http://127.0.0.1:${server.address().port}/`,
        });
        await waitForInitialMap();
        await delay(500);
      }
      await call("Runtime.evaluate", {
        expression:
          'document.querySelector("#validator-map-fullscreen")?.click()',
      });
      await delay(80);
      const { result: fullResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify((()=>{const map=document.querySelector("#validator-map"),r=map?.getBoundingClientRect(),world=document.querySelector("#validator-map .validator-map-world"),wr=world?.getBoundingClientRect();const markers=[...(map?.querySelectorAll(".validator-marker")||[])],hits=[...(map?.querySelectorAll(".validator-marker-hit")||[])],inside=(element,rect)=>{const er=element.getBoundingClientRect();return er.width>0&&er.height>0&&er.left>=rect.left-1&&er.right<=rect.right+1&&er.top>=rect.top-1&&er.bottom<=rect.bottom+1};return{left:r?.left,top:r?.top,right:r?.right,bottom:r?.bottom,worldFits:Boolean(wr&&r&&wr.left>=r.left-1&&wr.right<=r.right+1&&wr.top>=r.top-1&&wr.bottom<=r.bottom+1),markersVisible:Boolean(r&&markers.every(marker=>inside(marker,r))),hitsVisible:Boolean(r&&hits.every(hit=>inside(hit,r))),pressed:document.querySelector("#validator-map-fullscreen")?.getAttribute("aria-pressed"),locked:document.body.classList.contains("validator-map-fullscreen-open")}})())',
        returnByValue: true,
      });
      const full = JSON.parse(fullResult.value);
      if (
        full.pressed !== "true" ||
        !full.locked ||
        !full.worldFits ||
        !full.markersVisible ||
        !full.hitsVisible ||
        full.left > 1 ||
        full.top > 1 ||
        full.right < width - 1 ||
        full.bottom < height - 1
      )
        throw new Error(`fullscreen coverage failed: ${JSON.stringify(full)}`);
      if (width === 844 && height === 390) {
        const { result: groupedRequestResult } = await call("Runtime.evaluate", {
          expression:
            'JSON.stringify((()=>{const marker=[...document.querySelectorAll(".validator-marker")].find(item=>item.getAttribute("aria-label")?.startsWith("Multiple locations"));if(!marker)return{found:false};marker.focus();marker.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",bubbles:true,cancelable:true}));return{found:true}})())',
          returnByValue: true,
        });
        const groupedRequest = JSON.parse(groupedRequestResult.value);
        if (!groupedRequest.found)
          throw new Error("fullscreen grouped boundary marker is unavailable");
        await delay(180);
        const { result: groupedPopupResult } = await call("Runtime.evaluate", {
          expression:
            'JSON.stringify((()=>{const map=document.querySelector("#validator-map"),mr=map?.getBoundingClientRect(),popup=document.querySelector(".leaflet-popup"),pr=popup?.getBoundingClientRect(),content=popup?.querySelector(".leaflet-popup-content"),inside=(value,bounds)=>Boolean(value&&bounds&&value.left>=bounds.left-1&&value.right<=bounds.right+1&&value.top>=bounds.top-1&&value.bottom<=bounds.bottom+1);return{open:Boolean(popup),visible:Boolean(inside(pr,mr)&&inside(content?.getBoundingClientRect(),mr)&&content.scrollHeight<=content.clientHeight+1),text:content?.textContent||"",popupTop:pr?.top,mapTop:mr?.top}})())',
          returnByValue: true,
        });
        const groupedPopup = JSON.parse(groupedPopupResult.value);
        if (
          !groupedPopup.open ||
          !groupedPopup.visible ||
          !groupedPopup.text.includes("Multiple locations")
        )
          throw new Error(
            `fullscreen grouped popup containment failed: ${JSON.stringify(groupedPopup)}`,
          );
        await call("Runtime.evaluate", {
          expression:
            'document.querySelector(".leaflet-popup-close-button")?.click()',
        });
        await delay(160);
        await call("Page.navigate", {
          url: `http://127.0.0.1:${server.address().port}/`,
        });
        await waitForInitialMap();
        await delay(500);
        await call("Runtime.evaluate", {
          expression:
            'document.querySelector("#validator-map")?.scrollIntoView({behavior:"instant",block:"center"})',
        });
        await delay(80);
        const { result: edgeRequestResult } = await call("Runtime.evaluate", {
          expression:
            'JSON.stringify((()=>{const marker=[...document.querySelectorAll(".validator-marker")].find(item=>item.getAttribute("aria-label")?.startsWith("Multiple locations"));if(!marker)return{found:false};marker.focus();marker.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",bubbles:true,cancelable:true}));return{found:true}})())',
          returnByValue: true,
        });
        const edgeRequest = JSON.parse(edgeRequestResult.value);
        if (!edgeRequest.found)
          throw new Error("popup replacement edge marker is unavailable");
        await delay(180);
        const { result: replacementRequestResult } = await call("Runtime.evaluate", {
          expression:
            'JSON.stringify((()=>{const marker=[...document.querySelectorAll(".validator-marker")].find(item=>item.getAttribute("aria-label")?.startsWith("<Bratislava>,"));if(!marker)return{found:false};marker.focus();marker.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",bubbles:true,cancelable:true}));return{found:true}})())',
          returnByValue: true,
        });
        const replacementRequest = JSON.parse(replacementRequestResult.value);
        if (!replacementRequest.found)
          throw new Error("popup replacement marker is unavailable");
        await delay(180);
        await call("Runtime.evaluate", {
          expression:
            'document.querySelector(".leaflet-popup-close-button")?.click()',
        });
        await waitForMapRestoration("popup replacement close restoration");
        const dragStart = await dragMapRight();
        try {
          await waitForMapRestoration("popup replacement restoration");
        } catch (error) {
          throw new Error(
            `${error.message} drag=${JSON.stringify(dragStart)}`,
          );
        }
        await call("Runtime.evaluate", {
          expression:
            'document.querySelector("#validator-map-fullscreen")?.click()',
        });
        await delay(80);
      }
      const { result: popupRequestResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify((()=>{const marker=[...document.querySelectorAll(".validator-marker")].find(item=>{const label=item.getAttribute("aria-label")||"";return label.startsWith("Bratislava,")||label.startsWith("<Bratislava>,")});if(!marker)return{found:false};marker.focus();marker.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",bubbles:true,cancelable:true}));return{found:true}})())',
        returnByValue: true,
      });
      const popupRequest = JSON.parse(popupRequestResult.value);
      if (!popupRequest.found)
        throw new Error("fullscreen popup fixture marker is unavailable");
      await delay(160);
      const { result: popupGeometryResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify((()=>{const map=document.querySelector("#validator-map"),mr=map?.getBoundingClientRect(),popup=document.querySelector(".leaflet-popup"),pr=popup?.getBoundingClientRect(),content=popup?.querySelector(".leaflet-popup-content"),cr=content?.getBoundingClientRect(),rect=(value)=>value?{left:value.left,top:value.top,right:value.right,bottom:value.bottom,width:value.width,height:value.height}:null;const inside=(value,bounds)=>Boolean(value&&bounds&&value.left>=bounds.left-1&&value.right<=bounds.right+1&&value.top>=bounds.top-1&&value.bottom<=bounds.bottom+1);return{open:Boolean(popup),visible:Boolean(inside(pr,mr)&&inside(cr,mr)&&content.scrollHeight<=content.clientHeight+1),map:rect(mr),popup:rect(pr),content:rect(cr),contentScrollHeight:content?.scrollHeight||0,contentClientHeight:content?.clientHeight||0,text:content?.textContent||""}})())',
        returnByValue: true,
      });
      const popupGeometry = JSON.parse(popupGeometryResult.value);
      if (
        !popupGeometry.open ||
        !popupGeometry.visible ||
        (!popupGeometry.text.includes("Bratislava,") &&
          !popupGeometry.text.includes("<Bratislava>,"))
      )
        throw new Error(
          `fullscreen popup containment failed: ${JSON.stringify(popupGeometry)}`,
        );
      if (width === 390 && height === 844) {
        await call("Emulation.setDeviceMetricsOverride", {
          width: 320,
          height: 568,
          deviceScaleFactor: 1,
          mobile: true,
        });
        await call("Emulation.setVisibleSize", { width: 320, height: 568 });
        await delay(180);
        const { result: resizedPopupResult } = await call("Runtime.evaluate", {
          expression:
            'JSON.stringify((()=>{const map=document.querySelector("#validator-map"),mr=map?.getBoundingClientRect(),popup=document.querySelector(".leaflet-popup"),pr=popup?.getBoundingClientRect(),content=popup?.querySelector(".leaflet-popup-content"),cr=content?.getBoundingClientRect(),rect=(value)=>value?{left:value.left,top:value.top,right:value.right,bottom:value.bottom,width:value.width,height:value.height}:null,inside=(value,bounds)=>Boolean(value&&bounds&&value.left>=bounds.left-1&&value.right<=bounds.right+1&&value.top>=bounds.top-1&&value.bottom<=bounds.bottom+1);return{open:Boolean(popup),visible:Boolean(inside(pr,mr)&&inside(cr,mr)&&content.scrollHeight<=content.clientHeight+1),map:rect(mr),popup:rect(pr),content:rect(cr),text:content?.textContent||""}})())',
          returnByValue: true,
        });
        const resizedPopup = JSON.parse(resizedPopupResult.value);
        if (
          !resizedPopup.open ||
          !resizedPopup.visible ||
          !resizedPopup.text.includes("Bratislava,")
        )
          throw new Error(
            `open-popup resize containment failed: ${JSON.stringify(resizedPopup)}`,
          );
        await call("Emulation.setDeviceMetricsOverride", {
          width: 390,
          height: 844,
          deviceScaleFactor: 1,
          mobile: true,
        });
        await call("Emulation.setVisibleSize", { width: 390, height: 844 });
        await delay(180);
        const { result: restoredPopupResult } = await call("Runtime.evaluate", {
          expression:
            'JSON.stringify((()=>{const map=document.querySelector("#validator-map"),mr=map?.getBoundingClientRect(),popup=document.querySelector(".leaflet-popup"),pr=popup?.getBoundingClientRect(),content=popup?.querySelector(".leaflet-popup-content"),cr=content?.getBoundingClientRect(),rect=(value)=>value?{left:value.left,top:value.top,right:value.right,bottom:value.bottom,width:value.width,height:value.height}:null,inside=(value,bounds)=>Boolean(value&&bounds&&value.left>=bounds.left-1&&value.right<=bounds.right+1&&value.top>=bounds.top-1&&value.bottom<=bounds.bottom+1);return{open:Boolean(popup),visible:Boolean(inside(pr,mr)&&inside(cr,mr)&&content.scrollHeight<=content.clientHeight+1),map:rect(mr),popup:rect(pr),content:rect(cr),text:content?.textContent||""}})())',
          returnByValue: true,
        });
        const restoredPopup = JSON.parse(restoredPopupResult.value);
        if (
          !restoredPopup.open ||
          !restoredPopup.visible ||
          !restoredPopup.text.includes("Bratislava,")
        )
          throw new Error(
            `open-popup restore containment failed: ${JSON.stringify(restoredPopup)}`,
          );
      }
      await call("Input.dispatchKeyEvent", {
        type: "keyDown",
        key: "Escape",
        code: "Escape",
        windowsVirtualKeyCode: 27,
      });
      await call("Input.dispatchKeyEvent", {
        type: "keyUp",
        key: "Escape",
        code: "Escape",
        windowsVirtualKeyCode: 27,
      });
      await delay(120);
      await call("Input.dispatchKeyEvent", {
        type: "keyDown",
        key: "Escape",
        code: "Escape",
        windowsVirtualKeyCode: 27,
      });
      await call("Input.dispatchKeyEvent", {
        type: "keyUp",
        key: "Escape",
        code: "Escape",
        windowsVirtualKeyCode: 27,
      });
      const { result: exitResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify({pressed:document.querySelector("#validator-map-fullscreen")?.getAttribute("aria-pressed"),locked:document.body.classList.contains("validator-map-fullscreen-open")})',
        returnByValue: true,
      });
      const exit = JSON.parse(exitResult.value);
      if (exit.pressed !== "false" || exit.locked)
        throw new Error(
          `fullscreen Escape contract failed: ${JSON.stringify(exit)}`,
        );
    }
    if ([1920, 1280, 390, 320].includes(width)) {
      await call("Runtime.evaluate", {
        expression:
          'document.querySelector("#nodes")?.scrollIntoView({behavior:"instant",block:"start"})',
      });
      await delay(80);
      const hostRowScreenshot = await call("Page.captureScreenshot", {
        format: "png",
      });
      await mkdir(evidenceDir, { recursive: true });
      await writeFile(
        join(evidenceDir, `host-row-${width}x${height}.png`),
        Buffer.from(hostRowScreenshot.data, "base64"),
      );
      const { result: fiveHostInitialResult } = await call(
        "Runtime.evaluate",
        {
          expression:
            'JSON.stringify((()=>{const cards=[...document.querySelectorAll("#nodes .node")];cards.slice(5).forEach(card=>card.remove());layoutHostCards();const remaining=[...document.querySelectorAll("#nodes .node")];return{count:remaining.length,expanded:remaining.filter(card=>card.classList.contains("is-expanded")).map(card=>card.dataset.nodeKey),collapsed:remaining.filter(card=>card.classList.contains("is-collapsed")).map(card=>card.dataset.nodeKey)}})())',
          returnByValue: true,
        },
      );
      const fiveHostInitial = JSON.parse(fiveHostInitialResult.value);
      const fiveHostExpectedExpanded = width <= 900 ? 1 : 4;
      if (
        fiveHostInitial.count !== 5 ||
        fiveHostInitial.expanded.length !== fiveHostExpectedExpanded ||
        fiveHostInitial.collapsed.length !== 5 - fiveHostExpectedExpanded
      )
        throw new Error(
          `five-Host initial accordion contract failed at ${width}x${height}: ${JSON.stringify(fiveHostInitial)}`,
        );
      await delay(380);
      const fiveHostScreenshot = await call("Page.captureScreenshot", {
        format: "png",
      });
      await writeFile(
        join(evidenceDir, `host-row-five-${width}x${height}.png`),
        Buffer.from(fiveHostScreenshot.data, "base64"),
      );
      const { result: fiveHostActivatedResult } = await call(
        "Runtime.evaluate",
        {
          expression:
            'JSON.stringify((()=>{const cards=[...document.querySelectorAll("#nodes .node")],first=cards[0],fifth=cards[4];fifth?.querySelector(".node-toggle")?.click();return{expanded:cards.filter(card=>card.classList.contains("is-expanded")).map(card=>card.dataset.nodeKey),firstCollapsed:first?.classList.contains("is-collapsed"),firstHidden:Boolean(first?.querySelector(".node-details")?.hidden),fifthExpanded:fifth?.classList.contains("is-expanded"),fifthOpen:fifth?.querySelector(".node-toggle")?.getAttribute("aria-expanded")}})())',
          returnByValue: true,
        },
      );
      const fiveHostActivated = JSON.parse(fiveHostActivatedResult.value);
      if (
        fiveHostActivated.expanded.length !== fiveHostExpectedExpanded ||
        !fiveHostActivated.firstCollapsed ||
        !fiveHostActivated.firstHidden ||
        !fiveHostActivated.fifthExpanded ||
        fiveHostActivated.fifthOpen !== "true"
      )
        throw new Error(
          `five-Host activation contract failed at ${width}x${height}: ${JSON.stringify(fiveHostActivated)}`,
        );
      await delay(380);
      const fiveHostActivatedScreenshot = await call(
        "Page.captureScreenshot",
        { format: "png" },
      );
      await writeFile(
        join(
          evidenceDir,
          `host-row-five-selected-${width}x${height}.png`,
        ),
        Buffer.from(fiveHostActivatedScreenshot.data, "base64"),
      );
      await call("Page.navigate", {
        url: `http://127.0.0.1:${server.address().port}/`,
      });
      await waitForInitialMap();
      await delay(500);
    }
    if ([1280, 390, 320].includes(width)) {
      await call("Runtime.evaluate", {
        expression:
          '(()=>{const details=document.querySelector(".join-requirements");if(details)details.open=true;document.querySelector("#join-node")?.scrollIntoView({behavior:"instant",block:"start"})})()',
      });
      await delay(80);
      const joinScreenshot = await call("Page.captureScreenshot", {
        format: "png",
      });
      await mkdir(evidenceDir, { recursive: true });
      await writeFile(
        join(evidenceDir, `join-requirements-${width}x${height}.png`),
        Buffer.from(joinScreenshot.data, "base64"),
      );
      if (width <= 390) {
        await call("Runtime.evaluate", {
          expression:
            'document.querySelector(".join-requirements-note")?.scrollIntoView({behavior:"instant",block:"end"})',
        });
        await delay(80);
        const joinNoteScreenshot = await call("Page.captureScreenshot", {
          format: "png",
        });
        await writeFile(
          join(evidenceDir, `join-requirements-note-${width}x${height}.png`),
          Buffer.from(joinNoteScreenshot.data, "base64"),
        );
      }
    }
    if ([701, 700].includes(width)) {
      participantLimit = 22;
      await call("Runtime.evaluate", {
        expression: "refresh()",
        awaitPromise: true,
      });
      await delay(380);
      const { result: denseHostGeometryResult } = await call(
        "Runtime.evaluate",
        {
          expression: denseHostDeckExpression,
          returnByValue: true,
        },
      );
      denseHostGeometry = JSON.parse(denseHostGeometryResult.value);
      if (!denseHostGeometry.pass)
        throw new Error(
          `Dense Host-deck reachability failed at ${width}x${height}: ${JSON.stringify(denseHostGeometry)}`,
        );
      participantLimit = 11;
      await call("Runtime.evaluate", {
        expression: "refresh()",
        awaitPromise: true,
      });
      await delay(380);
    }
    if ([1920, 1440, 1400, 1399, 1321, 1320, 1280, 1101, 1100, 844, 701, 700, 521, 390, 375, 360, 320].includes(width)) {
      const { result: hostGeometryResult } = await call("Runtime.evaluate", {
        expression: hostGeometryExpression,
        returnByValue: true,
      });
      hostGeometry = JSON.parse(hostGeometryResult.value);
      if (!hostGeometry.pass)
        throw new Error(
          `Host-card geometry contract failed at ${width}x${height}: ${JSON.stringify(hostGeometry)}`,
        );
    }
    await call("Runtime.evaluate", {
      expression:
        'document.querySelector("#validator-map")?.scrollIntoView({behavior:"instant",block:"center"})',
    });
    await delay(80);
    const screenshot = await call("Page.captureScreenshot", { format: "png" });
    await mkdir(evidenceDir, { recursive: true });
    await writeFile(
      join(evidenceDir, `validator-map-${width}x${height}.png`),
      Buffer.from(screenshot.data, "base64"),
    );
    reports.push({ width, height, ...state, hostGeometry, denseHostGeometry });
  }
  const forbidden = requests.filter((url) => forbiddenMapRequest.test(url));
  if (forbidden.length)
    throw new Error(`forbidden map requests: ${JSON.stringify(forbidden)}`);
  await writeFile(
    join(evidenceDir, "validator-map-fixture.json"),
    `${JSON.stringify({ reports, requests }, null, 2)}\n`,
  );
  process.stdout.write(
    `PASS deterministic validator-map fixture evidence=${evidenceDir}\n`,
  );
} finally {
  socket?.close();
  await stopChromeDevTools(browser);
  await rm(profile, { recursive: true, force: true });
  await new Promise((resolvePromise) => server.close(resolvePromise));
}
