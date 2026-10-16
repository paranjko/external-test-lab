import dns from "node:dns/promises";
import net from "node:net";
import { pathToFileURL } from "node:url";

process.env.NODE_GUARD_NO_LISTEN = "1";
const { publicIpv4 } = await import("../../ops/preview/node-observation-guard.mjs");

export async function endpointPolicy(value, lookup = dns.lookup) {
  const excluded = (reason) => ({ state: "excluded", reason });
  let url;
  try {
    if (typeof value !== "string" || /[\s\\]/.test(value)) return excluded("invalid_endpoint");
    url = new URL(value);
  } catch { return excluded("invalid_endpoint"); }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password ||
    url.search || url.hash || url.pathname !== "/" || (url.port && Number(url.port) < 1)) return excluded("unsupported_endpoint");
  if (url.hostname.includes(":")) return excluded("ipv6_not_supported");
  let addresses;
  if (net.isIP(url.hostname)) addresses = [url.hostname];
  else {
    let timer;
    try {
      const records = await Promise.race([
        lookup(url.hostname, { all: true, verbatim: true }),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timeout")), 5000); }),
      ]);
      addresses = [...new Set(records.map(({ address }) => address))];
    } catch { return excluded("dns_unavailable"); }
    finally { clearTimeout(timer); }
  }
  if (!addresses.length || !addresses.every(publicIpv4)) return excluded("non_public_or_unsupported_address");
  return { state: "eligible", origin: url.origin, addresses };
}

export async function participantCatalog(document, lookup) {
  if (!Array.isArray(document.participant) || !document.participant.length ||
    document.pagination?.next_key || document.participant.length > 100) throw new Error("incomplete_participant_registry");
  const seen = new Set();
  for (const row of document.participant) {
    if (!row || typeof row.address !== "string" || !/^gonka1[0-9a-z]+$/.test(row.address) ||
      seen.has(row.address) || typeof row.status !== "string") throw new Error("invalid_participant_identity");
    seen.add(row.address);
  }
  return Promise.all(document.participant.map(async ({ address, inference_url, status }) => ({
    address, inference_url: inference_url ?? null, status,
    endpoint: await endpointPolicy(inference_url, lookup),
  })));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    let input = "";
    for await (const chunk of process.stdin) input += chunk;
    process.stdout.write(JSON.stringify(await participantCatalog(JSON.parse(input))) + "\n");
  } catch (error) {
    console.error("Invalid preview participant registry: " + error.message);
    process.exitCode = 2;
  }
}
