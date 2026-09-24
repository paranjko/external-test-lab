import dns from "node:dns";
import http from "node:http";
import https from "node:https";
import net from "node:net";

const port = Number(process.env.PREVIEW_NODE_GUARD_PORT || "8090");
const timeoutMs = 5_000;
const nodeHost = (name) => `${name}.gonka-dev.net`;

export function publicIpv4(address) {
  if (net.isIP(address) !== 4) return false;
  const [a, b] = address.split(".").map(Number);
  if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  return true;
}

export function validPath(url) {
  if (url.pathname === "/chain-rpc/status" && url.search === "") return true;
  if (url.pathname === "/chain-rpc/net_info" && url.search === "") return true;
  if (url.pathname === "/chain-rpc/validators" && url.search === "?per_page=100") return true;
  return url.pathname === "/chain-api/productscience/inference/inference/participant" &&
    url.search === "?pagination.limit=100&pagination.count_total=true";
}

function reject(response, code, reason) {
  response.writeHead(code, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify({ error: reason }));
}

export async function resolvedPublicIpv4(host) {
  const records = await dns.promises.lookup(host, { all: true, family: 4, verbatim: true });
  const addresses = records.map((record) => record.address);
  if (addresses.length !== 1 || !publicIpv4(addresses[0])) throw new Error("unsafe_dns_result");
  return addresses[0];
}

const server = http.createServer(async (request, response) => {
  if (!["GET", "HEAD"].includes(request.method || "")) return reject(response, 405, "method_not_allowed");
  const match = /^\/node\/(node[0-9]+)(\/.*)$/.exec(request.url || "");
  if (!match) return reject(response, 404, "not_found");
  const host = nodeHost(match[1]);
  const target = new URL(`https://${host}${match[2]}`);
  if (!validPath(target)) return reject(response, 404, "not_found");

  let address;
  try {
    address = await resolvedPublicIpv4(host);
  } catch {
    return reject(response, 502, "unsafe_or_unavailable_dns");
  }
  const upstream = https.request({
    hostname: host,
    port: 443,
    path: `${target.pathname}${target.search}`,
    method: request.method,
    servername: host,
    rejectUnauthorized: true,
    timeout: timeoutMs,
    // The address is resolved and policy-checked above. Node 26 otherwise enables
    // multi-address selection and expects the custom lookup to return an array.
    autoSelectFamily: false,
    lookup: (_hostname, _options, callback) => callback(null, address, 4),
    headers: { host, accept: "application/json" },
  }, (upstreamResponse) => {
    const headers = {
      "content-type": upstreamResponse.headers["content-type"] || "application/json",
      "cache-control": "no-store",
    };
    response.writeHead(upstreamResponse.statusCode || 502, headers);
    if (request.method === "HEAD") response.end();
    else {
      upstreamResponse.on("error", () => response.destroy());
      upstreamResponse.pipe(response);
    }
  });
  upstream.on("timeout", () => upstream.destroy(new Error("upstream_timeout")));
  upstream.on("error", () => reject(response, 502, "upstream_unavailable"));
  upstream.end();
});

if (process.env.NODE_GUARD_NO_LISTEN !== "1") server.listen(port, "0.0.0.0");
