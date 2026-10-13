#!/usr/bin/env node

import { pathToFileURL } from "node:url";

const DEFAULT_BASE_URL = "https://gonka-dev.net";
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_CHAIN_AGE_MS = 90_000;
const MAX_RESPONSE_BYTES = 16 * 1024 * 1024;
const CHAIN_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

function freshTimestamp(value, now, maxAgeMs = MAX_CHAIN_AGE_MS) {
  const timestamp = Date.parse(String(value || ""));
  const age = now - timestamp;
  return Number.isFinite(timestamp) && age >= 0 && age <= maxAgeMs;
}

export function validateNetworkSnapshot(snapshot, expectedChainId, now = Date.now()) {
  if (!snapshot || snapshot.schema_version !== 1 || typeof snapshot.chain_id !== "string" ||
      !CHAIN_ID_PATTERN.test(snapshot.chain_id)) {
    throw new Error("HTTP response is not a current network snapshot");
  }
  if (expectedChainId && snapshot.chain_id !== expectedChainId) {
    throw new Error(`HTTP snapshot chain_id mismatch: expected ${expectedChainId}, received ${snapshot.chain_id}`);
  }
  if (!freshTimestamp(snapshot.observed_at, now)) {
    throw new Error("HTTP snapshot is absent or stale");
  }
  if (!Array.isArray(snapshot.nodes)) {
    throw new Error("HTTP snapshot has no node inventory");
  }

  const chain = snapshot.chain;
  const latestEpoch = chain?.activity?.epoch?.latest_epoch;
  if (!chain || chain.state !== "observed" || !freshTimestamp(chain.observed_at, now) ||
      !chain.reference || !/^[0-9a-f]{40}$/i.test(String(chain.reference.node_id || "")) ||
      !Number.isSafeInteger(Number(chain.reference.height)) || Number(chain.reference.height) <= 0 ||
      !Array.isArray(chain.validators) || !Array.isArray(chain.participants) ||
      !Array.isArray(chain.hardware_nodes) || !Array.isArray(chain.approved_devshards) ||
      !chain.activity || !chain.activity.epoch || typeof chain.activity.epoch !== "object" ||
      !latestEpoch || typeof latestEpoch !== "object" ||
      !/^[1-9]\d*$/.test(String(latestEpoch.index || "")) ||
      !/^[1-9]\d*$/.test(String(latestEpoch.poc_start_block_height || ""))) {
    throw new Error("HTTP snapshot lacks a fresh full chain observation");
  }
  return snapshot.chain_id;
}

export function validateWebSocketEnvelope(envelope, chainId, now = Date.now()) {
  if (!envelope || envelope.type !== "network_snapshot" || !envelope.snapshot) {
    throw new Error("WebSocket response is not a network_snapshot envelope");
  }
  validateNetworkSnapshot(envelope.snapshot, chainId, now);
  return envelope.snapshot;
}

export function validateStatusPrefix(statusPrefix) {
  if (statusPrefix === "/status") return statusPrefix;
  const match = /^\/([1-9]\d*)\/status$/.exec(statusPrefix);
  if (!match || !Number.isSafeInteger(Number(match[1]))) {
    throw new Error("status prefix must be /status or /<positive preview number>/status");
  }
  return statusPrefix;
}

async function fetchJson(url, timeoutMs) {
  const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), redirect: "manual" });
  if (response.status !== 200) throw new Error(`HTTP ${response.status} from ${url.pathname}`);
  const contentType = response.headers.get("content-type") || "";
  if (!contentType.toLowerCase().includes("application/json")) {
    throw new Error(`non-JSON response from ${url.pathname}`);
  }
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_RESPONSE_BYTES) {
    throw new Error(`response from ${url.pathname} exceeds the size limit`);
  }
  try {
    const reader = response.body.getReader();
    const chunks = [];
    let total = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_RESPONSE_BYTES) {
        await reader.cancel();
        throw new Error(`response from ${url.pathname} exceeds the size limit`);
      }
      chunks.push(Buffer.from(value));
    }
    return JSON.parse(Buffer.concat(chunks, total).toString("utf8"));
  } catch (error) {
    if (error instanceof Error && error.message.includes("exceeds the size limit")) throw error;
    throw new Error(`invalid JSON from ${url.pathname}`);
  }
}

function receiveWebSocketSnapshot(url, chainId, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    let settled = false;
    const timer = setTimeout(() => {
      finish(new Error("WebSocket observer timed out"));
    }, timeoutMs);
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      error ? reject(error) : resolve(value);
      try { socket.close(); } catch {}
    };
    socket.addEventListener("message", (event) => {
      try {
        const text = typeof event.data === "string" ? event.data : String(event.data);
        if (Buffer.byteLength(text, "utf8") > MAX_RESPONSE_BYTES) {
          throw new Error("WebSocket observer snapshot exceeds the response size limit");
        }
        finish(null, validateWebSocketEnvelope(JSON.parse(text), chainId));
      } catch (error) {
        finish(error instanceof Error ? error : new Error(String(error)));
      }
    }, { once: true });
    socket.addEventListener("error", () => finish(new Error("WebSocket observer connection failed")), { once: true });
    socket.addEventListener("close", () => finish(new Error("WebSocket observer closed before a snapshot")), { once: true });
  });
}

export async function verifyNetworkObserver({
  baseUrl = DEFAULT_BASE_URL,
  chainId = "",
  statusPrefix = "/status",
  timeoutMs = REQUEST_TIMEOUT_MS,
} = {}) {
  if (chainId && !CHAIN_ID_PATTERN.test(chainId)) throw new Error("invalid requested chain ID");
  validateStatusPrefix(statusPrefix);
  const base = new URL(baseUrl);
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password ||
      base.pathname !== "/" || base.search || base.hash) {
    throw new Error("base URL must be an HTTP(S) origin without credentials, path, query, or fragment");
  }
  const httpUrl = new URL(`${statusPrefix}/network`, base);
  if (chainId) httpUrl.searchParams.set("chainId", chainId);
  const snapshot = await fetchJson(httpUrl, timeoutMs);
  const observedChainId = validateNetworkSnapshot(snapshot, chainId);

  const wsUrl = new URL(`${statusPrefix}/network/ws`, base);
  wsUrl.protocol = base.protocol === "https:" ? "wss:" : "ws:";
  wsUrl.searchParams.set("chainId", observedChainId);
  const streamed = await receiveWebSocketSnapshot(wsUrl, observedChainId, timeoutMs);
  if (Date.parse(streamed.chain.observed_at) < Date.parse(snapshot.chain.observed_at)) {
    throw new Error("WebSocket observer snapshot is older than the HTTP snapshot");
  }
  return { chainId: observedChainId, observedAt: streamed.chain.observed_at };
}

function parseArgs(argv) {
  const options = { baseUrl: DEFAULT_BASE_URL, chainId: "", statusPrefix: "/status" };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--base-url" && argv[index + 1]) options.baseUrl = argv[++index];
    else if (argv[index] === "--chain-id" && argv[index + 1]) options.chainId = argv[++index];
    else if (argv[index] === "--status-prefix" && argv[index + 1]) options.statusPrefix = argv[++index];
    else if (argv[index] === "--help") {
      console.log("Usage: node scripts/verify-network-observer.mjs [--base-url https://gonka-dev.net] [--chain-id ID] [--status-prefix /status|/<preview-number>/status]");
      process.exit(0);
    } else throw new Error(`unknown or incomplete argument: ${argv[index]}`);
  }
  return options;
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : "";
if (invokedPath === import.meta.url) {
  const exitAfterWrite = (stream, message, code) => {
    stream.write(`${message}\n`, () => process.exit(code));
  };
  try {
    const result = await verifyNetworkObserver(parseArgs(process.argv.slice(2)));
    exitAfterWrite(process.stdout, `PASS production network observer HTTP and WebSocket snapshots: chain ${result.chainId}, observed ${result.observedAt}`, 0);
  } catch (error) {
    exitAfterWrite(process.stderr, `FAIL production network observer: ${error instanceof Error ? error.message : String(error)}`, 1);
  }
}
