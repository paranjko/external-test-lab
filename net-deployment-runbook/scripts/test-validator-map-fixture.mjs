#!/usr/bin/env node
// Deterministic local regression fixture. It serves an arbitrary generated
// site tree, fixture API data, and locally supplied Leaflet/tile bytes. The
// browser never contacts a public DevNet endpoint.
import { createServer } from 'node:http';
import { readFile, stat, mkdir, writeFile } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createServer as createNetServer } from 'node:net';
import { spawn } from 'node:child_process';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, extname, normalize, resolve } from 'node:path';

const [siteRootText, evidenceDir] = process.argv.slice(2);
const leafletRoot = process.env.GDC_LEAFLET_DIST;
if (!siteRootText || !evidenceDir || !leafletRoot) throw new Error('usage: GDC_LEAFLET_DIST=DIR test-validator-map-fixture.mjs SITE_ROOT EVIDENCE_DIR');
const siteRoot = resolve(siteRootText);
const tile = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLJqQAAAABJRU5ErkJggg==';
const now = new Date().toISOString();
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const mime = { '.css': 'text/css', '.html': 'text/html', '.js': 'text/javascript', '.woff2': 'font/woff2' };
const config = port => `window.GDC_CONFIG = ${JSON.stringify({ chainId: 'fixture-chain', model: 'Qwen/Qwen3-0.6B', chainRpcHost: 'fixture.invalid', grafanaNetwork: 'https://grafana.gonka-dev.net/d/gdc-network/fixture?kiosk', grafanaInference: 'https://grafana.gonka-dev.net/d/gdc-inference/fixture?kiosk', nodes: [{ name: 'fixture-node', address: 'gonka1fixture', publicHost: 'fixture.local', statusBase: `http://127.0.0.1:${port}`, ip: '127.0.0.1', geo: { latitude: 48.15, longitude: 17.11, city: 'Bratislava', country: 'Slovakia', isp: 'fixture' }, gpuProfile: 'a5000-24g' }], nodeCatalog: [{ name: 'fixture-node', address: 'gonka1fixture', publicHost: 'fixture.local', statusBase: `http://127.0.0.1:${port}`, ip: '127.0.0.1', geo: { latitude: 48.15, longitude: 17.11, city: 'Bratislava', country: 'Slovakia', isp: 'fixture' }, gpuProfile: 'a5000-24g' }] })};\n`;
const api = port => ({
  '/status/participants': { block_height: '424', participant: [{ address: 'gonka1fixture', inference_url: `http://127.0.0.1:${port}`, validator_key: 'fixture-key', status: 'ACTIVE' }] },
  '/status/gpus': { data: { result: [{ metric: { host: 'fixture-node', gpu_name: 'NVIDIA RTX A5000' } }] } },
  '/status/software': { data: { result: [{ metric: { host: 'fixture-node', component: 'chain', version: 'v1.2.3' } }, { metric: { host: 'fixture-node', component: 'DAPI', version: 'v2.3.4' } }, { metric: { host: 'fixture-node', component: 'MLNode', version: 'v3.4.5' } }] } },
  '/status/telegram-consumer': { status: 'ok', inference_ready: true },
  '/chain-rpc/status': { result: { sync_info: { latest_block_height: '424', catching_up: false, latest_block_time: now } } },
  '/chain-rpc/net_info': { result: { n_peers: '4' } }, '/v1/versions': {},
  '/status/gateway/v1/status': { escrow_id: 'fixture', active: true, phase: 'active', requests_blocked: false },
  '/status/gateway-health': { state: 'READY', checked_at: now, curl_exit: 0, http_status: 200, latency_ms: 1, reason: '', admission: 'dispatched_once', admission_id: 'fixture', safe_generation: 'fixture', arrival_height: 424, permit_height: 424, dispatch_height: 424, response_height: 424 },
});
const server = createServer(async (request, response) => {
  const path = new URL(request.url, `http://127.0.0.1:${server.address().port}`).pathname;
  if (path === '/config.js') { response.writeHead(200, { 'content-type': 'text/javascript' }); response.end(config(server.address().port)); return; }
  if (path === '/status/gateway/metrics') { response.writeHead(200, { 'content-type': 'text/plain' }); response.end('devshard_gateway_inflight_requests 0\ndevshard_gateway_inflight_input_tokens 0\ndevshard_gateway_requests_total 7\ndevshard_gateway_limit_rejections_total 0\ndevshard_gateway_capacity_scale 1\n'); return; }
  const state = api(server.address().port)[path];
  if (state) { response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify(state)); return; }
  const relative = path === '/' ? '/index.html' : path;
  const file = resolve(siteRoot, `.${normalize(relative)}`);
  if (!file.startsWith(`${siteRoot}/`)) { response.writeHead(403); response.end(); return; }
  try { await stat(file); response.writeHead(200, { 'content-type': mime[extname(file)] || 'application/octet-stream' }); createReadStream(file).pipe(response); } catch { response.writeHead(404); response.end(); }
});
await new Promise((resolvePromise, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolvePromise); });
const freePort = await new Promise((resolvePromise, reject) => { const probe = createNetServer(); probe.once('error', reject); probe.listen(0, '127.0.0.1', () => { const port = probe.address().port; probe.close(error => error ? reject(error) : resolvePromise(port)); }); });
const profile = await mkdtemp(join(tmpdir(), 'gdc-map-fixture-'));
const browser = spawn(process.env.CHROME_BIN || 'google-chrome', ['--headless=new', '--no-sandbox', '--disable-gpu', `--remote-debugging-port=${freePort}`, `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
let socket; let sequence = 0; let sessionId; const pending = new Map();
const call = (method, params = {}, target = sessionId) => new Promise((resolvePromise, reject) => { const id = ++sequence; pending.set(id, { resolve: resolvePromise, reject }); socket.send(JSON.stringify({ id, method, params, ...(target ? { sessionId: target } : {}) })); });
const coverage = 'JSON.stringify((()=>{const map=document.querySelector("#validator-map"),r=map?.getBoundingClientRect(),tiles=[...document.querySelectorAll("#validator-map .leaflet-tile")].map(t=>t.getBoundingClientRect()),edge=n=>tiles.some(t=>n==="top"?t.top<=r.top+1:n==="bottom"?t.bottom>=r.bottom-1:n==="left"?t.left<=r.left+1:t.right>=r.right-1);return{top:edge("top"),bottom:edge("bottom"),left:edge("left"),right:edge("right"),tiles:tiles.length,markers:document.querySelectorAll("#validator-map .validator-marker").length,zoom:Number(map?.dataset.zoom),rect:{left:r?.left,top:r?.top,right:r?.right,bottom:r?.bottom}}})())';
const leaflet = await readFile(join(leafletRoot, 'leaflet-src.esm.js'));
const stylesheet = await readFile(join(leafletRoot, 'leaflet.css'));
const cartoTileHosts = new Set(['a.basemaps.cartocdn.com', 'b.basemaps.cartocdn.com', 'c.basemaps.cartocdn.com', 'd.basemaps.cartocdn.com']);
const isCartoTile = url => {
  try {
    const target = new URL(url);
    return target.protocol === 'https:' && cartoTileHosts.has(target.hostname);
  } catch {
    return false;
  }
};
async function devtools() { for (let attempt = 0; attempt < 60; attempt += 1) { try { return await (await fetch(`http://127.0.0.1:${freePort}/json/version`)).json(); } catch { await delay(100); } } throw new Error('Chrome DevTools endpoint did not become ready'); }
try {
  socket = new WebSocket((await devtools()).webSocketDebuggerUrl);
  await new Promise((resolvePromise, reject) => { socket.addEventListener('open', resolvePromise, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  socket.addEventListener('message', async event => {
    const message = JSON.parse(event.data); if (message.id) { const waiter = pending.get(message.id); if (!waiter) return; pending.delete(message.id); message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result); return; }
    if (message.method !== 'Fetch.requestPaused') return;
    const url = message.params.request.url; const cartoTile = isCartoTile(url); const body = url.includes('leaflet-src.esm.js') ? leaflet : url.includes('leaflet.css') ? stylesheet : cartoTile ? Buffer.from(tile, 'base64') : JSON.stringify({ result: url.includes('validators') ? { validators: [{ pub_key: { value: 'fixture-key' }, voting_power: '100' }] } : { sync_info: { latest_block_height: '424' } } });
    const type = url.includes('.css') ? 'text/css' : cartoTile ? 'image/png' : url.includes('fixture.invalid') ? 'application/json' : 'text/javascript';
    await call('Fetch.fulfillRequest', { requestId: message.params.requestId, responseCode: 200, responseHeaders: [{ name: 'content-type', value: type }, { name: 'access-control-allow-origin', value: '*' }], body: Buffer.from(body).toString('base64') });
  });
  const { targetId } = await call('Target.createTarget', { url: 'about:blank' }, undefined); ({ sessionId } = await call('Target.attachToTarget', { targetId, flatten: true }, undefined));
  await call('Page.enable'); await call('Fetch.enable', { patterns: [{ urlPattern: 'https://unpkg.com/*' }, { urlPattern: 'https://*.basemaps.cartocdn.com/*' }, { urlPattern: 'https://fixture.invalid/*' }] });
  const reports = [];
  for (const [width, height] of [[1280, 720], [1440, 900], [1920, 1080], [390, 844]]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: width < 500 }); await call('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 2 }); await call('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/` });
    for (let attempt = 0; attempt < 50; attempt += 1) { const { result } = await call('Runtime.evaluate', { expression: 'Boolean(document.querySelector("#updated")?.dateTime && Number(document.querySelector("#validator-map")?.dataset.markerCount)>0)', returnByValue: true }); if (result.value) break; if (attempt === 49) throw new Error(`fixture did not render at ${width}x${height}`); await delay(100); }
    await call('Runtime.evaluate', { expression: 'document.querySelector("#validator-map")?.scrollIntoView({block:"center"});document.querySelector("#validator-map .leaflet-control-zoom-out")?.click()' }); await delay(350);
    const { result } = await call('Runtime.evaluate', { expression: coverage, returnByValue: true }); const state = JSON.parse(result.value);
    if (!state.top || !state.bottom || !state.left || !state.right || !state.tiles || !state.markers) throw new Error(`map edge coverage failed at ${width}x${height}: ${JSON.stringify(state)}`);
    await delay(300);
    const { result: gestureStartResult } = await call('Runtime.evaluate', { expression: 'JSON.stringify((()=>{const r=document.querySelector("#validator-map").getBoundingClientRect();return{zoom:Number(document.querySelector("#validator-map").dataset.zoom),scrollY,x:r.left+r.width*.72,y:r.top+r.height*.33}})())', returnByValue: true });
    const gestureStart = JSON.parse(gestureStartResult.value);
    const { result: diagonalResult } = await call('Runtime.evaluate', { expression: `new Promise(resolve=>{const map=document.querySelector("#validator-map");const allowed=map.dispatchEvent(new WheelEvent("wheel",{bubbles:true,cancelable:true,ctrlKey:true,deltaX:7,deltaY:-9,clientX:${gestureStart.x},clientY:${gestureStart.y}}));requestAnimationFrame(()=>resolve(JSON.stringify({allowed,zoom:Number(map.dataset.zoom),scrollY})))})`, awaitPromise: true, returnByValue: true });
    const diagonal = JSON.parse(diagonalResult.value); await delay(150);
    const { result: wheelCoverageResult } = await call('Runtime.evaluate', { expression: coverage, returnByValue: true }); const wheelCoverage = JSON.parse(wheelCoverageResult.value);
    if (diagonal.allowed || !(diagonal.zoom > gestureStart.zoom) || diagonal.scrollY !== gestureStart.scrollY || !wheelCoverage.top || !wheelCoverage.bottom || !wheelCoverage.left || !wheelCoverage.right) throw new Error(`fractional diagonal pinch does not stay anchored and covered: ${JSON.stringify({ gestureStart, diagonal, wheelCoverage })}`);
    await call('Input.dispatchMouseEvent', { type: 'mouseWheel', x: gestureStart.x, y: gestureStart.y, deltaX: 5, deltaY: 12 }); await delay(150);
    const { result: trustedResult } = await call('Runtime.evaluate', { expression: `JSON.stringify({zoom:Number(document.querySelector("#validator-map").dataset.zoom),scrollY,coverage:${coverage}})`, returnByValue: true }); const trusted = JSON.parse(trustedResult.value); const trustedCoverage = JSON.parse(trusted.coverage);
    if (!(trusted.zoom < diagonal.zoom) || trusted.scrollY !== gestureStart.scrollY || !trustedCoverage.top || !trustedCoverage.bottom || !trustedCoverage.left || !trustedCoverage.right) throw new Error(`trusted wheel does not stay contained and covered: ${JSON.stringify({ diagonal, trusted, trustedCoverage })}`);
    const point = (x, id) => ({ x, y: gestureStart.y, id, radiusX: 4, radiusY: 4, force: 1 });
    await call('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [point(gestureStart.x - 80, 1), point(gestureStart.x + 80, 2)] }); await call('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [point(gestureStart.x - 45, 1), point(gestureStart.x + 45, 2)] }); await delay(100); await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }); await delay(150);
    const { result: touchResult } = await call('Runtime.evaluate', { expression: `JSON.stringify({zoom:Number(document.querySelector("#validator-map").dataset.zoom),scrollY,coverage:${coverage}})`, returnByValue: true }); const touch = JSON.parse(touchResult.value); const touchCoverage = JSON.parse(touch.coverage);
    if (!(touch.zoom < trusted.zoom) || touch.scrollY !== gestureStart.scrollY || !touchCoverage.top || !touchCoverage.bottom || !touchCoverage.left || !touchCoverage.right) throw new Error(`native two-touch pinch does not stay contained and covered: ${JSON.stringify({ trusted, touch, touchCoverage })}`);
    if (width < 500) { await call('Runtime.evaluate', { expression: 'document.querySelector("#validator-map-fullscreen")?.click()' }); await delay(350); const { result: full } = await call('Runtime.evaluate', { expression: coverage, returnByValue: true }); const fullscreen = JSON.parse(full.value); if (!fullscreen.top || !fullscreen.bottom || fullscreen.rect.left > 1 || fullscreen.rect.top > 1 || fullscreen.rect.right < width - 1 || fullscreen.rect.bottom < height - 1) throw new Error(`fullscreen coverage failed: ${JSON.stringify(fullscreen)}`); }
    const screenshot = await call('Page.captureScreenshot', { format: 'png' }); await mkdir(evidenceDir, { recursive: true }); await writeFile(join(evidenceDir, `validator-map-${width}x${height}.png`), Buffer.from(screenshot.data, 'base64')); reports.push({ width, height, ...state });
  }
  await writeFile(join(evidenceDir, 'validator-map-fixture.json'), `${JSON.stringify(reports, null, 2)}\n`); process.stdout.write(`PASS deterministic validator-map fixture evidence=${evidenceDir}\n`);
} finally { socket?.close(); browser.kill('SIGTERM'); await new Promise(resolvePromise => server.close(resolvePromise)); }
