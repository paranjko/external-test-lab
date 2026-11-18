#!/usr/bin/env node
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { startChromeDevTools, stopChromeDevTools } from './chrome-devtools.mjs';
import { compareHostIdentitySets } from './preview-host-identities.mjs';

const [url, widthText, heightText, output, visibleNodesText = '0', screenshotScrollText = '0'] = process.argv.slice(2);
const width = Number(widthText);
const height = Number(heightText);
const visibleNodes = Number(visibleNodesText);
const screenshotScroll = Number(screenshotScrollText);
const expectResetState = process.env.GDC_EXPECT_RESET_STATE === 'true';
const expectNetworkSnapshot = process.env.GDC_EXPECT_NETWORK_SNAPSHOT === 'true';
const checkMapFullscreen = process.env.GDC_CHECK_MAP_FULLSCREEN === 'true';
const expectedGatewayState = process.env.GDC_EXPECT_GATEWAY_STATE || '';
const expectGatewayReady = process.env.GDC_EXPECT_GATEWAY_READY === 'true';
const expectedSiteRevision = process.env.GDC_EXPECT_SITE_REVISION || '';
const expectedAppDigest = process.env.GDC_EXPECT_APP_DIGEST || '';
const expectedStatusPrefix = process.env.GDC_EXPECT_STATUS_PREFIX || '';
const expectedGithubHref = process.env.GDC_EXPECT_GITHUB_HREF || '';
const expectedCardCount = Number(process.env.GDC_EXPECT_CARD_COUNT || '0');
const expectedNodeStates = (process.env.GDC_EXPECT_NODE_STATES || '')
  .split(',')
  .filter(Boolean)
  .map(item => {
    const [name, state] = item.split('=', 2);
    return { name, state };
  });
const reportBrowserFailure = error => {
  const detail = String(error?.message || error).replace(/\s+/g, ' ').trim();
  process.stderr.write(`WAIT homepage browser check unavailable reason=${detail}\n`);
  process.exitCode = 1;
};
process.on('uncaughtException', reportBrowserFailure);
process.on('unhandledRejection', reportBrowserFailure);
if (!url || !Number.isInteger(width) || !Number.isInteger(height) || !output || !Number.isInteger(visibleNodes) || visibleNodes < 0 || !Number.isSafeInteger(screenshotScroll) || screenshotScroll < 0) {
  throw new Error('usage: capture-homepage-viewport.mjs URL WIDTH HEIGHT OUTPUT.png [MIN_VISIBLE_NODES [SCREENSHOT_SCROLL]]');
}
if (expectedStatusPrefix && !expectedStatusPrefix.startsWith('/')) {
  throw new Error('GDC_EXPECT_STATUS_PREFIX must be an absolute path prefix');
}
if (expectNetworkSnapshot && !expectedStatusPrefix) {
  throw new Error('GDC_EXPECT_NETWORK_SNAPSHOT requires GDC_EXPECT_STATUS_PREFIX');
}
if (!Number.isInteger(expectedCardCount) || expectedCardCount < 0) {
  throw new Error('GDC_EXPECT_CARD_COUNT must be a non-negative integer');
}

const browserTempRoot = process.env.GDC_BROWSER_TMPDIR || join(process.cwd(), '..', '.data', 'browser-tmp');
await mkdir(browserTempRoot, { recursive: true });
const profile = await mkdtemp(join(browserTempRoot, 'gdc-homepage-chrome-'));
const chrome = process.env.CHROME_BIN || 'google-chrome';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const mapCoverageExpression = 'JSON.stringify((()=>{const map=document.querySelector("#validator-map");if(!map)return null;const mapRect=map.getBoundingClientRect(),world=map.querySelector(".validator-map-world"),worldRect=world?.getBoundingClientRect(),markers=[...map.querySelectorAll(".validator-marker")].map(marker=>{const rect=marker.getBoundingClientRect();return{label:marker.getAttribute("aria-label"),left:rect.left,top:rect.top,right:rect.right,bottom:rect.bottom,width:rect.width,height:rect.height,visible:rect.width>0&&rect.height>0&&rect.left>=mapRect.left-1&&rect.right<=mapRect.right+1&&rect.top>=mapRect.top-1&&rect.bottom<=mapRect.bottom+1}});return{worldLoaded:Boolean(world?.complete&&world?.naturalWidth),worldFits:Boolean(worldRect&&worldRect.left>=mapRect.left-1&&worldRect.right<=mapRect.right+1&&worldRect.top>=mapRect.top-1&&worldRect.bottom<=mapRect.bottom+1),markersVisible:markers.every(marker=>marker.visible),markers}})())';
const homepageStateExpression = `JSON.stringify({
  width: innerWidth,
  height: innerHeight,
  visualWidth: visualViewport?.width || innerWidth,
  visualHeight: visualViewport?.height || innerHeight,
  scrollWidth: document.documentElement.scrollWidth,
  updated: document.querySelector("#updated")?.textContent,
  updatedDateTime: document.querySelector("#updated")?.dateTime,
  updatedTag: document.querySelector("#updated")?.tagName,
  bestHeight: document.querySelector("#best-height")?.textContent,
  devshardVersions: ((element) => ({
    text: element?.textContent?.trim(),
    title: element?.title || "",
  }))(document.querySelector("#devshard-versions")),
  mapPoints: document.querySelectorAll("#validator-map .validator-marker").length,
  mapMarkers: Number(document.querySelector("#validator-map")?.dataset.markerCount || 0),
  mapHosts: Number(document.querySelector("#validator-map")?.dataset.hostCount || 0),
  currentValidatorCount: document.querySelector("#validator-map")?.dataset.currentValidatorCount || "unavailable",
  validatorHeight: document.querySelector("#validator-map")?.dataset.validatorHeight || "",
  mapWorld: Boolean(document.querySelector("#validator-map .validator-map-world")?.complete && document.querySelector("#validator-map .validator-map-world")?.naturalWidth),
  mapMarkerDetails: [...document.querySelectorAll("#validator-map .validator-marker")].map(marker => {
    const rect = marker.getBoundingClientRect();
    const label = marker.getAttribute("aria-label") || "";
    const count = Number(/; (\\d+) nodes?\\b/.exec(label)?.[1] || 0);
    const gpuCount = Number(/; (\\d+) GPUs?;/.exec(label)?.[1] || 0);
    const radius = rect.width / 2;
    return { label, count, gpuCount, radius, width: rect.width, height: rect.height, filter: getComputedStyle(marker).filter };
  }),
  siteRevision: document.querySelector("#site-revision")?.dataset.revision || "",
  appDigest: document.querySelector("#site-revision")?.dataset.appDigest || "",
  configuredChainId: String(window.GDC_CONFIG?.chainId || ""),
  publicBootstrap: window.GDC_CONFIG?.publicBootstrap === true,
  footerGithub: ((element) => ({
    href: element?.href || "",
    ariaLabel: element?.getAttribute("aria-label") || "",
    width: element?.getBoundingClientRect().width || 0,
    height: element?.getBoundingClientRect().height || 0,
  }))(document.querySelector("#footer-github")),
  removedSections: ["join-node", "epoch-overview", "verification-results", "devshard-execution", "gateway-quality", "gateway-access"].filter(id => document.getElementById(id)),
  traffic: ((section) => ({
    state: section?.dataset.state || "",
    total: section?.querySelector("#traffic-total-rps")?.textContent?.trim() || "",
    cards: [...(section?.querySelectorAll(".traffic-card") || [])].map(card => ({
      name: card.querySelector(".traffic-name")?.textContent?.trim() || "",
      rps: card.querySelector(".traffic-rps")?.textContent?.trim() || "",
      values: [...card.querySelectorAll("dd")].map(value => value.textContent?.trim() || ""),
    })),
  }))(document.querySelector("#gateway-traffic")),
  nodeDeck: ((element) => {
    const intersects = (a, b) => a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1;
    return {
      exists: Boolean(element),
      role: element?.getAttribute("role"),
      label: element?.getAttribute("aria-label"),
      clientWidth: element?.clientWidth || 0,
      scrollWidth: element?.scrollWidth || 0,
      looseCards: [...(element?.children || [])].filter(child => child.classList.contains("node")).length,
      rows: [...(element?.querySelectorAll(".model-group") || [])].map(group => {
        const bounds = group.getBoundingClientRect();
        const cards = [...group.querySelectorAll(".node")].map(card => card.getBoundingClientRect());
        return {
          model: group.dataset.model || "",
          title: group.querySelector(".model-group-title span")?.textContent?.trim() || "",
          declared: group.querySelector(".model-group-title small")?.textContent?.trim() || "",
          count: cards.length,
          cardsInside: cards.every(card => card.left >= bounds.left - 1 && card.right <= bounds.right + 1),
          overlap: cards.some((card, index) => cards.slice(index + 1).some(other => intersects(card, other))),
          minimumWidth: cards.length ? Math.min(...cards.map(card => card.width)) : 0,
        };
      }),
    };
  })(document.querySelector("#nodes")),
  nodes: [...document.querySelectorAll("#nodes .node")].map(node => {
    const rect = node.getBoundingClientRect();
    const bounds = element => {
      const value = element?.getBoundingClientRect();
      return value && { top: value.top, bottom: value.bottom, left: value.left, right: value.right, width: value.width, height: value.height };
    };
    const textBounds = element => {
      if (!element) return null;
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
      const rectangles = [];
      while (walker.nextNode()) {
        const text = walker.currentNode;
        if (!String(text.textContent || "").trim() || text.parentElement?.closest(".sr-only,[aria-hidden='true'],[hidden]")) continue;
        const range = document.createRange();
        range.selectNodeContents(text);
        rectangles.push(...range.getClientRects());
      }
      const visible = rectangles.filter(rect => rect.width > 0 && rect.height > 0);
      if (!visible.length) return null;
      const left = Math.min(...visible.map(rect => rect.left));
      const right = Math.max(...visible.map(rect => rect.right));
      const top = Math.min(...visible.map(rect => rect.top));
      const bottom = Math.max(...visible.map(rect => rect.bottom));
      return { top, bottom, left, right, width: right - left, height: bottom - top };
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
    const mlnodesField = (() => {
      const value = node.querySelector('[data-k="mlnode"]');
      const row = node.querySelector('[data-k-row="mlnode"]');
      const rect = value?.getBoundingClientRect();
      const range = textBounds(value);
      const style = value && getComputedStyle(value);
      const visible = Boolean(value && row && !row.hidden && value.offsetParent !== null && rect && rect.width > 0 && rect.height > 0 && range && range.width > 0 && range.height > 0);
      const ellipsisContract = style?.overflowX === "hidden" && style?.textOverflow === "ellipsis" && style?.whiteSpace === "nowrap";
      const horizontalOverflow = Boolean(value && value.scrollWidth > value.clientWidth && !ellipsisContract);
      const verticalOverflow = Boolean(value && (value.scrollHeight > value.clientHeight || (row?.scrollHeight || 0) > (row?.clientHeight || 0)));
      const outsideBounds = Boolean(range && rect && (range.top < rect.top - 2 || range.bottom > rect.bottom + 2 || (!ellipsisContract && (range.left < rect.left - 2 || range.right > rect.right + 2))));
      return { text: value?.textContent?.trim(), visible, clipped: Boolean(!visible || horizontalOverflow || verticalOverflow || outsideBounds), truncated: Boolean(value && value.scrollWidth > value.clientWidth) };
    })();
    const statusField = textField("[data-k=status]");
    const hostField = textField("[data-k=host]");
    const statusTitle = node.querySelector("[data-k=status]")?.title || "";
    const details = node.querySelector(".node-details");
    const toggle = node.querySelector(".node-toggle");
    const rows = [node.querySelector("h3"), ...(details?.children || [])]
      .filter(row => row && row.offsetParent !== null)
      .map((row, index) => ({ key: index === 0 ? "heading" : row.dataset.kRow || row.dataset.k || row.tagName.toLowerCase(), ...rowInfo(row) }));
    const rowOverlapDetails = rows.flatMap((row, index) => rows.slice(index + 1).flatMap(other =>
      row.textBounds && other.textBounds &&
      row.textBounds.left < other.textBounds.right - 0.5 && other.textBounds.left < row.textBounds.right - 0.5 &&
      row.textBounds.top < other.textBounds.bottom - 0.5 && other.textBounds.top < row.textBounds.bottom - 0.5
        ? [{ from: row.key, to: other.key, first: row.textBounds, second: other.textBounds }]
        : []));
    const rowOverlap = rowOverlapDetails.length > 0;
    const contentBottom = rows.reduce((bottom, row) => Math.max(bottom, row.textBounds?.bottom ?? -Infinity), -Infinity);
    return {
      key: node.dataset.nodeKey,
      name: hostField.text,
      hostVisible: hostField.visible,
      hostClipped: hostField.clipped,
      expanded: node.classList.contains("is-expanded"),
      collapsed: node.classList.contains("is-collapsed"),
      toggleExpanded: toggle?.getAttribute("aria-expanded"),
      toggleControls: toggle?.getAttribute("aria-controls"),
      toggleLabel: toggle?.getAttribute("aria-label"),
      detailsId: details?.id,
      detailsHidden: Boolean(details?.hidden),
      status: statusField.text,
      statusVisible: statusField.visible,
      statusClipped: statusField.clipped,
      statusTitle,
      vp: node.querySelector("[data-k=vp]")?.textContent,
      sync: node.querySelector("[data-k=sync]")?.textContent,
      endpoint: node.querySelector("[data-k=endpoint]")?.textContent,
      inferenced: metric("inferenced"),
      dapi: metric("dapi"),
      devshard: metric("devshard"),
      mlnodes: mlnodesField,
      valueFields: ["height", "vp", "sync", "endpoint"].map(valueField),
      top: rect.top,
      bottom: rect.bottom,
      height: rect.height,
      clientHeight: node.clientHeight,
      scrollHeight: node.scrollHeight,
      rowOverlap,
      rowOverlapDetails,
      contentOverflowsCard: contentBottom > rect.bottom + 0.5,
    };
  }),
})`;
let socket;
let browser;
let sequence = 0;
let pageSessionId = '';
const pending = new Map();
const networkRequests = new Map();
const networkSockets = new Map();
const websocketSnapshots = [];
try {
  const chromeSession = await startChromeDevTools({
    chrome,
    profile,
    context: `homepage viewport ${width}x${height}`,
  });
  browser = chromeSession.browser;
  const version = await chromeSession.waitForEndpoint();
  socket = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.sessionId === pageSessionId && message.method === 'Network.requestWillBeSent') {
      networkRequests.set(message.params.requestId, {
        url: message.params.request.url,
        status: null,
        error: '',
      });
    }
    if (message.sessionId === pageSessionId && message.method === 'Network.responseReceived') {
      const request = networkRequests.get(message.params.requestId);
      if (request) request.status = message.params.response.status;
    }
    if (message.sessionId === pageSessionId && message.method === 'Network.loadingFailed') {
      const request = networkRequests.get(message.params.requestId);
      if (request) request.error = message.params.errorText || 'network request failed';
      const socketRequest = networkSockets.get(message.params.requestId);
      if (socketRequest) socketRequest.error = message.params.errorText || 'websocket handshake failed';
    }
    if (message.sessionId === pageSessionId && message.method === 'Network.webSocketCreated') {
      networkSockets.set(message.params.requestId, {
        url: message.params.url,
        status: null,
        error: '',
      });
    }
    if (message.sessionId === pageSessionId && message.method === 'Network.webSocketHandshakeResponseReceived') {
      const request = networkSockets.get(message.params.requestId);
      if (request) request.status = message.params.response.status;
    }
    if (message.sessionId === pageSessionId && message.method === 'Network.webSocketFrameReceived') {
      const request = networkSockets.get(message.params.requestId);
      if (!request) return;
      try {
        const frame = JSON.parse(message.params.response.payloadData || '');
        const snapshot = frame?.type === 'network_snapshot' ? frame.snapshot : null;
        if (snapshot && Array.isArray(snapshot.nodes)) {
          websocketSnapshots.push({
            url: request.url,
            status: request.status,
            schema_version: snapshot.schema_version,
            chain_id: snapshot.chain_id || '',
            chain_state: snapshot.chain?.state || '',
            epoch: String(snapshot.chain?.activity?.epoch?.latest_epoch?.index || ''),
            node_count: snapshot.nodes.length,
            node_ids: snapshot.nodes.map(node => String(node?.node_id || '').trim().toUpperCase()),
          });
        }
      } catch {}
    }
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
  pageSessionId = sessionId;
  await call('Page.enable', {}, sessionId);
  await call('Network.enable', {}, sessionId);
  await call('Network.setCacheDisabled', { cacheDisabled: true }, sessionId);
  await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: true }, sessionId);
  await call('Emulation.setVisibleSize', { width, height }, sessionId);
  await call('Page.navigate', { url }, sessionId);
  const gatewayStateReadyExpression = '["observed","unavailable"].includes(document.querySelector("#gateway-traffic")?.dataset.state || "")';
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const { result } = await call('Runtime.evaluate', {
      expression: `Boolean(document.querySelector("#updated")?.dateTime && /^Updated .* UTC$/.test(document.querySelector("#updated")?.textContent || "") && document.querySelector("#validator-map .validator-map-world")?.complete && document.querySelector("#validator-map .validator-map-world")?.naturalWidth && ${gatewayStateReadyExpression})`,
      returnByValue: true,
    }, sessionId);
    if (result.value) break;
    if (attempt === 29) throw new Error('homepage status, gateway traffic, and validator map refresh did not complete within 30 seconds');
    await delay(1000);
  }
  const { result } = await call('Runtime.evaluate', {
    expression: homepageStateExpression,
    returnByValue: true,
  }, sessionId);
  const state = JSON.parse(result.value);
  let networkSnapshotHttp = null;
  let hasEmbeddedChainSnapshot = false;
  if (expectedStatusPrefix) {
    const networkPath = `${expectedStatusPrefix}network`;
    const { result: networkIdentityResult } = await call('Runtime.evaluate', {
      expression: `fetch(${JSON.stringify(networkPath)}, { cache: 'no-store' }).then(async response => { let payload = null; try { payload = await response.json(); } catch {} return JSON.stringify({ status: response.status, payload, nodeIds: (Array.isArray(payload?.nodes) ? payload.nodes : []).map(node => String(node?.node_id || '').trim().toUpperCase()) }); })`,
      awaitPromise: true,
      returnByValue: true,
    }, sessionId);
    const networkIdentity = JSON.parse(networkIdentityResult.value || '{}');
    networkSnapshotHttp = networkIdentity;
    hasEmbeddedChainSnapshot = Object.hasOwn(networkIdentity.payload || {}, 'chain');
    const identityComparison = compareHostIdentitySets(
      networkIdentity.nodeIds,
      state.nodes.map(node => node.key),
    );
    state.p2pNodeIds = identityComparison.expected;
    state.renderedNodeIds = identityComparison.rendered;
    if (networkIdentity.status !== 200 || !identityComparison.matches) {
      throw new Error(`rendered Host identities do not match current preview P2P observations ${JSON.stringify({ status: networkIdentity.status, ...identityComparison })}`);
    }
    if (expectNetworkSnapshot) {
      const payload = networkIdentity.payload;
      const chainId = String(payload?.chain_id || '');
      const chain = payload?.chain;
      const epoch = chain?.activity?.epoch?.latest_epoch || {};
      const epochIndex = String(epoch.index || '');
      const stageHeight = Number(epoch.poc_start_block_height);
      const endHeight = Number(epoch.end_height);
      const referenceHeight = Number(chain?.reference?.height);
      const chainObservedAt = Date.parse(String(chain?.observed_at || ''));
      const chainAgeMs = Date.now() - chainObservedAt;
      const chainMismatches = (Array.isArray(payload?.nodes) ? payload.nodes : [])
        .filter(node => node?.components?.chain_rpc?.state === 'observed' && node.components.chain_rpc.chain_id !== chainId)
        .map(node => ({ node_id: node.node_id || '', chain_id: node.components.chain_rpc.chain_id || '' }));
      if (payload?.schema_version !== 1 || !chainId || chainId !== state.configuredChainId || (chain?.chain_id && chain.chain_id !== chainId) || chain?.state !== 'observed' ||
          !Number.isFinite(chainAgeMs) || chainAgeMs < 0 || chainAgeMs > 90000 ||
          !/^[1-9]\d*$/.test(epochIndex) || !Number.isSafeInteger(stageHeight) || !Number.isSafeInteger(endHeight) ||
          !Number.isSafeInteger(referenceHeight) || stageHeight <= 0 || endHeight <= stageHeight || referenceHeight < stageHeight ||
          chainMismatches.length) {
        throw new Error(`live HTTP network snapshot does not provide a matching fresh chain ${JSON.stringify({ status: networkIdentity.status, schema_version: payload?.schema_version, chain_id: chainId, configured_chain_id: state.configuredChainId, chain_state: chain?.state, chain_age_ms: chainAgeMs, chain_mismatches: chainMismatches, epoch: epochIndex, stage_height: stageHeight, end_height: endHeight, reference_height: referenceHeight })}`);
      }
      const isNetworkSocket = request => {
        try { return new URL(request.url).pathname === `${expectedStatusPrefix}network/ws`; }
        catch { return false; }
      };
      const matchingNetworkSockets = () => [...networkSockets.values()].filter(isNetworkSocket);
      const matchingSocketSnapshot = () => websocketSnapshots.find(snapshot => isNetworkSocket(snapshot) && snapshot.schema_version === 1 && snapshot.chain_id === chainId && snapshot.chain_state === 'observed' && snapshot.epoch === epochIndex);
      for (let attempt = 0; attempt < 50; attempt += 1) {
        const rejectedSocket = matchingNetworkSockets().find(request => [401, 404].includes(Number(request.status)));
        if (rejectedSocket) throw new Error(`network WebSocket was rejected ${JSON.stringify(rejectedSocket)}`);
        if (matchingNetworkSockets().some(request => request.status === 101 && !request.error) && matchingSocketSnapshot()) break;
        if (attempt === 49) throw new Error(`network WebSocket did not deliver a matching network snapshot ${JSON.stringify({ sockets: [...networkSockets.values()], snapshots: websocketSnapshots, expected_chain_id: chainId, expected_epoch: epochIndex })}`);
        await delay(200);
      }
      const wsSnapshot = matchingSocketSnapshot();
      const websocketIdentityComparison = compareHostIdentitySets(networkIdentity.nodeIds, wsSnapshot?.node_ids);
      if (!wsSnapshot || wsSnapshot.status !== 101 || !websocketIdentityComparison.matches || !matchingNetworkSockets().some(request => request.status === 101 && !request.error)) {
        throw new Error(`network WebSocket receipt did not match the HTTP chain snapshot ${JSON.stringify({ sockets: [...networkSockets.values()], snapshots: websocketSnapshots, expected_chain_id: chainId, expected_epoch: epochIndex })}`);
      }
      state.networkSnapshot = {
        http: { status: networkIdentity.status, schema_version: payload.schema_version, chain_id: chainId, epoch: epochIndex, node_count: payload.nodes.length },
        websocket: wsSnapshot,
      };
    }
  }
  const { result: appDigestResult } = await call('Runtime.evaluate', {
    expression: '(async()=>{const script=[...document.scripts].find(item=>new URL(item.src,location.href).pathname.endsWith("/app.js"));if(!script)return"";const bytes=await fetch(script.src,{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error(`app.js fetch failed ${response.status}`);return response.arrayBuffer()});const digest=await crypto.subtle.digest("SHA-256",bytes);return [...new Uint8Array(digest)].map(byte=>byte.toString(16).padStart(2,"0")).join("")})()',
    awaitPromise: true,
    returnByValue: true,
  }, sessionId);
  state.loadedAppDigest = appDigestResult.value;
  const layoutWidthDelta = state.width - width;
  const layoutHeightDelta = state.height - height;
  if (
    Math.abs(state.visualWidth - width) > 0.5 ||
    Math.abs(state.visualHeight - height) > 0.5 ||
    layoutWidthDelta < 0 ||
    layoutWidthDelta > 16 ||
    layoutHeightDelta < 0 ||
    layoutHeightDelta > 16
  ) {
    const layoutMetrics = await call('Page.getLayoutMetrics', {}, sessionId);
    throw new Error(
      `emulation mismatch layout=${state.width}x${state.height} visual=${state.visualWidth}x${state.visualHeight} ${JSON.stringify(layoutMetrics)}`,
    );
  }
  if (expectedSiteRevision && state.siteRevision !== expectedSiteRevision) throw new Error(`preview revision mismatch ${JSON.stringify(state)}`);
  if (expectedAppDigest && (state.loadedAppDigest !== expectedAppDigest || state.appDigest !== expectedAppDigest)) throw new Error(`preview app digest mismatch ${JSON.stringify(state)}`);
  if (expectedGithubHref && state.footerGithub.href !== expectedGithubHref) throw new Error(`preview GitHub footer link mismatch ${JSON.stringify(state.footerGithub)}`);
  const statusRequests = [...networkRequests.values()].filter(request => {
    try {
      return new URL(request.url).pathname.startsWith(expectedStatusPrefix);
    } catch {
      return false;
    }
  });
  if (expectedStatusPrefix && !statusRequests.length) {
    throw new Error(`homepage did not request preview status endpoints ${expectedStatusPrefix}`);
  }
  if (expectedStatusPrefix) {
    const pageOrigin = new URL(url).origin;
    const escapedGeneration = [...networkRequests.values()].filter(request => {
      try {
        const requestUrl = new URL(request.url);
        return requestUrl.origin === pageOrigin && requestUrl.pathname.startsWith("/status/") && !requestUrl.pathname.startsWith(expectedStatusPrefix);
      } catch {
        return false;
      }
    });
    if (escapedGeneration.length) {
      throw new Error(`preview request escaped generation status prefix ${JSON.stringify(escapedGeneration)}`);
    }
    // The embedded chain snapshot replaces these inventory reads in snapshot
    // mode. The gateway remains an independent shared contract; a Host-local
    // unavailable component is rendered as a bounded card diagnostic.
    const requiredPaths = [
      ...(hasEmbeddedChainSnapshot ? [] : ["participants", "gpus", "software"]),
      ...(state.publicBootstrap ? [] : ["gateway-traffic"]),
    ].map(path => `${expectedStatusPrefix}${path}`);
    const expectedPreviewGatewayUnavailable = expectedGatewayState === 'UNAVAILABLE' && !state.publicBootstrap;
    const requiredFailures = requiredPaths.flatMap(path => {
      const requests = statusRequests.filter(request => {
        try {
          return new URL(request.url).pathname === path;
        } catch {
          return false;
        }
      });
      const isGatewayPath = path.endsWith('/gateway-traffic');
      const expected503 = expectedPreviewGatewayUnavailable && isGatewayPath;
      return !requests.length || requests.some(request => request.error || (expected503
        ? Number(request.status) !== 503
        : Number(request.status) >= 400))
        ? [{ path, requests }]
        : [];
    });
    if (requiredFailures.length) {
      throw new Error(`preview shared status request failed ${JSON.stringify(requiredFailures)}`);
    }
  }
  if (expectedCardCount && state.nodes.length !== expectedCardCount) {
    throw new Error(`homepage rendered ${state.nodes.length}/${expectedCardCount} required Host cards`);
  }
  if (state.mapMarkerDetails.some(marker => marker.width < 12 || marker.height < 12 || marker.width > 36 || marker.height > 36 || marker.filter !== 'none')) throw new Error(`validator marker geometry or halo contract failed ${JSON.stringify(state.mapMarkerDetails)}`);
  if (state.scrollWidth > state.width) throw new Error(`horizontal overflow ${state.scrollWidth}>${state.width}`);
  if ((!expectResetState && state.nodes.length < 1) || state.updatedTag !== 'TIME' || !/^Updated .* UTC$/.test(state.updated || '') || !/^\d{4}-\d{2}-\d{2}T/.test(state.updatedDateTime || '') || !state.mapWorld) throw new Error(`homepage status or validator map did not render ${JSON.stringify(state)}`);
  if (state.removedSections.length) throw new Error(`homepage still renders removed sections ${JSON.stringify(state.removedSections)}`);
  const mappedNodes = state.nodes;
  if (!expectResetState && state.mapHosts > mappedNodes.length) throw new Error(`network node map has more geographic Hosts than live participant cards ${JSON.stringify({ mapHosts: state.mapHosts, cards: mappedNodes.length })}`);
  if (state.mapPoints !== state.mapMarkers) throw new Error(`validator map rendered ${state.mapPoints} visible points for ${state.mapMarkers} geographic groups ${JSON.stringify(state)}`);
  if (!expectResetState && (state.mapMarkerDetails.reduce((total, marker) => total + marker.count, 0) !== state.mapHosts || state.mapMarkerDetails.some(marker => !Number.isInteger(marker.count) || marker.count < 1 || !Number.isInteger(marker.gpuCount) || marker.gpuCount < 0 || !Number.isFinite(marker.radius) || Math.abs(marker.radius - (marker.gpuCount <= 1 ? 6 : Math.min(7.5 * Math.sqrt(marker.gpuCount), 18))) > 0.1))) throw new Error(`network node map grouping or GPU-radius contract failed ${JSON.stringify(state.mapMarkerDetails)}`);
  if (mappedNodes.filter(node => node.expanded).some(node => [node.inferenced, node.dapi, node.devshard, node.mlnodes].some(field => !field.visible || !field.text || field.text === 'Checking…' || field.clipped))) throw new Error(`participant runtime inventory is incomplete ${JSON.stringify(state)}`);
  if (hasEmbeddedChainSnapshot) {
    const chain = networkSnapshotHttp.payload.chain;
    const observedAt = Date.parse(String(chain?.observed_at || ''));
    const age = Date.now() - observedAt;
    const fresh = chain?.state === 'observed' && Number.isFinite(age) && age >= 0 && age <= 90000;
    const approvals = Array.isArray(chain?.approved_devshards) ? chain.approved_devshards : [];
    const expectedText = !fresh ? 'Unavailable' : approvals.length ? approvals.map(item => String(item?.name || '').trim() + ' ' + String(item?.sha256 || '').trim().toLowerCase().slice(0, 6)).join('') : 'None approved';
    const expectedTitle = !fresh ? 'Approved DevShard versions could not be read from verified chain state' : approvals.length
      ? approvals.map(item => `${String(item?.name || '').trim()}: ${String(item?.sha256 || '').trim().toLowerCase()}`).join('\n')
      : 'Chain state reports no approved DevShard versions';
    if (state.devshardVersions.text !== expectedText || state.devshardVersions.title !== expectedTitle) {
      throw new Error(`approved DevShard versions did not match the HTTP network snapshot ${JSON.stringify({ rendered: state.devshardVersions, expectedText, expectedTitle })}`);
    }
    const directChainRequests = [...networkRequests.values()].filter(request => {
      try { return /\/chain-api\/productscience\/inference\/inference\//.test(new URL(request.url).pathname); }
      catch { return false; }
    });
    if (expectNetworkSnapshot && directChainRequests.length) {
      throw new Error(`snapshot acceptance unexpectedly made direct per-Host chain API requests ${JSON.stringify(directChainRequests)}`);
    }
  } else {
    const approvalRequest = [...networkRequests.values()].find(request => {
      try { return new URL(request.url).pathname.endsWith('/chain-api/productscience/inference/inference/devshard_approved_versions'); }
      catch { return false; }
    });
    if (!approvalRequest) throw new Error('legacy homepage did not request the dedicated current DevShard approvals query');
    const { result: approvalReadResult } = await call('Runtime.evaluate', {
      expression: `fetch(${JSON.stringify(approvalRequest.url)}, { cache: 'no-store' }).then(async response => { let payload = null; try { payload = await response.json(); } catch {} const records = payload?.versions; const seen = new Set(); let versions = []; let valid = response.ok && Array.isArray(records); if (valid) { for (const item of records) { const name = String(item?.name || '').trim(); const binary = String(item?.binary || '').trim(); const sha256 = String(item?.sha256 || '').trim().toLowerCase(); if (!/^v[0-9][A-Za-z0-9._-]*$/.test(name) || !binary || !/^[0-9a-f]{64}$/.test(sha256) || seen.has(name)) { valid = false; break; } seen.add(name); versions.push({ name, sha256 }); } } versions.sort((left, right) => left.name.localeCompare(right.name, undefined, { numeric: true })); return JSON.stringify({ expectedText: !valid ? 'Unavailable' : versions.length ? versions.map(item => item.name + ' ' + item.sha256.slice(0, 6)).join('') : 'None approved', expectedTitle: !valid ? 'Approved DevShard versions could not be read from verified chain state' : versions.length ? versions.map(item => item.name + ': ' + item.sha256).join('\\n') : 'Chain state reports no approved DevShard versions', status: response.status }); }).catch(() => JSON.stringify({ expectedText: 'Unavailable', expectedTitle: 'Approved DevShard versions could not be read from verified chain state', status: 0 }))`,
      awaitPromise: true,
      returnByValue: true,
    }, sessionId);
    const approvalRead = JSON.parse(approvalReadResult.value || '{}');
    if (state.devshardVersions.text !== approvalRead.expectedText || state.devshardVersions.title !== approvalRead.expectedTitle) throw new Error(`approved DevShard versions did not match a fresh dedicated chain query (HTTP ${approvalRead.status}) ${JSON.stringify({ rendered: state.devshardVersions, expectedText: approvalRead.expectedText, expectedTitle: approvalRead.expectedTitle })}`);
  }
  const hasUnboundedHostDiagnostic = node => {
    const endpoint = node.endpoint || '';
    return /Failed to fetch|timeout|dns/i.test(`${node.status} ${endpoint}`)
      || (/\b[45]\d\d\b/.test(endpoint) && !/^Unavailable – HTTP [45]\d\d$/.test(endpoint));
  };
  if (mappedNodes.some(node => !node.key || !node.name || !node.hostVisible || !node.status || !node.statusVisible || !node.toggleControls || node.toggleControls !== node.detailsId || !node.toggleLabel?.includes(node.name) || hasUnboundedHostDiagnostic(node))) throw new Error(`Host-card identity contract failed ${JSON.stringify(mappedNodes)}`);
  if (mappedNodes.some(node => !node.expanded || node.collapsed || node.toggleExpanded !== 'true' || node.detailsHidden || node.hostClipped || node.statusClipped || node.scrollHeight > node.clientHeight || node.rowOverlap || node.contentOverflowsCard || !node.statusTitle || node.valueFields.some(field => !field.text || !field.visible || field.clipped) || [node.inferenced, node.dapi, node.devshard, node.mlnodes].some(field => !field.visible || !field.text || field.clipped))) throw new Error(`Host card contract failed ${JSON.stringify(mappedNodes)}`);
  const deck = state.nodeDeck;
  const rowsValid = deck.rows.every(row => row.model && row.title === row.model && row.count >= 1 && row.declared === `${row.count} host${row.count === 1 ? '' : 's'}` && row.cardsInside && !row.overlap && row.minimumWidth >= Math.min(300, deck.clientWidth - 2));
  if (!deck.exists || deck.role !== 'list' || !deck.label?.includes('Hosts by model') || deck.scrollWidth > deck.clientWidth + 1 || deck.looseCards !== 0 || !rowsValid || deck.rows.reduce((total, row) => total + row.count, 0) !== mappedNodes.length || new Set(deck.rows.map(row => row.model)).size !== deck.rows.length) throw new Error(`Host model rows layout contract failed ${JSON.stringify(deck)}`);
  for (const expected of expectedNodeStates) {
    const node = mappedNodes.find(item => item.name === expected.name);
    if (!node || node.status !== expected.state) {
      throw new Error(`Host state does not match expected ${expected.name}=${expected.state}: ${JSON.stringify(mappedNodes)}`);
    }
  }
  if (expectResetState) {
    const active = state.nodes;
    if (active.some(node => !/^offline \(\d+\)$/.test(node.status || '')) || state.bestHeight !== '–' || state.mapHosts !== 0 || state.mapMarkers !== 0 || state.mapPoints !== 0) {
      throw new Error(`homepage does not show the real reset/offline state ${JSON.stringify(state)}`);
    }
  }
  if (checkMapFullscreen) {
    await call('Runtime.evaluate', { expression: 'document.querySelector("#validator-map-fullscreen")?.click()' }, sessionId);
    let fullscreen;
    for (let attempt = 0; attempt < 50; attempt += 1) {
      const { result: fullscreenResult } = await call('Runtime.evaluate', { expression: `JSON.stringify({coverage:${mapCoverageExpression},rect:(()=>{const r=document.querySelector("#validator-map")?.getBoundingClientRect();return r&&{left:r.left,top:r.top,right:r.right,bottom:r.bottom}})(),pressed:document.querySelector("#validator-map-fullscreen")?.getAttribute("aria-pressed")})`, returnByValue: true }, sessionId);
      fullscreen = JSON.parse(fullscreenResult.value);
      const coverage = JSON.parse(fullscreen.coverage);
      if (coverage?.worldLoaded && coverage.worldFits && coverage.markersVisible && fullscreen.pressed === 'true' && fullscreen.rect.left <= 1 && fullscreen.rect.top <= 1 && fullscreen.rect.right >= width - 1 && fullscreen.rect.bottom >= height - 1) break;
      if (attempt === 49) throw new Error(`validator map does not cover fullscreen viewport ${JSON.stringify(fullscreen)}`);
      await delay(100);
    }
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, sessionId);
    await call('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 }, sessionId);
    let fullscreenExit;
    for (let attempt = 0; attempt < 20; attempt += 1) {
      const { result: fullscreenExitResult } = await call('Runtime.evaluate', { expression: 'JSON.stringify({pressed:document.querySelector("#validator-map-fullscreen")?.getAttribute("aria-pressed"),active:document.querySelector("#validator-map-shell")?.classList.contains("is-fullscreen")})', returnByValue: true }, sessionId);
      fullscreenExit = JSON.parse(fullscreenExitResult.value);
      if (fullscreenExit.pressed === 'false' && !fullscreenExit.active) break;
      if (attempt === 19) throw new Error(`validator map did not exit fullscreen ${JSON.stringify(fullscreenExit)}`);
      await delay(100);
    }
  }
  const { result: grafanaResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify(["grafana-overview","grafana-network","grafana-inference","grafana-chain","grafana-components"].map(id=>{const e=document.getElementById(id);return {id,href:e?.href,target:e?.target}}))',
    returnByValue: true,
  }, sessionId);
  const grafana = JSON.parse(grafanaResult.value);
  const expectedGrafanaPaths = ["/d/gdc-overview/", "/d/gdc-network/", "/d/gdc-inference/", "/d/gdc-chain/", "/d/gdc-components/"];
  if (grafana.length !== 5 || grafana.some((link,index)=>{const url=new URL(link.href);return url.hostname!=="grafana.gonka-dev.net"||!url.pathname.startsWith(expectedGrafanaPaths[index])||!url.searchParams.has("kiosk")||link.target!=="_blank"})) throw new Error(`invalid public Grafana links ${JSON.stringify(grafana)}`);
  const traffic = state.traffic;
  const trafficCardsValid = traffic.cards.every(card => /^Gateway \S/.test(card.name) && /^\d+\.\d$/.test(card.rps) && card.values.length === 4 && card.values.every(Boolean));
  if (!['observed', 'unavailable'].includes(traffic.state)) throw new Error(`gateway traffic block did not settle ${JSON.stringify(traffic)}`);
  if (traffic.state === 'observed' && (!/^\d+\.\d req\/s$/.test(traffic.total) || !trafficCardsValid)) throw new Error(`gateway traffic contract failed ${JSON.stringify(traffic)}`);
  if (traffic.state === 'unavailable' && (traffic.total !== '–' || traffic.cards.length)) throw new Error(`unavailable gateway traffic must not show numbers ${JSON.stringify(traffic)}`);
  if (expectedGatewayState === 'UNAVAILABLE' && traffic.state !== 'unavailable') throw new Error(`gateway traffic ${traffic.state} does not match expected unavailable`);
  if (expectGatewayReady && (traffic.state !== 'observed' || !traffic.cards.length)) {
    throw new Error(`public page shows no gateway traffic ${JSON.stringify(traffic)}`);
  }
  const { result: typeResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({prose:Number.parseFloat(getComputedStyle(document.querySelector(".hero p")).fontSize),footerSize:Number.parseFloat(getComputedStyle(document.querySelector("footer")).fontSize),bodyFont:getComputedStyle(document.body).fontFamily,footerChildren:[...document.querySelector("footer").children].map(e=>{const r=e.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom}})})',
    returnByValue: true,
  }, sessionId);
  const typography = JSON.parse(typeResult.value);
  const footerOverlap = typography.footerChildren.some((box, index, boxes) => boxes.slice(index + 1).some(other => box.left < other.right && other.left < box.right && box.top < other.bottom && other.top < box.bottom));
  if (typography.prose < 16 || typography.footerSize < 13 || !/Inter/.test(typography.bodyFont) || footerOverlap) throw new Error(`unreadable typography contract ${JSON.stringify(typography)}`);
  await call('Runtime.evaluate', { expression: 'document.querySelector("#nodes")?.scrollIntoView({block:"start",behavior:"instant"})' }, sessionId);
  await delay(300);
  const { result: nodeViewportResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({height:innerHeight,nodes:[...document.querySelectorAll("#nodes .node")].map(n=>{const r=n.getBoundingClientRect();return {top:r.top,bottom:r.bottom}})})',
    returnByValue: true,
  }, sessionId);
  const nodeViewport = JSON.parse(nodeViewportResult.value);
  const visible = nodeViewport.nodes.filter(node => node.top >= 0 && node.bottom <= nodeViewport.height).length;
  if (visible < visibleNodes) throw new Error(`only ${visible}/${visibleNodes} required node cards are visible after scrolling to participant status`);
  await call('Runtime.evaluate', { expression: `window.scrollTo({ top: ${screenshotScroll}, left: 0, behavior: 'instant' })` }, sessionId);
  await delay(150);
  const { result: screenshotScrollResult } = await call('Runtime.evaluate', {
    expression: 'JSON.stringify({x:scrollX,y:scrollY})',
    returnByValue: true,
  }, sessionId);
  const screenshotPosition = JSON.parse(screenshotScrollResult.value);
  if (screenshotPosition.x !== 0 || screenshotPosition.y !== screenshotScroll) {
    throw new Error(`homepage did not reach requested screenshot scroll position ${JSON.stringify({ requested: { x: 0, y: screenshotScroll }, actual: screenshotPosition })}`);
  }
  const screenshot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }, sessionId);
  const screenshotBytes = Buffer.from(screenshot.data, 'base64');
  const pngSignature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (screenshotBytes.length < 24 || !screenshotBytes.subarray(0, 8).equals(pngSignature)) throw new Error('homepage screenshot is not a PNG');
  if (screenshotBytes.readUInt32BE(8) !== 13 || screenshotBytes.toString('ascii', 12, 16) !== 'IHDR') throw new Error('homepage screenshot has an invalid PNG IHDR');
  const screenshotWidth = screenshotBytes.readUInt32BE(16);
  const screenshotHeight = screenshotBytes.readUInt32BE(20);
  if (screenshotWidth !== width || screenshotHeight !== height) throw new Error(`homepage screenshot dimensions ${screenshotWidth}x${screenshotHeight} do not match ${width}x${height}`);
  await writeFile(output, screenshotBytes);
  await writeFile(`${output}.json`, JSON.stringify({
    schema_version: 1,
    url,
    screenshot: output,
    revision: state.siteRevision,
    app_digest: state.appDigest,
    footer_github: state.footerGithub,
    expected_status_prefix: expectedStatusPrefix || null,
    screenshot_scroll: screenshotPosition,
    network_snapshot: state.networkSnapshot || null,
    map: {
      hosts: state.mapHosts,
      currentValidators: state.currentValidatorCount,
      validatorHeight: state.validatorHeight,
      groups: state.mapMarkers,
      markers: state.mapMarkerDetails,
    },
    status_requests: statusRequests,
    nodes: state.nodes.map(node => ({
      name: node.name,
      status: node.status,
      inferenced: node.inferenced.text,
      dapi: node.dapi.text,
      devshard: node.devshard.text,
      mlnodes: node.mlnodes.text,
      height: node.height,
    })),
  }, null, 2) + '\n');
} finally {
  socket?.close();
  await stopChromeDevTools(browser);
  await rm(profile, { recursive: true, force: true });
}
