import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { startChromeDevTools, stopChromeDevTools } from '../../net-deployment-runbook/scripts/chrome-devtools.mjs';

const url = process.env.TRACE_PAGE_URL || 'http://127.0.0.1:8097/trace/index.html';
const output = resolve(process.env.TRACE_PAGE_EVIDENCE || '.cache/page');
await mkdir(output, { recursive: true });
const profile = await mkdtemp(join(output, 'chrome-'));
const browser = await startChromeDevTools({ profile, context: 'trace landing page' });
let socket;
try {
  await browser.waitForEndpoint();
  const pages = await (await fetch(`http://127.0.0.1:${browser.port}/json/list`)).json();
  socket = new WebSocket(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let id = 0;
  const pending = new Map();
  const errors = [];
  socket.onmessage = ({ data }) => {
    const response = JSON.parse(data);
    if (response.method === 'Runtime.exceptionThrown') errors.push(response.params.exceptionDetails);
    const callback = pending.get(response.id);
    if (callback) { pending.delete(response.id); response.error ? callback.reject(response.error) : callback.resolve(response.result); }
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const request = ++id;
    pending.set(request, { resolve, reject });
    socket.send(JSON.stringify({ id: request, method, params }));
  });
  const evaluate = async expression => {
    const response = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true, userGesture: true });
    assert.equal(response.exceptionDetails, undefined, JSON.stringify(response.exceptionDetails));
    return response.result.value;
  };
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Emulation.setFocusEmulationEnabled', { enabled: true });
  await send('Browser.grantPermissions', { origin: new URL(url).origin, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] });
  const results = [];
  for (const width of [360, 1280]) {
    await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: width === 360 });
    await send('Page.navigate', { url });
    for (let attempt = 0; attempt < 100; attempt++) {
      if (await evaluate('document.readyState === "complete" && Boolean(document.querySelector("#copy"))')) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    const state = await evaluate(`({ title: document.title, width: innerWidth, scrollWidth: document.documentElement.scrollWidth,
      downloads: document.querySelectorAll('tbody a').length, cssRules: document.styleSheets[0].cssRules.length,
      featureColumns: getComputedStyle(document.querySelector('.features')).gridTemplateColumns.split(' ').length })`);
    assert.equal(state.width, width);
    assert.ok(state.scrollWidth <= width, JSON.stringify(state));
    assert.equal(state.downloads, 5);
    assert.ok(state.cssRules > 10);
    assert.equal(state.featureColumns, width === 360 ? 1 : 3);
    await evaluate('document.querySelector("#copy").click()');
    for (let attempt = 0; attempt < 50; attempt++) {
      if (await evaluate('document.querySelector("#copy-status").textContent === "Command copied."')) break;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.equal(await evaluate('navigator.clipboard.readText()'), 'curl -LsSf https://gonka-dev.net/trace/install.sh | sh');
    const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
    await writeFile(join(output, `trace-${width}.png`), Buffer.from(shot.data, 'base64'));
    await evaluate(`Object.defineProperty(navigator, 'clipboard', { value: { writeText: async () => { throw new Error('denied'); } }, configurable: true }); document.querySelector('#copy').click()`);
    assert.equal(await evaluate('window.getSelection().toString()'), 'curl -LsSf https://gonka-dev.net/trace/install.sh | sh');
    results.push(state);
  }
  assert.deepEqual(errors, []);
  await writeFile(join(output, 'results.json'), JSON.stringify(results, null, 2) + '\n');
  console.log('PASS responsive layout, five downloads, clipboard and selection fallback at 360/1280px');
} finally {
  socket?.close();
  await stopChromeDevTools(browser.browser);
}
