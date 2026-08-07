#!/usr/bin/env node
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';

const [url, widthText, heightText, output, visibleNodesText = '0'] = process.argv.slice(2);
const width = Number(widthText);
const height = Number(heightText);
const visibleNodes = Number(visibleNodesText);
const expectResetState = process.env.GDC_EXPECT_RESET_STATE === 'true';
const expectedGatewayState = process.env.GDC_EXPECT_GATEWAY_STATE || '';
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
  await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: true }, sessionId);
  await call('Page.navigate', { url }, sessionId);
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const { result } = await call('Runtime.evaluate', {
      expression: 'Boolean(document.querySelector("#updated")?.dateTime && /^Updated .* UTC$/.test(document.querySelector("#updated")?.textContent || "") && ["READY – processing requests","READY – no requests in flight","PENDING","UNAVAILABLE","OFFLINE"].includes(document.querySelector("#quality-health-state")?.textContent || ""))',
      returnByValue: true,
    }, sessionId);
    if (result.value) break;
    if (attempt === 29) throw new Error('homepage status and live gateway refresh did not complete within 30 seconds');
    await delay(1000);
  }
  const { result } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({width:innerWidth,height:innerHeight,scrollWidth:document.documentElement.scrollWidth,updated:document.querySelector("#updated")?.textContent,updatedDateTime:document.querySelector("#updated")?.dateTime,updatedTag:document.querySelector("#updated")?.tagName,bestHeight:document.querySelector("#best-height")?.textContent,mapPoints:document.querySelectorAll("#validator-map .validator-marker").length,mapMarkers:Number(document.querySelector("#validator-map")?.dataset.markerCount||0),mapValidators:Number(document.querySelector("#validator-map")?.dataset.validatorCount||0),mapLeaflet:document.querySelector("#validator-map")?.classList.contains("leaflet-container"),gatewayAccessHidden:document.querySelector("#gateway-access")?.hidden,nodes:[...document.querySelectorAll("#nodes .node")].map(n=>({name:n.querySelector("h3")?.textContent,status:n.querySelector("[data-k=status]")?.textContent,versions:n.querySelector("[data-k=versions]")?.textContent,top:n.getBoundingClientRect().top,bottom:n.getBoundingClientRect().bottom}))})',
    returnByValue: true,
  }, sessionId);
  const state = JSON.parse(result.value);
  if (state.width !== width || state.height !== height) throw new Error(`emulation mismatch ${state.width}x${state.height}`);
  if (state.scrollWidth > state.width) throw new Error(`horizontal overflow ${state.scrollWidth}>${state.width}`);
  if (state.nodes.length < 1 || state.updatedTag !== 'TIME' || !/^Updated .* UTC$/.test(state.updated || '') || !/^\d{4}-\d{2}-\d{2}T/.test(state.updatedDateTime || '') || !state.mapLeaflet || state.mapPoints < 1) throw new Error(`homepage status or validator map did not render ${JSON.stringify(state)}`);
  const mappedNodes = state.nodes.filter(node => node.name !== 'gdc-node3');
  if (state.mapValidators !== mappedNodes.length) throw new Error(`validator map has ${state.mapValidators} validators for ${mappedNodes.length} live participant cards ${JSON.stringify(state)}`);
  if (state.mapMarkers < 1 || state.mapPoints !== state.mapMarkers) throw new Error(`validator map rendered ${state.mapPoints} visible points for ${state.mapMarkers} geographic groups ${JSON.stringify(state)}`);
  if (mappedNodes.some(node => !node.versions || node.versions === 'checking')) throw new Error(`participant software versions did not resolve ${JSON.stringify(state)}`);
  if (expectResetState) {
    const active = state.nodes.filter(node => node.name !== 'gdc-node3');
    if (active.length < 1 || active.some(node => !/^offline \(\d+\)$/.test(node.status || '')) || state.bestHeight !== '–' || !state.gatewayAccessHidden) {
      throw new Error(`homepage does not show the real reset/offline state ${JSON.stringify(state)}`);
    }
  }
  if (expectedGatewayState === 'UNAVAILABLE' && !state.gatewayAccessHidden) {
    throw new Error(`gateway access card must be hidden while unavailable ${JSON.stringify(state)}`);
  }
  await call('Runtime.evaluate', { expression: 'document.querySelector("#validator-map .leaflet-control-zoom-in")?.click()' }, sessionId);
  await delay(300);
  await call('Runtime.evaluate', { expression: 'document.querySelector("#validator-map .leaflet-control-zoom-out")?.click()' }, sessionId);
  await delay(300);
  const { result: mapCoverageResult } = await call('Runtime.evaluate', {
    expression: '(()=>{const map=document.querySelector("#validator-map");return Boolean(map&&getComputedStyle(map).backgroundColor!=="rgb(221, 221, 221)")})()',
    returnByValue: true,
  }, sessionId);
  if (!mapCoverageResult.value) throw new Error('validator map restored Leaflet default light background after zoom in/out');
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
  if (gateway.metrics.length !== 5 || !gateway.metrics.some(text => text.includes("Active requests") && text.includes("currently in flight")) || !gateway.metrics.some(text => text.includes("Successful requests") && text.includes("completed since gateway restart")) || !gateway.metrics.some(text => text.includes("Rate-limited requests") && text.includes("rejected since gateway restart")) || !["READY – processing requests", "READY – no requests in flight", "PENDING", "UNAVAILABLE", "OFFLINE"].includes(gateway.health) || (!expectResetState && gateway.counts.some(value => !/^\d+$/.test(value || '')))) throw new Error(`incomplete live gateway contract ${JSON.stringify(gateway)}`);
  if (expectResetState && gateway.health !== 'OFFLINE') throw new Error(`gateway must be OFFLINE after reset ${JSON.stringify(gateway)}`);
  if (expectedGatewayState && gateway.health !== expectedGatewayState) throw new Error(`gateway state ${gateway.health} does not match expected ${expectedGatewayState}`);
  const { result: typeResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({heading:(s=>s==="normal"?0:Number.parseFloat(s))(getComputedStyle(document.querySelector(".hero h1")).letterSpacing),prose:Number.parseFloat(getComputedStyle(document.querySelector(".hero p")).wordSpacing),footer:Number.parseFloat(getComputedStyle(document.querySelector("footer")).wordSpacing),footerSize:Number.parseFloat(getComputedStyle(document.querySelector("footer")).fontSize),negativeTracking:[...document.querySelectorAll("body *")].filter(e=>{const s=getComputedStyle(e).letterSpacing;return s!=="normal"&&Number.parseFloat(s)<0}).map(e=>e.tagName+"."+e.className),footerChildren:[...document.querySelector("footer").children].map(e=>{const r=e.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom}})})',
    returnByValue: true,
  }, sessionId);
  const typography = JSON.parse(typeResult.value);
  const footerOverlap = typography.footerChildren.some((box, index, boxes) => boxes.slice(index + 1).some(other => box.left < other.right && other.left < box.right && box.top < other.bottom && other.top < box.bottom));
  if (typography.heading < 0 || typography.prose <= 0 || typography.footer <= 0 || typography.footerSize < 13 || typography.negativeTracking.length || footerOverlap) throw new Error(`unreadable typography contract ${JSON.stringify(typography)}`);
  const visible = state.nodes.filter(node => node.top >= 0 && node.bottom <= state.height).length;
  if (visible < visibleNodes) throw new Error(`only ${visible}/${visibleNodes} required node cards are visible in the initial viewport`);
  const screenshot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }, sessionId);
  await writeFile(output, Buffer.from(screenshot.data, 'base64'));
} finally {
  socket?.close();
  browser.kill('SIGTERM');
}
