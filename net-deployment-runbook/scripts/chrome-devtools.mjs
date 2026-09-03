import { spawn } from "node:child_process";
import { createServer } from "node:net";

const DEFAULT_READY_TIMEOUT_MS = 30_000;
const POLL_INTERVAL_MS = 100;
const FETCH_TIMEOUT_MS = 1_000;
const STDERR_LIMIT = 4_096;

const delay = (milliseconds) =>
  new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds));

const hasExited = (child) =>
  child.exitCode !== null || child.signalCode !== null;

async function reserveLoopbackPort() {
  return new Promise((resolvePromise, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) =>
        error ? reject(error) : resolvePromise(address.port),
      );
    });
  });
}

function waitForClose(child, timeoutMilliseconds) {
  if (hasExited(child)) return Promise.resolve(true);
  return new Promise((resolvePromise) => {
    let settled = false;
    const finish = (closed) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.off("close", onClose);
      resolvePromise(closed);
    };
    const onClose = () => finish(true);
    const timer = setTimeout(() => finish(false), timeoutMilliseconds);
    timer.unref?.();
    child.once("close", onClose);
  });
}

export async function startChromeDevTools({
  chrome = "google-chrome",
  profile,
  context = "browser check",
  readyTimeoutMilliseconds = DEFAULT_READY_TIMEOUT_MS,
} = {}) {
  if (!profile) throw new Error("Chrome profile directory is required");
  if (
    !Number.isInteger(readyTimeoutMilliseconds) ||
    readyTimeoutMilliseconds < 1
  ) {
    throw new Error("Chrome DevTools ready timeout must be a positive integer");
  }

  const port = await reserveLoopbackPort();
  const browser = spawn(
    chrome,
    [
      "--headless=new",
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--remote-debugging-address=127.0.0.1",
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profile}`,
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  let browserStderr = "";
  let browserLaunchError = "";
  browser.stderr.setEncoding("utf8");
  browser.stderr.on("data", (chunk) => {
    browserStderr = `${browserStderr}${chunk}`.slice(-STDERR_LIMIT);
  });
  browser.on("error", (error) => {
    browserLaunchError = error.message;
  });

  const waitForEndpoint = async () => {
    const startedAt = Date.now();
    const deadline = startedAt + readyTimeoutMilliseconds;
    let lastConnectionError = "";
    while (Date.now() < deadline) {
      if (browserLaunchError || hasExited(browser)) break;
      try {
        const remaining = deadline - Date.now();
        const response = await fetch(
          `http://127.0.0.1:${port}/json/version`,
          {
            signal: AbortSignal.timeout(
              Math.max(1, Math.min(FETCH_TIMEOUT_MS, remaining)),
            ),
          },
        );
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`);
        }
        const version = await response.json();
        if (!version.webSocketDebuggerUrl) {
          throw new Error("response lacks webSocketDebuggerUrl");
        }
        return version;
      } catch (error) {
        lastConnectionError = error.message;
        const remaining = deadline - Date.now();
        if (remaining > 0) {
          await delay(Math.min(POLL_INTERVAL_MS, remaining));
        }
      }
    }

    if (browserLaunchError || hasExited(browser)) {
      await waitForClose(browser, 250);
    }
    const diagnostics = [
      browserLaunchError && `launch error: ${browserLaunchError}`,
      browser.exitCode !== null && `exit code: ${browser.exitCode}`,
      browser.signalCode !== null && `signal: ${browser.signalCode}`,
      lastConnectionError && `last connection error: ${lastConnectionError}`,
      browserStderr.trim() && `stderr: ${browserStderr.trim()}`,
    ].filter(Boolean);
    const timeoutSeconds = readyTimeoutMilliseconds / 1_000;
    throw new Error(
      `Chrome DevTools endpoint did not become ready within ${timeoutSeconds} seconds for ${context}${
        diagnostics.length ? `: ${diagnostics.join("; ")}` : ""
      }`,
    );
  };

  return { browser, port, waitForEndpoint };
}

export async function stopChromeDevTools(browser) {
  if (!browser || hasExited(browser)) return;
  browser.kill("SIGTERM");
  if (await waitForClose(browser, 5_000)) return;
  browser.kill("SIGKILL");
  await waitForClose(browser, 1_000);
}
