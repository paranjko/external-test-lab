import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const temporary = await mkdtemp(path.join(tmpdir(), "gdc-participants-test-"));
const socketPath = path.join(temporary, "proxy.sock");
const rows = Array.from({ length: 205 }, (_, n) => ({
  address: "fixture-account-" + n,
  inference_url: "https://host-" + n + ".example.test",
  status: n === 1 ? "INACTIVE" : "ACTIVE",
  description: "Preserve Unicode: узел",
}));
let mode = "good";
let requests = [];
const fixtureErrors = [];
const upstream = http.createServer((request, response) => {
  try {
    const url = new URL(request.url, "http://fixture");
    requests.push({ path: url.pathname, key: url.searchParams.get("pagination.key") });
    response.setHeader("Content-Type", "application/json");
    if (url.pathname.endsWith("/participant")) {
      assert.equal(url.searchParams.get("pagination.limit"), "100");
      const key = url.searchParams.get("pagination.key");
      const offset = key ? Number(Buffer.from(key, "base64").toString()) : 0;
      assert.equal(request.headers["x-cosmos-block-height"], key ? "42" : undefined);
      if (mode === "page_failure" && offset > 0) {
        response.writeHead(503).end("{}");
        return;
      }
      const entries = mode === "empty" ? [] : rows;
      const next = offset + 100 < entries.length
        ? Buffer.from(String(mode === "repeated_cursor" ? 100 : offset + 100)).toString("base64")
        : null;
      response.end(JSON.stringify({
        participant: mode === "malformed" ? {} : entries.slice(offset, offset + 100),
        block_height: mode === "changed_height" && offset > 0 ? "43" : "42",
        pagination: { total: String(entries.length + (mode === "wrong_total" ? 1 : 0)), next_key: next },
      }));
    } else if (url.pathname.endsWith("/params")) {
      assert.equal(request.headers["x-cosmos-block-height"], "42");
      if (mode === "params_failure") {
        response.writeHead(503).end("{}");
        return;
      }
      const blocked = mode === "no_blocks" ? [] : [rows[0].address, rows[199].address];
      response.end(JSON.stringify(mode === "missing_blocklist" ? {} : {
        params: { participant_access_params: { blocked_participant_addresses: blocked } },
      }));
    } else {
      throw new Error("unexpected upstream route " + url.pathname);
    }
  } catch (error) {
    fixtureErrors.push(error.message);
    response.writeHead(500).end("{}");
  }
});
await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
const activation = spawn("systemd-socket-activate", [
  "--listen=" + socketPath, "--accept", "--inetd",
  "--setenv=GDC_PARTICIPANTS_CHAIN_API=http://127.0.0.1:" + upstream.address().port,
  "/usr/bin/bash", path.join(root, "04-ops/participants-proxy.sh"),
], { stdio: ["ignore", "ignore", "pipe"] });
let diagnostics = "";
activation.stderr.on("data", (chunk) => { diagnostics += chunk; });
let activationError;
activation.on("error", (error) => { activationError = error; });
function get(target = "/status/participants", method = "GET") {
  return new Promise((resolve, reject) => {
    const request = http.request({ socketPath, path: target, method, agent: false,
      headers: { "x-cosmos-block-height": "1" } }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        try {
          assert.equal(response.headers["cache-control"], "no-store");
          assert.equal(Number(response.headers["content-length"]), Buffer.byteLength(body));
          resolve({ status: response.statusCode, body: JSON.parse(body) });
        } catch (error) { reject(error); }
      });
    });
    request.setTimeout(10000, () => request.destroy(new Error("fixture timeout")));
    request.on("error", reject);
    request.end();
  });
}
try {
  for (let attempt = 0; ; attempt++) {
    if (activationError) throw activationError;
    if (await stat(socketPath).catch(() => null)) break;
    assert.ok(attempt < 100, diagnostics);
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  const good = await get();
  assert.equal(good.status, 200, diagnostics);
  assert.equal(good.body.participant.length, 203);
  assert.deepEqual(good.body.pagination, { next_key: null, total: "203" });
  assert.equal(good.body.block_height, "42");
  assert.deepEqual(good.body.participant, rows.filter((_, n) => n !== 0 && n !== 199));
  assert.equal(requests.filter((request) => request.path.endsWith("/participant")).length, 3);
  assert.equal((await get("/status/participants?pagination.limit=1")).body.participant.length, 203);
  for (const failure of ["page_failure", "params_failure", "missing_blocklist",
    "changed_height", "repeated_cursor", "wrong_total", "malformed"]) {
    mode = failure;
    const result = await get();
    assert.equal(result.status, 503, failure + ": " + diagnostics);
    assert.deepEqual(result.body, { error: "participant_registry_unavailable" });
  }
  mode = "empty";
  assert.deepEqual((await get()).body.participant, []);
  mode = "no_blocks";
  assert.deepEqual((await get()).body.participant, rows);
  const count = requests.length;
  assert.equal((await get("/unrelated")).status, 404);
  assert.equal((await get("/status/participants", "POST")).status, 405);
  assert.equal(requests.length, count);
  for (const filename of ["04-ops/Caddyfile", "04-ops/render-ops.sh"]) {
    const source = await readFile(path.join(root, filename), "utf8");
    assert.match(source, /handle \/status\/participants \{\s+reverse_proxy 127\.0\.0\.1:18089\s+\}/);
  }
  const install = await readFile(path.join(root, "04-ops/install-ops.sh"), "utf8");
  assert.match(install, /install .*participants-proxy\.sh.*\/usr\/local\/lib\/gonka-devnet\/participants-proxy\.sh/);
  assert.match(install, /systemctl enable --now gdc-participants-proxy\.socket/);
  const unit = await readFile(path.join(root, "04-ops/gdc-participants-proxy@.service"), "utf8");
  assert.match(unit, /StandardInput=socket/);
  assert.match(unit, /StandardOutput=inherit/);
  assert.match(unit, /DynamicUser=yes/);
  assert.deepEqual(fixtureErrors, []);
  console.log("PASS real socket-activated HTTP proxy: complete 100-row pagination, on-chain filtering, retained inactive participants, pinned height and non-partial failures");
} finally {
  if (activation.exitCode === null && !activationError) {
    activation.kill();
    await once(activation, "exit");
  }
  upstream.closeAllConnections();
  await new Promise((resolve) => upstream.close(resolve));
  await rm(temporary, { recursive: true, force: true });
}
