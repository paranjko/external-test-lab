#!/usr/bin/env node
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';

const [url, widthText, heightText, output, visibleNodesText = '0'] = process.argv.slice(2);
const width = Number(widthText);
const height = Number(heightText);
const visibleNodes = Number(visibleNodesText);
const expectResetState = process.env.GDC_EXPECT_RESET_STATE === 'true';
const checkMapFullscreen = process.env.GDC_CHECK_MAP_FULLSCREEN === 'true';
const expectedGatewayState = process.env.GDC_EXPECT_GATEWAY_STATE || '';
const expectGatewayReady = process.env.GDC_EXPECT_GATEWAY_READY === 'true';
const expectedSiteRevision = process.env.GDC_EXPECT_SITE_REVISION || '';
const expectedAppDigest = process.env.GDC_EXPECT_APP_DIGEST || '';
const hostRequirementsProfile = JSON.parse(await readFile(new URL('../profiles/devnet-hadware.json', import.meta.url), 'utf8'));
const expectedJoinRequirements = hostRequirementsProfile.requirements.map(({ label, description }) => ({ label, value: description }));
const expectedJoinSummary = 'Minimum Host requirements For more details, read Community DevNet runbook/JOIN: add a Host';
const expectedJoinRequirementsNote = hostRequirementsProfile.model_context.description;
const reportBrowserFailure = error => {
  const detail = String(error?.message || error).replace(/\s+/g, ' ').trim();
  process.stderr.write(`WAIT homepage browser check unavailable reason=${detail}\n`);
  process.exitCode = 1;
};
process.on('uncaughtException', reportBrowserFailure);
process.on('unhandledRejection', reportBrowserFailure);
if (!url || !Number.isInteger(width) || !Number.isInteger(height) || !output || !Number.isInteger(visibleNodes) || visibleNodes < 0) {
  throw new Error('usage: capture-homepage-viewport.mjs URL WIDTH HEIGHT OUTPUT.png [MIN_VISIBLE_NODES]');
}

const profile = await mkdtemp(join(tmpdir(), 'gdc-homepage-chrome-'));
// A fixed DevTools port can be owned by another concurrent browser check,
// which leaves reset waiting forever for the wrong Chrome instance. Reserve an
// ephemeral loopback port for this invocation instead.
const port = await new Promise((resolve, reject) => {
  const server = createServer();
  server.once('error', reject);
  server.listen(0, '127.0.0.1', () => {
    const address = server.address();
    server.close(error => error ? reject(error) : resolve(address.port));
  });
});
const chrome = process.env.CHROME_BIN || 'google-chrome';
const browser = spawn(chrome, [
  '--headless=new', '--no-sandbox', '--disable-gpu', `--remote-debugging-port=${port}`,
  `--user-data-dir=${profile}`, 'about:blank',
], { stdio: 'ignore' });

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const mapCoverageExpression = 'JSON.stringify((()=>{const map=document.querySelector("#validator-map");if(!map)return null;const mapRect=map.getBoundingClientRect(),world=map.querySelector(".validator-map-world");return{worldLoaded:Boolean(world?.complete&&world?.naturalWidth),markersVisible:[...map.querySelectorAll(".validator-marker")].every(marker=>{const rect=marker.getBoundingClientRect();return rect.width>0&&rect.height>0&&rect.right>=mapRect.left&&rect.left<=mapRect.right&&rect.bottom>=mapRect.top&&rect.top<=mapRect.bottom})}})())';
const homepageStateExpression = `JSON.stringify({
  width: innerWidth,
  height: innerHeight,
  scrollWidth: document.documentElement.scrollWidth,
  updated: document.querySelector("#updated")?.textContent,
  updatedDateTime: document.querySelector("#updated")?.dateTime,
  updatedTag: document.querySelector("#updated")?.tagName,
  bestHeight: document.querySelector("#best-height")?.textContent,
  mapPoints: document.querySelectorAll("#validator-map .validator-marker").length,
  mapMarkers: Number(document.querySelector("#validator-map")?.dataset.markerCount || 0),
  mapValidators: Number(document.querySelector("#validator-map")?.dataset.validatorCount || 0),
  mapWorld: Boolean(document.querySelector("#validator-map .validator-map-world")?.complete && document.querySelector("#validator-map .validator-map-world")?.naturalWidth),
  mapMarkerGeometry: [...document.querySelectorAll("#validator-map .validator-marker")].map(marker => {
    const rect = marker.getBoundingClientRect();
    return { width: rect.width, height: rect.height, filter: getComputedStyle(marker).filter };
  }),
  siteRevision: document.querySelector("#site-revision")?.dataset.revision || "",
  appDigest: document.querySelector("#site-revision")?.dataset.appDigest || "",
  gatewayAccessHidden: document.querySelector("#gateway-access")?.hidden,
  join: ((element) => ({
    exists: Boolean(element),
    title: element?.querySelector("h2")?.textContent,
    code: element?.querySelector("code")?.textContent,
    link: element?.querySelector("a")?.href,
    summary: element?.querySelector("summary")?.textContent?.replace(/\\s+/g, " ").trim(),
    requirementsOpen: element?.querySelector(".join-requirements")?.open,
    requirements: [...(element?.querySelectorAll(".join-requirements-grid > div") || [])].map(item => ({
      label: item.querySelector("dt")?.textContent,
      value: item.querySelector("dd")?.textContent,
    })),
    requirementsNote: element?.querySelector(".join-requirements-note")?.textContent,
    modelLink: element?.querySelector(".join-requirements-note a")?.href,
  }))(document.querySelector("#join-node")),
  nodes: [...document.querySelectorAll("#nodes .node")].map(node => {
    const rect = node.getBoundingClientRect();
    const bounds = element => {
      const value = element?.getBoundingClientRect();
      return value && { top: value.top, bottom: value.bottom, left: value.left, right: value.right, width: value.width, height: value.height };
    };
    const textBounds = element => {
      if (!element) return null;
      const range = document.createRange();
      range.selectNodeContents(element);
      return bounds(range);
    };
    const rowInfo = element => {
      const value = textBounds(element);
      const rect = element?.getBoundingClientRect();
      const visible = Boolean(element && element.offsetParent !== null && rect && rect.width > 0 && rect.height > 0 && value && value.width > 0 && value.height > 0);
      return {
        bounds: bounds(element),
        textBounds: value,
        visible,
        clipped: Boolean(!visible || element.scrollWidth > element.clientWidth || element.scrollHeight > element.clientHeight || value.right > rect.right + 2 || value.bottom > rect.bottom + 2 || value.left < rect.left - 2 || value.top < rect.top - 2),
      };
    };
    const metric = key => {
      const row = node.querySelector("[data-k-row=" + key + "]");
      const value = row?.querySelector("b");
      const rect = value?.getBoundingClientRect();
      const visible = Boolean(value && value.offsetParent !== null && rect && rect.width > 0 && rect.height > 0);
      return {
        text: value?.textContent?.trim(),
        visible,
        clipped: Boolean(!visible || value.scrollWidth > value.clientWidth || value.scrollHeight > value.clientHeight || row.scrollHeight > row.clientHeight),
      };
    };
    const valueField = key => {
      const value = node.querySelector("[data-k=" + key + "]");
      const rect = value?.getBoundingClientRect();
      const visible = Boolean(value && value.offsetParent !== null && rect && rect.width > 0 && rect.height > 0);
      return {
        text: value?.textContent?.trim(),
        visible,
        clipped: Boolean(!visible || value.scrollWidth > value.clientWidth || value.scrollHeight > value.clientHeight),
      };
    };
    const textField = selector => {
      const value = node.querySelector(selector);
      const rect = value?.getBoundingClientRect();
      const range = textBounds(value);
      const visible = Boolean(value && value.offsetParent !== null && rect && rect.width > 0 && rect.height > 0 && range && range.width > 0 && range.height > 0);
      return {
        text: value?.textContent?.trim(),
        visible,
        clipped: Boolean(!visible || value.scrollWidth > value.clientWidth || value.scrollHeight > value.clientHeight || (range && (range.left < rect.left - 2 || range.right > rect.right + 2 || range.top < rect.top - 2 || range.bottom > rect.bottom + 2))),
      };
    };
    const statusField = textField("[data-k=status]");
    const statusReasonField = textField("[data-k=status-reason]");
    const scopeField = textField("[data-k=scope]");
    const rows = [...node.children]
      .filter(row => row.matches("h3,.status,small,.metric") && row.offsetParent !== null)
      .map(rowInfo);
    const rowOverlap = rows.slice(0, -1).some((row, index) => row.textBounds && rows[index + 1].bounds && row.textBounds.bottom > rows[index + 1].bounds.top + 0.5);
    const contentBottom = rows.reduce((bottom, row) => Math.max(bottom, row.textBounds?.bottom ?? -Infinity), -Infinity);
    return {
      name: node.querySelector("h3")?.textContent,
      status: statusField.text,
      statusVisible: statusField.visible,
      statusClipped: statusField.clipped,
      statusReason: statusReasonField.text,
      statusReasonVisible: statusReasonField.visible,
      statusReasonClipped: statusReasonField.clipped,
      scope: scopeField.text,
      scopeVisible: scopeField.visible,
      scopeClipped: scopeField.clipped,
      vp: node.querySelector("[data-k=vp]")?.textContent,
      sync: node.querySelector("[data-k=sync]")?.textContent,
      endpoint: node.querySelector("[data-k=endpoint]")?.textContent,
      versions: node.querySelector("[data-k=versions]")?.textContent,
      software: metric("software"),
      gpu: metric("gpu"),
      valueFields: ["height", "vp", "sync", "endpoint"].map(valueField),
      top: rect.top,
      bottom: rect.bottom,
      height: rect.height,
      clientHeight: node.clientHeight,
      scrollHeight: node.scrollHeight,
      rowOverlap,
      contentOverflowsCard: contentBottom > rect.bottom + 0.5,
    };
  }),
})`;
let socket;
let sequence = 0;
const pending = new Map();
async function endpoint() {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try { return await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); } catch { await delay(100); }
  }
  throw new Error('Chrome DevTools endpoint did not become ready');
}
try {
  const version = await endpoint();
  socket = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result);
  });
  const call = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const { targetId } = await call('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await call('Target.attachToTarget', { targetId, flatten: true });
  await call('Page.enable', {}, sessionId);
  await call('Network.enable', {}, sessionId);
  await call('Network.setCacheDisabled', { cacheDisabled: true }, sessionId);
  await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: true }, sessionId);
  await call('Page.navigate', { url }, sessionId);
  const gatewayStateReadyExpression = expectGatewayReady
    ? '/^READY – /.test(document.querySelector("#quality-health-state")?.textContent || "")'
    : '["READY – verified inference; processing requests","READY – verified inference; no requests in flight","RECOVERING","PENDING","UNAVAILABLE","OFFLINE"].includes(document.querySelector("#quality-health-state")?.textContent || "")';
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const { result } = await call('Runtime.evaluate', {
      expression: `Boolean(document.querySelector("#updated")?.dateTime && /^Updated .* UTC$/.test(document.querySelector("#updated")?.textContent || "") && ${gatewayStateReadyExpression})`,
      returnByValue: true,
    }, sessionId);
    if (result.value) break;
    if (attempt === 29) throw new Error('homepage status and live gateway refresh did not complete within 30 seconds');
    await delay(1000);
  }
  const { result } = await call('Runtime.evaluate', {
    expression: homepageStateExpression,
    returnByValue: true,
  }, sessionId);
  const state = JSON.parse(result.value);
  const { result: appDigestResult } = await call('Runtime.evaluate', {
    expression: '(async()=>{const script=[...document.scripts].find(item=>new URL(item.src,location.href).pathname.endsWith("/app.js"));if(!script)return"";const bytes=await fetch(script.src,{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error(`app.js fetch failed ${response.status}`);return response.arrayBuffer()});const digest=await crypto.subtle.digest("SHA-256",bytes);return [...new Uint8Array(digest)].map(byte=>byte.toString(16).padStart(2,"0")).join("")})()',
    awaitPromise: true,
    returnByValue: true,
  }, sessionId);
  state.loadedAppDigest = appDigestResult.value;
  if (state.width !== width || state.height !== height) throw new Error(`emulation mismatch ${state.width}x${state.height}`);
  if (expectedSiteRevision && state.siteRevision !== expectedSiteRevision) throw new Error(`preview revision mismatch ${JSON.stringify(state)}`);
  if (expectedAppDigest && (state.loadedAppDigest !== expectedAppDigest || state.appDigest !== expectedAppDigest)) throw new Error(`preview app digest mismatch ${JSON.stringify(state)}`);
  if (state.mapMarkerGeometry.some(marker => marker.width < 5 || marker.height < 5 || marker.width > 21 || marker.height > 21 || marker.filter !== 'none')) throw new Error(`validator marker geometry or halo contract failed ${JSON.stringify(state.mapMarkerGeometry)}`);
  if (state.scrollWidth > state.width) throw new Error(`horizontal overflow ${state.scrollWidth}>${state.width}`);
  if ((!expectResetState && state.nodes.length < 1) || state.updatedTag !== 'TIME' || !/^Updated .* UTC$/.test(state.updated || '') || !/^\d{4}-\d{2}-\d{2}T/.test(state.updatedDateTime || '') || !state.mapWorld) throw new Error(`homepage status or validator map did not render ${JSON.stringify(state)}`);
  if (!state.join.exists || state.join.title !== 'How to Join node' || state.join.code !== 'git clone https://github.com/paranjko/external-test-lab.git\nalias gdc="$PWD/external-test-lab/net-deployment-runbook/gdc.sh"\ngdc host join --public-host <IP_or_DOMAIN> <ssh-alias>' || state.join.link !== 'https://github.com/paranjko/external-test-lab/blob/main/net-deployment-runbook/ROLE-JOIN.md#join-add-a-host' || state.join.summary !== expectedJoinSummary || state.join.requirementsOpen || JSON.stringify(state.join.requirements) !== JSON.stringify(expectedJoinRequirements) || state.join.requirementsNote !== expectedJoinRequirementsNote || state.join.modelLink !== 'https://node0.gonka-dev.net/chain-api/productscience/inference/inference/models_all') throw new Error(`JOIN guide did not render ${JSON.stringify(state.join)}`);
  await call('Runtime.evaluate', { expression: 'document.querySelector(".join-requirements-toggle")?.click()' }, sessionId);
  await delay(100);
  const { result: joinRequirementsResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({open:document.querySelector(".join-requirements")?.open,page:document.documentElement.scrollWidth,viewport:innerWidth,nested:[...document.querySelectorAll(".join-requirements,.join-requirements *")].some(e=>e.scrollWidth>e.clientWidth)})',
    returnByValue: true,
  }, sessionId);
  const joinRequirements = JSON.parse(joinRequirementsResult.value);
  if (!joinRequirements.open || joinRequirements.page > joinRequirements.viewport || joinRequirements.nested) throw new Error(`JOIN requirements interaction or overflow failed ${JSON.stringify(joinRequirements)}`);
  await call('Runtime.evaluate', { expression: 'document.querySelector(".join-requirements-toggle")?.click()' }, sessionId);
  const mappedNodes = state.nodes;
  if (!expectResetState && state.mapValidators !== mappedNodes.length) throw new Error(`validator map has ${state.mapValidators} validators for ${mappedNodes.length} live participant cards ${JSON.stringify(state)}`);
  if ((!expectResetState && state.mapMarkers < 1) || state.mapPoints !== state.mapMarkers) throw new Error(`validator map rendered ${state.mapPoints} visible points for ${state.mapMarkers} geographic groups ${JSON.stringify(state)}`);
  if (mappedNodes.some(node => !node.versions || node.versions === 'checking')) throw new Error(`participant software versions did not resolve ${JSON.stringify(state)}`);
  const hasUnboundedHostDiagnostic = node => {
    const endpoint = node.endpoint || '';
    return /Failed to fetch|timeout|dns/i.test(`${node.status} ${endpoint}`)
      || (/\b[45]\d\d\b/.test(endpoint) && !/^Unavailable – HTTP [45]\d\d$/.test(endpoint));
  };
  if (mappedNodes.some(node => Math.abs(node.height - 424) > 0.5 || node.scrollHeight > node.clientHeight || node.rowOverlap || node.contentOverflowsCard || !node.status || !node.statusVisible || node.statusClipped || !node.statusReason || !node.statusReasonVisible || node.statusReasonClipped || !node.scope || !node.scopeVisible || node.scopeClipped || node.valueFields.some(field => !field.text || !field.visible || field.clipped) || !node.software.text || !node.software.visible || node.software.clipped || (node.gpu.text && (!node.gpu.visible || node.gpu.clipped)) || hasUnboundedHostDiagnostic(node))) throw new Error(`Host-card geometry or complete field contract failed ${JSON.stringify(mappedNodes)}`);
  if (expectResetState) {
    const active = state.nodes;
    if (active.some(node => !/^offline \(\d+\)$/.test(node.status || '')) || state.bestHeight !== '–' || !state.gatewayAccessHidden || state.mapValidators !== 0 || state.mapMarkers !== 0 || state.mapPoints !== 0) {
      throw new Error(`homepage does not show the real reset/offline state ${JSON.stringify(state)}`);
    }
  }
  if (expectedGatewayState === 'UNAVAILABLE' && !state.gatewayAccessHidden) {
    throw new Error(`gateway access card must be hidden while unavailable ${JSON.stringify(state)}`);
  }
  if (checkMapFullscreen) {
    await call('Runtime.evaluate', { expression: 'document.querySelector("#validator-map-fullscreen")?.click()' }, sessionId);
    await delay(350);
    const { result: fullscreenResult } = await call('Runtime.evaluate', { expression: `JSON.stringify({coverage:${mapCoverageExpression},rect:(()=>{const r=document.querySelector("#validator-map")?.getBoundingClientRect();return r&&{left:r.left,top:r.top,right:r.right,bottom:r.bottom}})(),pressed:document.querySelector("#validator-map-fullscreen")?.getAttribute("aria-pressed")})`, returnByValue: true }, sessionId);
    const fullscreen = JSON.parse(fullscreenResult.value);
    const coverage = JSON.parse(fullscreen.coverage);
    if (!coverage || !coverage.worldLoaded || !coverage.markersVisible || fullscreen.pressed !== 'true' || fullscreen.rect.left > 1 || fullscreen.rect.top > 1 || fullscreen.rect.right < width - 1 || fullscreen.rect.bottom < height - 1) throw new Error(`validator map does not cover fullscreen viewport ${JSON.stringify(fullscreen)}`);
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, sessionId);
    await call('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, sessionId);
    await delay(350);
    const { result: fullscreenExitResult } = await call('Runtime.evaluate', { expression: 'JSON.stringify({pressed:document.querySelector("#validator-map-fullscreen")?.getAttribute("aria-pressed"),active:document.querySelector("#validator-map-shell")?.classList.contains("is-fullscreen")})', returnByValue: true }, sessionId);
    const fullscreenExit = JSON.parse(fullscreenExitResult.value);
    if (fullscreenExit.pressed !== 'false' || fullscreenExit.active) throw new Error(`validator map did not exit fullscreen ${JSON.stringify(fullscreenExit)}`);
  }
  const { result: accessResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({code:document.querySelectorAll("#gateway-access pre,#gateway-access code").length,scroll:[...document.querySelectorAll("#gateway-access,#gateway-access *")].some(e=>{const s=getComputedStyle(e);return (s.overflowX==="auto"||s.overflowX==="scroll"||s.overflowY==="auto"||s.overflowY==="scroll")&&(e.scrollWidth>e.clientWidth||e.scrollHeight>e.clientHeight)})})',
    returnByValue: true,
  }, sessionId);
  const access = JSON.parse(accessResult.value);
  if (access.code || access.scroll) throw new Error('access card contains code or a nested scroll area');
  const { result: grafanaResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify(["grafana-network","grafana-inference"].map(id=>{const e=document.getElementById(id);return {id,href:e?.href,target:e?.target}}))',
    returnByValue: true,
  }, sessionId);
  const grafana = JSON.parse(grafanaResult.value);
  const expectedGrafanaPaths = ["/d/gdc-network/", "/d/gdc-inference/"];
  if (grafana.length !== 2 || grafana.some((link,index)=>{const url=new URL(link.href);return url.hostname!=="grafana.gonka-dev.net"||!url.pathname.startsWith(expectedGrafanaPaths[index])||!url.searchParams.has("kiosk")||link.target!=="_blank"})) throw new Error(`invalid public Grafana links ${JSON.stringify(grafana)}`);
  const { result: gatewayResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({metrics:[...document.querySelectorAll("#quality-metrics article")].map(e=>e.textContent),health:document.querySelector("#quality-health-state")?.textContent,counts:["quality-active","quality-accepted","quality-rejected"].map(id=>document.getElementById(id)?.textContent)})',
    returnByValue: true,
  }, sessionId);
  const gateway = JSON.parse(gatewayResult.value);
  if (gateway.metrics.length !== 5 || !gateway.metrics.some(text => text.includes("Active requests") && text.includes("currently in flight")) || !gateway.metrics.some(text => text.includes("Successful requests") && text.includes("completed since gateway restart")) || !gateway.metrics.some(text => text.includes("Rate-limited requests") && text.includes("rejected since gateway restart")) || !["READY – verified inference; processing requests", "READY – verified inference; no requests in flight", "RECOVERING", "PENDING", "UNAVAILABLE", "OFFLINE"].includes(gateway.health) || (!expectResetState && gateway.counts.some(value => !/^\d+$/.test(value || '')))) throw new Error(`incomplete live gateway contract ${JSON.stringify(gateway)}`);
  if (expectResetState && gateway.health !== 'OFFLINE') throw new Error(`gateway must be OFFLINE after reset ${JSON.stringify(gateway)}`);
  if (expectedGatewayState && gateway.health !== expectedGatewayState) throw new Error(`gateway state ${gateway.health} does not match expected ${expectedGatewayState}`);
  if (expectGatewayReady && !/^READY – /.test(gateway.health || '')) {
    throw new Error(`public page shows a non-ready gateway state ${gateway.health}`);
  }
  const { result: typeResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({heading:(s=>s==="normal"?0:Number.parseFloat(s))(getComputedStyle(document.querySelector(".hero h1")).letterSpacing),prose:Number.parseFloat(getComputedStyle(document.querySelector(".hero p")).wordSpacing),footer:Number.parseFloat(getComputedStyle(document.querySelector("footer")).wordSpacing),footerSize:Number.parseFloat(getComputedStyle(document.querySelector("footer")).fontSize),negativeTracking:[...document.querySelectorAll("body *")].filter(e=>{const s=getComputedStyle(e).letterSpacing;return s!=="normal"&&Number.parseFloat(s)<0}).map(e=>e.tagName+"."+e.className),footerChildren:[...document.querySelector("footer").children].map(e=>{const r=e.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom}})})',
    returnByValue: true,
  }, sessionId);
  const typography = JSON.parse(typeResult.value);
  const footerOverlap = typography.footerChildren.some((box, index, boxes) => boxes.slice(index + 1).some(other => box.left < other.right && other.left < box.right && box.top < other.bottom && other.top < box.bottom));
  if (typography.heading < 0 || typography.prose <= 0 || typography.footer <= 0 || typography.footerSize < 13 || typography.negativeTracking.length || footerOverlap) throw new Error(`unreadable typography contract ${JSON.stringify(typography)}`);
  await call('Runtime.evaluate', { expression: 'document.querySelector("#nodes")?.scrollIntoView({block:"start"})' }, sessionId);
  await delay(300);
  const { result: nodeViewportResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({height:innerHeight,nodes:[...document.querySelectorAll("#nodes .node")].map(n=>{const r=n.getBoundingClientRect();return {top:r.top,bottom:r.bottom}})})',
    returnByValue: true,
  }, sessionId);
  const nodeViewport = JSON.parse(nodeViewportResult.value);
  const visible = nodeViewport.nodes.filter(node => node.top >= 0 && node.bottom <= nodeViewport.height).length;
  if (visible < visibleNodes) throw new Error(`only ${visible}/${visibleNodes} required node cards are visible after scrolling to participant status`);
  await call('Runtime.evaluate', { expression: 'document.querySelector("#join-node")?.scrollIntoView({block:"start"})' }, sessionId);
  await delay(300);
  const screenshot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }, sessionId);
  await writeFile(output, Buffer.from(screenshot.data, 'base64'));
} finally {
  socket?.close();
  browser.kill('SIGTERM');
}
