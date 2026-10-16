import assert from "node:assert/strict";
import { endpointPolicy, participantCatalog } from "./preview-participant-catalog.mjs";

const lookup = async (host) => {
  if (host === "operator.example") return [{ address: "8.8.8.8" }];
  if (host === "mixed.example") return [{ address: "8.8.8.8" }, { address: "10.0.0.1" }];
  if (host === "private.example") return [{ address: "127.0.0.1" }];
  throw new Error("unexpected or unavailable DNS: " + host);
};
for (const value of ["https://31.192.105.46", "https://operator.example", "http://operator.example:8000"]) {
  assert.equal((await endpointPolicy(value, lookup)).state, "eligible", value);
}
for (const value of ["https://127.1", "https://169.254.169.254", "https://10.0.0.1", "https://100.64.0.1",
  "https://192.168.0.1", "https://[::1]", "https://mixed.example", "https://private.example", "https://missing.example",
  "file:///etc/passwd", "https://user:password@operator.example", "https://operator.example/admin",
  "https://operator.example?redirect=x", "https://operator.example#fragment", "https://operator.example:0",
  "https://operator.example:65536", "https://operator.example\\@127.0.0.1", null]) {
  assert.equal((await endpointPolicy(value, lookup)).state, "excluded", String(value));
}
const document = { participant: [
  { address: "gonka1one", status: "ACTIVE", inference_url: "https://operator.example" },
  { address: "gonka1two", status: "ACTIVE", inference_url: "https://operator.example" },
  { address: "gonka1three", status: "ACTIVE", inference_url: "https://127.0.0.1" },
] };
const catalog = await participantCatalog(document, lookup);
assert.deepEqual(catalog.map(row => row.address), ["gonka1one", "gonka1two", "gonka1three"]);
assert.deepEqual(catalog.map(row => row.endpoint.state), ["eligible", "eligible", "excluded"]);
assert.equal(catalog[2].endpoint.reason, "non_public_or_unsupported_address");
await assert.rejects(participantCatalog({ ...document, pagination: { next_key: "more" } }, lookup));
await assert.rejects(participantCatalog({ participant: [document.participant[0], document.participant[0]] }, lookup));
console.log("PASS registry identities survive shared domains, IP endpoints and excluded destinations");
