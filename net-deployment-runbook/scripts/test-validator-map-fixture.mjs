#!/usr/bin/env node
// Deterministic local browser contract for the same-origin Natural Earth SVG
// and validator markers. It never contacts a public DevNet or map provider.
import { createServer } from "node:http";
import { createReadStream } from "node:fs";
import { mkdir, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { createServer as createNetServer } from "node:net";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { extname, join, normalize, resolve } from "node:path";

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
        address: "gonka1fixturedynamic",
        publicHost: "geo-fixture.invalid",
        statusBase: `http://127.0.0.1:${port}`,
        gpuProfile: "a5000-24g",
      },
    ],
  })};\n`;
const api = (port) => ({
  "/status/participants": {
    block_height: "424",
    participant: [
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
    ].map((key) => ({
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
const freePort = await new Promise((resolvePromise, reject) => {
  const probe = createNetServer();
  probe.once("error", reject);
  probe.listen(0, "127.0.0.1", () => {
    const port = probe.address().port;
    probe.close((error) => (error ? reject(error) : resolvePromise(port)));
  });
});
const profile = await mkdtemp(join(tmpdir(), "gdc-map-fixture-"));
const devtoolsReadyAttempts = 300;
const browser = spawn(
  process.env.CHROME_BIN || "google-chrome",
  [
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--remote-debugging-address=127.0.0.1",
    `--remote-debugging-port=${freePort}`,
    `--user-data-dir=${profile}`,
    "about:blank",
  ],
  { stdio: ["ignore", "ignore", "pipe"] },
);
let browserStderr = "";
let browserLaunchError = "";
browser.stderr.on("data", (chunk) => {
  browserStderr = `${browserStderr}${chunk}`.slice(-4096);
});
browser.on("error", (error) => {
  browserLaunchError = error.message;
});
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
async function devtools() {
  let lastConnectionError = "";
  for (let attempt = 0; attempt < devtoolsReadyAttempts; attempt += 1) {
    if (browserLaunchError) break;
    if (browser.exitCode !== null || browser.signalCode !== null) break;
    try {
      return await (
        await fetch(`http://127.0.0.1:${freePort}/json/version`)
      ).json();
    } catch (error) {
      lastConnectionError = error.message;
      await delay(100);
    }
  }
  const diagnostics = [
    browserLaunchError && `launch error: ${browserLaunchError}`,
    browser.exitCode !== null && `exit code: ${browser.exitCode}`,
    browser.signalCode !== null && `signal: ${browser.signalCode}`,
    lastConnectionError && `last connection error: ${lastConnectionError}`,
    browserStderr && `stderr: ${browserStderr.trim()}`,
  ].filter(Boolean);
  throw new Error(
    `Chrome DevTools endpoint did not become ready within ${
      (devtoolsReadyAttempts * 100) / 1000
    } seconds${diagnostics.length ? `: ${diagnostics.join("; ")}` : ""}`,
  );
}
try {
  socket = new WebSocket((await devtools()).webSocketDebuggerUrl);
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
    const card = document.querySelector("#nodes .node");
    const cards = [...document.querySelectorAll("#nodes .node")];
    if (!card) return { pass: false, error: "no Host card" };
    const setText = (selector, value) => {
      const element = card.querySelector(selector);
      if (element) element.textContent = value;
      return element;
    };
    setText("h3", "node0.example.test with a deliberately long hostname");
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
    const bounds = element => {
      const rect = element?.getBoundingClientRect();
      return rect && { top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right };
    };
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
    const rows = [...card.children]
      .filter(row => row.matches("h3,.status,small,.metric") && row.offsetParent !== null)
      .map(element => ({ bounds: bounds(element), textBounds: textBounds(element) }));
    const rowOverlap = rows.slice(0, -1).some((row, index) => row.textBounds && rows[index + 1].bounds && row.textBounds.bottom > rows[index + 1].bounds.top + 0.5);
    const cardRect = card.getBoundingClientRect();
    const contentBottom = rows.reduce((bottom, row) => Math.max(bottom, row.textBounds?.bottom ?? -Infinity), -Infinity);
    const next = cards
      .slice(1)
      .map(candidate => ({ candidate, bounds: candidate.getBoundingClientRect() }))
      .filter(item => item.bounds.top >= cardRect.bottom - 0.5 && item.bounds.left < cardRect.right && item.bounds.right > cardRect.left)
      .sort((left, right) => left.bounds.top - right.bounds.top)[0];
    const fields = {
      status: fieldInfo('[data-k="status"]'),
      statusReason: fieldInfo('[data-k="status-reason"]'),
      scope: fieldInfo('[data-k="scope"]'),
      votingPower: fieldInfo('[data-k="vp"]'),
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
    const nextOverlap = Boolean(next && contentBottom > next.bounds.top + 0.5);
    const complete = Object.values(fields).every(field => field.text && field.visible && !field.clipped);
    return {
      pass: Math.abs(cardRect.height - 424) <= 0.5 && card.scrollHeight <= card.clientHeight && !rowOverlap && contentBottom <= cardRect.bottom + 0.5 && !nextOverlap && complete && hiddenRejected && document.documentElement.scrollWidth <= innerWidth,
      card: { height: cardRect.height, clientHeight: card.clientHeight, scrollHeight: card.scrollHeight },
      fields,
      rowOverlap,
      nextOverlap,
      hiddenRequiredFieldRejected: hiddenRejected,
      cardBounds: bounds(card),
      contentBottom,
      nextBounds: next?.bounds || null,
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
  for (const [width, height] of [
    [1280, 720],
    [521, 720],
    [1440, 900],
    [1920, 1080],
    [390, 844],
  ]) {
    await call("Emulation.setDeviceMetricsOverride", {
      width,
      height,
      deviceScaleFactor: 1,
      mobile: width < 500,
    });
    await call("Page.navigate", {
      url: `http://127.0.0.1:${server.address().port}/`,
    });
    for (let attempt = 0; attempt < 120; attempt += 1) {
      const { result } = await call("Runtime.evaluate", {
        expression:
          'Boolean(document.querySelector("#updated")?.dateTime && document.querySelector(".validator-map-world")?.complete && Number(document.querySelector("#validator-map")?.dataset.markerCount)===7)',
        returnByValue: true,
      });
      if (result.value) break;
      if (attempt === 119) {
        const { result: mapResult } = await call("Runtime.evaluate", {
          expression:
            'JSON.stringify({text:document.querySelector("#validator-map")?.textContent,leaflet:typeof window.L,updated:document.querySelector("#updated")?.dateTime||"",nodes:document.querySelectorAll("#nodes .node").length,validators:document.querySelector("#validator-map")?.dataset.validatorCount||"",markers:document.querySelector("#validator-map")?.dataset.markerCount||"",world:Boolean(document.querySelector(".validator-map-world")?.complete&&document.querySelector(".validator-map-world")?.naturalWidth)})',
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
      await call("Emulation.setDeviceMetricsOverride", {
        width,
        height,
        deviceScaleFactor: 1,
        mobile: false,
      });
      await delay(200);
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
      height: 3000,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await call("Emulation.setVisibleSize", { width: 1280, height: 3000 });
    await call("Runtime.evaluate", {
      expression: `validatorMapController.update(${JSON.stringify(overlappingEuropeanMarkers)})`,
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
        const { result: currentMarkersResult } = await call(
          "Runtime.evaluate",
          {
            expression:
              'JSON.stringify([...document.querySelectorAll(".validator-marker")].map(marker=>{const r=marker.getBoundingClientRect();return{label:marker.getAttribute("aria-label"),x:r.left+r.width/2,y:r.top+r.height/2}}))',
            returnByValue: true,
          },
        );
        const marker = JSON.parse(currentMarkersResult.value).find((item) =>
          item.label?.startsWith(expected),
        );
        if (!marker) throw new Error(`overlapping marker missing ${expected}`);
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
      mobile: width < 500,
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
        'document.querySelector("#validator-map")?.scrollIntoView({block:"center"})',
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
    if (width < 500) {
      await call("Runtime.evaluate", {
        expression:
          'document.querySelector("#validator-map-fullscreen")?.click()',
      });
      await delay(80);
      const { result: fullResult } = await call("Runtime.evaluate", {
        expression:
          'JSON.stringify((()=>{const r=document.querySelector("#validator-map")?.getBoundingClientRect();return{left:r?.left,top:r?.top,right:r?.right,bottom:r?.bottom,pressed:document.querySelector("#validator-map-fullscreen")?.getAttribute("aria-pressed"),locked:document.body.classList.contains("validator-map-fullscreen-open")}})())',
        returnByValue: true,
      });
      const full = JSON.parse(fullResult.value);
      if (
        full.pressed !== "true" ||
        !full.locked ||
        full.left > 1 ||
        full.top > 1 ||
        full.right < width - 1 ||
        full.bottom < height - 1
      )
        throw new Error(`fullscreen coverage failed: ${JSON.stringify(full)}`);
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
    if ([1280, 521, 390].includes(width)) {
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
        'document.querySelector("#validator-map")?.scrollIntoView({block:"center"})',
    });
    await delay(80);
    const screenshot = await call("Page.captureScreenshot", { format: "png" });
    await mkdir(evidenceDir, { recursive: true });
    await writeFile(
      join(evidenceDir, `validator-map-${width}x${height}.png`),
      Buffer.from(screenshot.data, "base64"),
    );
    reports.push({ width, height, ...state, hostGeometry });
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
  browser.kill("SIGTERM");
  await new Promise((resolvePromise) => server.close(resolvePromise));
}
