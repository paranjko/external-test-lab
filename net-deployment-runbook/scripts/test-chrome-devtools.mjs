#!/usr/bin/env node
import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  startChromeDevTools,
  stopChromeDevTools,
} from "./chrome-devtools.mjs";

const root = await mkdtemp(join(tmpdir(), "gdc-chrome-devtools-test-"));

async function executable(name, source) {
  const path = join(root, name);
  await writeFile(path, `#!/usr/bin/env node\n${source}`);
  await chmod(path, 0o755);
  return path;
}

async function profile(name) {
  return mkdtemp(join(root, `${name}-`));
}

try {
  const delayedChrome = await executable(
    "delayed-chrome.mjs",
    `
import { createServer } from "node:http";
const portArgument = process.argv.find((argument) => argument.startsWith("--remote-debugging-port="));
const port = Number(portArgument?.split("=")[1]);
if (!Number.isInteger(port)) process.exit(2);
let server;
const stop = () => server ? server.close(() => process.exit(0)) : process.exit(0);
process.on("SIGTERM", stop);
setTimeout(() => {
  server = createServer((request, response) => {
    if (request.url !== "/json/version") {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ webSocketDebuggerUrl: "ws://127.0.0.1/fixture" }));
  });
  server.listen(port, "127.0.0.1");
}, 4_500);
`,
  );
  const delayed = await startChromeDevTools({
    chrome: delayedChrome,
    profile: await profile("delayed"),
    context: "delayed fixture",
  });
  const delayedStartedAt = Date.now();
  try {
    const version = await delayed.waitForEndpoint();
    assert.equal(version.webSocketDebuggerUrl, "ws://127.0.0.1/fixture");
    assert.ok(Date.now() - delayedStartedAt >= 4_000);
  } finally {
    await stopChromeDevTools(delayed.browser);
  }

  const failingChrome = await executable(
    "failing-chrome.mjs",
    'process.stderr.write("fixture chrome launch failed\\n"); process.exit(23);\n',
  );
  const failing = await startChromeDevTools({
    chrome: failingChrome,
    profile: await profile("failing"),
    context: "failing fixture",
  });
  try {
    await assert.rejects(
      failing.waitForEndpoint(),
      (error) =>
        /for failing fixture/.test(error.message) &&
        /exit code: 23/.test(error.message) &&
        /stderr: fixture chrome launch failed/.test(error.message),
    );
  } finally {
    await stopChromeDevTools(failing.browser);
  }

  const missing = await startChromeDevTools({
    chrome: join(root, "missing-chrome"),
    profile: await profile("missing"),
    context: "missing fixture",
  });
  try {
    await assert.rejects(
      missing.waitForEndpoint(),
      (error) =>
        /for missing fixture/.test(error.message) &&
        /launch error:.*ENOENT/.test(error.message),
    );
  } finally {
    await stopChromeDevTools(missing.browser);
  }

  process.stdout.write(
    "PASS Chrome DevTools startup tolerates delay and reports launch failure\n",
  );
} finally {
  await rm(root, { recursive: true, force: true });
}
