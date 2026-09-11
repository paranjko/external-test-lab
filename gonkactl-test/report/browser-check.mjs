#!/usr/bin/env node
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:net";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const READY_MS = 30_000;
const REQUEST_MS = 10_000;
const SOCKET_MS = 10_000;
const DOM_MS = 30_000;
const STDERR_LIMIT = 64 * 1024;
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const exited = (child) => child.exitCode !== null || child.signalCode !== null;

function args() {
  const values = {};
  for (let i = 2; i < process.argv.length; i += 1) {
    const key = process.argv[i];
    if (!key.startsWith("--")) throw new Error(`unexpected argument ${key}`);
    if (key === "--probe" || key === "--ignore-certificate-errors") values[key.slice(2)] = true;
    else values[key.slice(2)] = process.argv[++i];
  }
  if (!values["evidence-dir"] || !values.profile) throw new Error("--evidence-dir and --profile are required");
  if (!values.probe && (!values.url || !values.bundle)) throw new Error("--url and --bundle are required outside probe mode");
  return values;
}

async function port() {
  return new Promise((resolve, reject) => {
    const server = createServer().once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => error ? reject(error) : resolve(address.port));
    });
  });
}

async function fetchDeadline(url, options = {}) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(REQUEST_MS) });
}

async function closeChild(child) {
  if (exited(child)) return "already-exited";
  child.kill("SIGTERM");
  const closed = await Promise.race([
    new Promise((resolve) => child.once("close", () => resolve(true))),
    delay(5_000).then(() => false),
  ]);
  if (closed) return "sigterm";
  child.kill("SIGKILL");
  await Promise.race([new Promise((resolve) => child.once("close", resolve)), delay(1_000)]);
  return "sigkill";
}

async function launch(options) {
  const chrome = process.env.CHROME || "google-chrome";
  const debugPort = await port();
  const flags = ["--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage",
    `--disk-cache-dir=${path.join(options["evidence-dir"], "cache")}`,
    "--remote-debugging-address=127.0.0.1", `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${options.profile}`];
  if (options["ignore-certificate-errors"]) flags.push("--ignore-certificate-errors");
  flags.push("about:blank");
  const child = spawn(chrome, flags, { stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  let launchError = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr = `${stderr}${chunk}`.slice(-STDERR_LIMIT); });
  child.on("error", (error) => { launchError = error.message; });
  const deadline = Date.now() + READY_MS;
  let version;
  while (Date.now() < deadline && !launchError && !exited(child)) {
    try {
      const response = await fetchDeadline(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) { version = await response.json(); if (version.webSocketDebuggerUrl) break; }
    } catch {}
    await delay(100);
  }
  if (!version?.webSocketDebuggerUrl) throw new Error(`CDP readiness failed: ${launchError || stderr || "deadline exceeded"}`);
  return { chrome, child, debugPort, flags, version, stderr: () => stderr };
}

async function pageSocket(debugPort) {
  const response = await fetchDeadline(`http://127.0.0.1:${debugPort}/json/new?about:blank`, { method: "PUT" });
  if (!response.ok) throw new Error(`create CDP page: HTTP ${response.status}`);
  const target = await response.json();
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(target.webSocketDebuggerUrl);
    const timer = setTimeout(() => { socket.close(); reject(new Error("CDP socket open deadline exceeded")); }, SOCKET_MS);
    socket.addEventListener("open", () => { clearTimeout(timer); resolve(socket); }, { once: true });
    socket.addEventListener("error", () => { clearTimeout(timer); reject(new Error("CDP socket error")); }, { once: true });
  });
}

function client(socket, events) {
  let id = 0;
  const pending = new Map();
  socket.addEventListener("message", ({ data }) => {
    const message = JSON.parse(data);
    if (message.id) {
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id); clearTimeout(request.timer);
      message.error ? request.reject(new Error(message.error.message)) : request.resolve(message.result);
    } else if (message.method) events.push({ at: new Date().toISOString(), method: message.method, params: message.params });
  });
  return (method, params = {}) => new Promise((resolve, reject) => {
    const requestId = ++id;
    const timer = setTimeout(() => { pending.delete(requestId); reject(new Error(`CDP request deadline: ${method}`)); }, REQUEST_MS);
    pending.set(requestId, { resolve, reject, timer });
    socket.send(JSON.stringify({ id: requestId, method, params }));
  });
}

async function expected(bundle) {
  const index = JSON.parse(await readFile(path.join(bundle, "widgets/search-index.json"), "utf8"));
  for (const item of index) {
    const result = JSON.parse(await readFile(path.join(bundle, "data/test-results", `${item.id}.json`), "utf8"));
    if (result.steps?.length && result.attachments?.length && result.history?.length >= 2) {
      const attachment = result.attachments[0].link;
      const content = await readFile(path.join(bundle, "data/attachments", `${attachment.id}.json`), "utf8");
      let attachmentNeedle = content.trim();
      try {
        const scalars = [];
        const collect = (value) => {
          if (value !== null && typeof value === "object") Object.values(value).forEach(collect);
          else scalars.push(String(value));
        };
        collect(JSON.parse(content));
        attachmentNeedle = scalars.sort((left, right) => right.length - left.length)[0] || attachmentNeedle;
      } catch {}
      return { resultId: item.id, caseName: result.name, stepText: result.steps[0].name,
        attachmentLabel: attachment.name, attachmentId: attachment.id, attachmentContent: content, attachmentNeedle,
        historyCount: result.history.length };
    }
  }
  throw new Error("no generated case has steps, an attachment, and at least two history entries");
}

async function navigate(call, url) {
  const result = await call("Page.navigate", { url });
  if (result.errorText) throw new Error(`navigation failed: ${result.errorText}`);
  await waitDOM(call, (html) => html.includes("</html>"));
  return result.loaderId;
}

async function currentLoader(call) {
  const tree = await call("Page.getFrameTree");
  const loader = tree.frameTree?.frame?.loaderId;
  if (!loader) throw new Error("top-level document lacks a CDP loader ID");
  return loader;
}

async function dom(call) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const document = await call("DOM.getDocument", { depth: -1, pierce: true });
    try {
      return (await call("DOM.getOuterHTML", { nodeId: document.root.nodeId })).outerHTML;
    } catch (error) {
      if (!error.message.includes("Could not find node") || attempt === 2) throw error;
    }
  }
}

async function waitDOM(call, predicate) {
  const deadline = Date.now() + DOM_MS;
  let html = "";
  while (Date.now() < deadline) {
    html = await dom(call);
    if (predicate(html)) return html;
    await delay(100);
  }
  throw new Error("DOM assertion deadline exceeded");
}

async function evaluate(call, expression) {
  const result = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(`browser evaluation failed: ${result.exceptionDetails.text}`);
  return result.result.value;
}

async function waitEvaluate(call, expression, predicate) {
  const deadline = Date.now() + DOM_MS;
  let value;
  while (Date.now() < deadline) {
    value = await evaluate(call, expression);
    if (predicate(value)) return value;
    await delay(100);
  }
  throw new Error(`rendered UI assertion deadline exceeded: ${expression}`);
}

async function clickElement(call, expression) {
  const point = await evaluate(call, `(() => { const node = (${expression}); if (!node) return null; const box = node.getBoundingClientRect(); if (!box.width || !box.height) return null; return { x: box.left + box.width / 2, y: box.top + box.height / 2 }; })()`);
  if (!point) return false;
  await call("Input.dispatchMouseEvent", { type: "mouseMoved", x: point.x, y: point.y });
  await call("Input.dispatchMouseEvent", { type: "mousePressed", x: point.x, y: point.y, button: "left", clickCount: 1 });
  await call("Input.dispatchMouseEvent", { type: "mouseReleased", x: point.x, y: point.y, button: "left", clickCount: 1 });
  return true;
}

function assertContains(html, values, stage) {
  for (const [label, value] of Object.entries(values)) if (!html.includes(value)) throw new Error(`${stage} DOM lacks ${label} ${JSON.stringify(value)}`);
}

async function main() {
  const options = args();
  const forbiddenRoots = ["/tmp", "/var/tmp"].map((root) => path.resolve(root));
  for (const [label, value] of [["evidence-dir", options["evidence-dir"]], ["profile", options.profile]]) {
    const resolved = path.resolve(value);
    if (forbiddenRoots.some((root) => resolved === root || resolved.startsWith(`${root}${path.sep}`))) {
      throw new Error(`${label} must be persistent and cannot use system temporary storage: ${resolved}`);
    }
  }
  await mkdir(options["evidence-dir"], { recursive: true });
  await mkdir(options.profile, { recursive: true });
  let browser; let socket; let cleanup = "not-started"; let status = "FAIL"; let failure = "";
  const events = []; const assertions = [];
  try {
    browser = await launch(options);
    socket = await pageSocket(browser.debugPort);
    const call = client(socket, events);
    await call("Page.enable"); await call("DOM.enable"); await call("Network.enable");
    if (options.probe) {
      await navigate(call, "about:blank");
      assertions.push("cdp_endpoint_ready", "page_navigation_ready", "dom_read_ready");
    } else {
      const wanted = await expected(options.bundle);
      const base = options.url;
      const caseURL = `${base}#/${wanted.resultId}`;
      await navigate(call, caseURL);
      const first = await waitDOM(call, (html) => [wanted.caseName, wanted.stepText, wanted.attachmentLabel, "History"].every((x) => html.includes(x)));
      assertContains(first, { case_name: wanted.caseName, step_text: wanted.stepText, attachment_label: wanted.attachmentLabel, history_surface: "History" }, "case");
      const renderedHistory = first.match(/data-testid="test-result-tab-history"[\s\S]{0,500}?data-testid="counter"[^>]*>(\d+)</);
      if (!renderedHistory || Number(renderedHistory[1]) < 2) throw new Error("case DOM lacks at least two rendered history entries");
      await writeFile(path.join(options["evidence-dir"], "case.dom.html"), first);
      assertions.push("direct_hash_navigation", "case_name", "step_text", "attachment_label", `history_entries_expected=${wanted.historyCount}`, `history_entries_rendered=${renderedHistory[1]}`);

      if (!await evaluate(call, `(() => { const node = document.querySelector('[data-testid="test-result-tab-history"]'); if (!node) return false; node.click(); return true; })()`)) throw new Error("could not activate History tab");
      const historyItems = await waitEvaluate(call, `Array.from(document.querySelectorAll('[data-testid="test-result-history-item"]')).map((node) => node.innerText)`, (items) => items.length >= 2 && items.every((text) => text.trim().length > 0));
      const historyDOM = await dom(call);
      await writeFile(path.join(options["evidence-dir"], "history.dom.html"), historyDOM);
      assertions.push(`history_items_clicked_and_rendered=${historyItems.length}`);

      if (!await evaluate(call, `(() => { const node = document.querySelector('[data-testid="test-result-tab-attachments"]'); if (!node) return false; node.click(); return true; })()`)) throw new Error("could not activate Attachments tab");
      const attachmentLabelJSON = JSON.stringify(wanted.attachmentLabel);
      const activated = await clickElement(call, `(() => { const label = ${attachmentLabelJSON}; const header = Array.from(document.querySelectorAll('[data-testid="test-result-attachment-header"]')).find((item) => item.innerText.includes(label)); const attachment = header?.closest('[data-testid="test-result-attachment"]'); return attachment?.querySelector('button'); })()`);
      if (!activated) throw new Error("could not activate matching attachment control");
      await delay(250);
      const attachmentUIDOM = await dom(call);
      await writeFile(path.join(options["evidence-dir"], "attachment-ui.dom.html"), attachmentUIDOM);
      const attachmentFrames = await call("Page.getFrameTree");
      await writeFile(path.join(options["evidence-dir"], "attachment-ui.frames.json"), JSON.stringify(attachmentFrames, null, 2));
      const contentJSON = JSON.stringify(wanted.attachmentNeedle);
      const renderedAttachment = await waitEvaluate(call, `(() => { const wanted = ${contentJSON}; return Array.from(document.querySelectorAll('[data-testid="test-result-attachment-content"], [data-testid="test-result-attachment-text"], [data-testid="test-result-attachment-content-wrapper"], [data-testid="code-attachment-content"]')).map((node) => node.innerText || node.textContent || '').find((text) => text.includes(wanted)) || ''; })()`, Boolean);
      assertions.push("attachment_control_activated", "attachment_content_rendered_in_ui");

      const currentHash = await evaluate(call, "location.hash");
      if (!new RegExp(`^#/?${wanted.resultId}(?:/attachments)?$`).test(currentHash)) throw new Error(`attachment UI did not retain the selected case route: ${currentHash}`);
      assertions.push("case_specific_attachment_route");
      await navigate(call, caseURL);
      const preReload = await waitDOM(call, (html) => [wanted.caseName, wanted.stepText, wanted.attachmentLabel].every((x) => html.includes(x)));
      assertContains(preReload, { case_name: wanted.caseName, step_text: wanted.stepText, attachment_label: wanted.attachmentLabel }, "pre-reload case");
      const preReloadLoader = await currentLoader(call);
      assertions.push("return_to_direct_case_route_before_reload");
      const reloadEventStart = events.length;
      const reload = await call("Page.reload", { ignoreCache: true });
      void reload;
      const reloadEventDeadline = Date.now() + DOM_MS;
      let reloadLoader = "";
      while (Date.now() < reloadEventDeadline) {
        const event = events.slice(reloadEventStart).find((entry) => entry.method === "Page.frameNavigated" && entry.params?.frame?.loaderId && entry.params.frame.loaderId !== preReloadLoader);
        if (event) { reloadLoader = event.params.frame.loaderId; break; }
        await delay(100);
      }
      if (!reloadLoader) throw new Error("Page.reload did not produce a changed document loader");
      const reloaded = await waitDOM(call, (html) => [wanted.caseName, wanted.stepText, wanted.attachmentLabel].every((x) => html.includes(x)));
      assertContains(reloaded, { case_name: wanted.caseName, step_text: wanted.stepText, attachment_label: wanted.attachmentLabel }, "reloaded case");
      await writeFile(path.join(options["evidence-dir"], "case-reload.dom.html"), reloaded);
      assertions.push(`reload_document_changed=${preReloadLoader}->${reloadLoader}`, "reload_reasserted");
      const attachmentURL = new URL(`data/attachments/${wanted.attachmentId}.json`, base).href;
      await navigate(call, attachmentURL);
      const attachmentDOM = await waitDOM(call, (html) => html.includes(wanted.attachmentContent.trim()));
      await writeFile(path.join(options["evidence-dir"], "attachment.dom.html"), attachmentDOM);
      assertions.push("direct_attachment_navigation", "attachment_semantic_content");
      await writeFile(path.join(options["evidence-dir"], "expected.json"), JSON.stringify({ ...wanted, attachmentContent: wanted.attachmentContent.trim(), caseURL, attachmentURL }, null, 2));
    }
    status = "PASS";
  } catch (error) {
    failure = error.stack || error.message || String(error);
    throw error;
  } finally {
    if (socket) socket.close();
    if (browser) {
      cleanup = await closeChild(browser.child);
      await writeFile(path.join(options["evidence-dir"], "browser.stderr.log"), browser.stderr());
    }
    await writeFile(path.join(options["evidence-dir"], "network.jsonl"), events.filter((event) => event.method.startsWith("Network.")).map((event) => JSON.stringify(event)).join("\n") + "\n");
    let version = "unavailable";
    if (browser) {
      try { version = execFileSync(browser.chrome, ["--version"], { encoding: "utf8" }).trim(); } catch {}
    }
    await writeFile(path.join(options["evidence-dir"], "receipt.txt"), [
      `status=${status}`, `chrome=${browser?.chrome || process.env.CHROME || "google-chrome"}`, `version=${version}`,
      `flags=${browser?.flags.join(" ") || "launch-failed"}`, `fixture_tls_exception=${Boolean(options["ignore-certificate-errors"])}`,
      `evidence_dir=${path.resolve(options["evidence-dir"])}`, `profile=${path.resolve(options.profile)}`, `cache_dir=${path.resolve(options["evidence-dir"], "cache")}`,
      `request_deadline_ms=${REQUEST_MS}`, `socket_deadline_ms=${SOCKET_MS}`, `dom_deadline_ms=${DOM_MS}`,
      `assertions=${assertions.join(",")}`, `failure=${failure.replaceAll("\n", " | ")}`, `owned_process_cleanup=${cleanup}`, "",
    ].join("\n"));
  }
}

main().catch((error) => { console.error(error.stack || error); process.exitCode = 1; });
