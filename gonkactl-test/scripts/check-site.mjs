import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { startChromeDevTools, stopChromeDevTools } from '../../net-deployment-runbook/scripts/chrome-devtools.mjs';

const [base = 'http://127.0.0.1:8187', evidence = '../build/gonkactl-test-site'] = process.argv.slice(2);
await mkdir(evidence, { recursive: true });
const profile = await mkdtemp(join(evidence, 'chrome-'));
let browser, socket;
try {
  const page = await fetch(`${base}/test`, { signal: AbortSignal.timeout(10000) });
  assert.equal(page.status, 200);
  assert.match(await page.text(), /gonkactl-test/);
  const installer = await fetch(`${base}/test/install.sh`, { signal: AbortSignal.timeout(10000) });
  assert.equal(installer.status, 200);
  assert.match(installer.headers.get('content-type'), /text\/plain|application\/x-sh/);
  assert.match(await installer.text(), /^#!\/bin\/sh/);
  const chrome = await startChromeDevTools({ profile, context: 'gonkactl-test landing' });
  browser = chrome.browser;
  const endpoint = await chrome.waitForEndpoint();
  socket = new WebSocket(endpoint.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let serial = 0;
  const waiting = new Map();
  socket.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    const request = waiting.get(message.id);
    if (!request) return;
    clearTimeout(request.timer);
    waiting.delete(message.id);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  };
  const call = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => { waiting.delete(id); reject(new Error(`${method} timed out`)); }, 10000);
    waiting.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params, sessionId }));
  });
  const { targetId } = await call('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await call('Target.attachToTarget', { targetId, flatten: true });
  await call('Page.enable', {}, sessionId);
  await call('Browser.grantPermissions', { origin: base, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] });
  const receipts = [];
  for (const width of [375, 768, 1440]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
    await call('Page.navigate', { url: `${base}/test/` }, sessionId);
    let ready = false;
    for (let count = 0; count < 50; count++) {
      const state = await call('Runtime.evaluate', { expression: 'document.readyState', returnByValue: true }, sessionId);
      if (state.result.value === 'complete') { ready = true; break; }
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.ok(ready, 'page did not finish loading');
    const state = await call('Runtime.evaluate', { expression: `({width:innerWidth, scrollWidth:document.documentElement.scrollWidth, title:document.querySelector('h1').textContent, downloads:document.querySelectorAll('.downloads a').length})`, returnByValue: true }, sessionId);
    assert.equal(state.result.value.title, 'gonkactl-test');
    assert.equal(state.result.value.downloads, 5);
    assert.ok(state.result.value.scrollWidth <= width, 'horizontal overflow');
    await call('Runtime.evaluate', { expression: "document.querySelector('#copy-command').click()", userGesture: true }, sessionId);
    const copied = await call('Runtime.evaluate', { expression: 'navigator.clipboard.readText()', awaitPromise: true, returnByValue: true }, sessionId);
    assert.equal(copied.result.value, 'curl -LsSf https://gonka-dev.net/test/install.sh | sh');
    const screenshot = await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false }, sessionId);
    await writeFile(join(evidence, `test-${width}.png`), Buffer.from(screenshot.data, 'base64'));
    receipts.push({ ...state.result.value, clipboard: 'pass' });
  }
  await writeFile(join(evidence, 'browser.json'), JSON.stringify({ base, installerContentType: installer.headers.get('content-type'), viewports: receipts }, null, 2) + '\n');
  console.log('PASS: /test, installer MIME, three viewports and clipboard');
} finally {
  socket?.close();
  await stopChromeDevTools(browser);
  await rm(profile, { recursive: true, force: true });
}
