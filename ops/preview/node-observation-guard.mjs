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
  if (
    a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0 && address.split(".")[2] === "0") ||
    (a === 192 && b === 0 && address.split(".")[2] === "2") ||
    (a === 192 && b === 88 && address.split(".")[2] === "99") ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19 || b === 51 && address.split(".")[2] === "100")) ||
    (a === 203 && b === 0 && address.split(".")[2] === "113")
  ) return false;
  return true;
}

export function validPath(url) {
  if (url.pathname === "/health" && url.search === "") return true;
  if (url.pathname === "/v1/versions" && url.search === "") return true;
  if (url.pathname === "/devshard/healthz" && url.search === "") return true;
  if (url.pathname === "/devshard/stats/shards" && url.search === "") return true;
  if (url.pathname === "/chain-rpc/status" && url.search === "") return true;
  if (url.pathname === "/chain-rpc/net_info" && url.search === "") return true;
  if (url.pathname === "/chain-rpc/block" && validPositiveIntegerQuery(url, "height")) return true;
  if (url.pathname === "/chain-rpc/validators" && validValidatorQuery(url)) return true;
  if (url.pathname === "/chain-api/cosmos/base/tendermint/v1beta1/node_info" && url.search === "") return true;
  if (url.pathname === "/chain-api/productscience/inference/inference/params" && url.search === "") return true;
  if (/^\/chain-api\/productscience\/inference\/inference\/hardware_nodes\/gonka1[02-9ac-hj-np-z]{6,90}$/.test(url.pathname) && url.search === "") return true;
  const apiPath = "/chain-api/productscience/inference/inference/";
  const suffix = url.pathname.startsWith(apiPath) ? url.pathname.slice(apiPath.length) : "";
  if (
    ["devshard_approved_versions", "models_all", "epoch_info", "active_confirmation_poc_event"].includes(suffix) &&
    url.search === ""
  ) return true;
  if (/^(?:epoch_group_data|all_poc_v2_store_commits|poc_v2_validations_for_stage|confirmation_poc_events)\/[1-9]\d*$/.test(suffix) && url.search === "") return true;
  if (url.pathname === `${apiPath}participant`) {
    return url.search === "?pagination.limit=100" ||
      url.search === "?pagination.limit=100&pagination.count_total=true";
  }
  return false;
}

export function validBootstrapPath(path) {
  return /^\/bootstrap\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\/bootstrap\.json$/.test(path);
}

export function validGeoPath(path) {
  const match = /^\/geo\/(\d{1,3}(?:\.\d{1,3}){3})$/.exec(path);
  return Boolean(match && publicIpv4(match[1]));
}

function validPositiveIntegerQuery(url, key) {
  const match = new RegExp(`^\\?${key}=([1-9]\\d*)$`).exec(url.search);
  return Boolean(match && Number.isSafeInteger(Number(match[1])));
}

function validValidatorQuery(url) {
  if (!url.search || url.search.startsWith("?&") || url.search.endsWith("&") || url.search.includes("&&")) return false;
  const rawPairs = url.search.slice(1).split("&");
  if (rawPairs.some((pair) => !/^(?:height|page|per_page)=\d+$/.test(pair))) return false;
  const params = url.searchParams;
  const keys = [...params.keys()];
  if (keys.length === 1 && keys[0] === "per_page")
    return params.getAll("per_page").length === 1 && params.get("per_page") === "100";
  if (keys.length !== 3 || new Set(keys).size !== 3 ||
    !["height", "page", "per_page"].every((key) => params.getAll(key).length === 1)) return false;
  const height = params.get("height") || "";
  const page = params.get("page") || "";
  return /^(?:[1-9]\d*)$/.test(height) && Number.isSafeInteger(Number(height)) &&
    /^(?:[1-9]\d*)$/.test(page) && Number.isSafeInteger(Number(page)) && Number(page) <= 100 &&
    params.get("per_page") === "100";
}

function reject(response, code, reason) {
  if (response.headersSent) {
    response.destroy();
    return;
  }
  response.writeHead(code, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify({ error: reason }));
}

export async function resolvedPublicIpv4(host) {
  const records = await dns.promises.lookup(host, { all: true, family: 4, verbatim: true });
  const addresses = records.map((record) => record.address);
  if (addresses.length !== 1 || !publicIpv4(addresses[0])) throw new Error("unsafe_dns_result");
  return addresses[0];
}

function proxyRequest(request, response, host, path, address) {
  const upstream = https.request({
    hostname: host,
    port: 443,
    path,
    method: request.method,
    servername: host,
    rejectUnauthorized: true,
    timeout: timeoutMs,
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
}

async function proxyPublicHost(request, response, host, path) {
  let address;
  try {
    address = await resolvedPublicIpv4(host);
  } catch {
    return reject(response, 502, "unsafe_or_unavailable_dns");
  }
  return proxyRequest(request, response, host, path, address);
}

const server = http.createServer(async (request, response) => {
  if (!["GET", "HEAD"].includes(request.method || "")) return reject(response, 405, "method_not_allowed");
  const geoMatch = /^\/geo\/(\d{1,3}(?:\.\d{1,3}){3})$/.exec(request.url || "");
  if (geoMatch) {
    if (request.method !== "GET") return reject(response, 405, "method_not_allowed");
    const ip = geoMatch[1];
    if (!publicIpv4(ip)) return reject(response, 404, "not_found");
    return proxyPublicHost(request, response, "ipwho.is", `/${ip}`);
  }
  const bootstrapMatch = /^\/bootstrap\/([A-Za-z0-9][A-Za-z0-9._-]{0,127})\/bootstrap\.json$/.exec(request.url || "");
  if (bootstrapMatch) {
    if (request.method !== "GET") return reject(response, 405, "method_not_allowed");
    return proxyPublicHost(request, response, "gonka-dev.net", `/${bootstrapMatch[1]}/bootstrap.json`);
  }
  const match = /^\/node\/(node[0-9]+)(\/.*)$/.exec(request.url || "");
  if (!match) return reject(response, 404, "not_found");
  const host = nodeHost(match[1]);
  const target = new URL(`https://${host}${match[2]}`);
  if (!validPath(target)) return reject(response, 404, "not_found");

  // The address is resolved and policy-checked above before connecting.
  return proxyPublicHost(request, response, host, `${target.pathname}${target.search}`);
});

if (process.env.NODE_GUARD_NO_LISTEN !== "1") server.listen(port, "0.0.0.0");
