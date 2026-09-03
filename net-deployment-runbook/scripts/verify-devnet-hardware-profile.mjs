#!/usr/bin/env node
import { readFile } from "node:fs/promises";

const [profilePath, homepagePath] = process.argv.slice(2);
if (!profilePath || !homepagePath) {
  throw new Error(
    "usage: verify-devnet-hardware-profile.mjs PROFILE.json HOMEPAGE.html",
  );
}

const profile = JSON.parse(await readFile(profilePath, "utf8"));
const homepage = await readFile(homepagePath, "utf8");
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
const isObject = (value) =>
  Boolean(value) && typeof value === "object" && !Array.isArray(value);
const same = (actual, expected) =>
  JSON.stringify(actual) === JSON.stringify(expected);
const escapeHtml = (value) =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

assert(profile.schema_version === 1, "unsupported hardware profile schema");
assert(
  profile.kind === "external-test-lab-devnet-host-requirements",
  "unexpected hardware profile kind",
);
assert(profile.network === "gonka-devnet-community", "unexpected network");
assert(
  profile.deployment_profile === "community-lab",
  "unexpected deployment profile",
);
assert(
  profile.publication?.status === "informational" &&
    profile.publication?.automated_host_compliance === false,
  "hardware profile must remain informational until automated Host compliance is implemented",
);
assert(
  Array.isArray(profile.requirements) && profile.requirements.length === 10,
  "hardware profile must contain ten Host requirements",
);

const expectedIds = [
  "os",
  "gpu",
  "driver",
  "cuda",
  "cpu",
  "memory",
  "storage",
  "network",
  "ingress",
  "uptime",
];
assert(
  same(
    profile.requirements.map(({ id }) => id),
    expectedIds,
  ),
  "hardware requirements are missing, duplicated, or reordered",
);
for (const requirement of profile.requirements) {
  assert(
    typeof requirement.label === "string" && requirement.label.trim(),
    `requirement ${requirement.id} has no label`,
  );
  assert(
    typeof requirement.description === "string" &&
      requirement.description.trim() === requirement.description,
    `requirement ${requirement.id} has an invalid description`,
  );
  assert(
    !requirement.description.includes(";"),
    `requirement ${requirement.id} description contains a semicolon`,
  );
  assert(
    ["required", "declared_minimum", "practical_baseline"].includes(
      requirement.classification,
    ),
    `requirement ${requirement.id} has an invalid classification`,
  );
  assert(
    isObject(requirement.minimum) &&
      Object.keys(requirement.minimum).length > 0,
    `requirement ${requirement.id} has no structured minimum`,
  );
}

const requirements = Object.fromEntries(
  profile.requirements.map((requirement) => [requirement.id, requirement]),
);
assert(
  requirements.os.minimum.distribution === "ubuntu" &&
    same(requirements.os.minimum.versions, ["22.04", "24.04", "26.04"]) &&
    requirements.os.minimum.architecture === "amd64",
  "OS minimum is invalid",
);
assert(
  requirements.gpu.minimum.vendor === "nvidia" &&
    requirements.gpu.minimum.vram_gb === 16,
  "GPU minimum is invalid",
);
assert(
  requirements.driver.minimum.vendor === "nvidia" &&
    requirements.driver.minimum.branch === 580 &&
    requirements.driver.minimum.comparison === "greater_than_or_equal",
  "driver minimum is invalid",
);
assert(
  requirements.cuda.minimum.docker_cuda_version === "12.8" &&
    requirements.cuda.minimum.gpu_visible_in_container === true,
  "CUDA minimum is invalid",
);
assert(requirements.cpu.minimum.threads === 8, "CPU minimum is invalid");
assert(requirements.memory.minimum.ram_gb === 32, "memory minimum is invalid");
assert(
  requirements.storage.minimum.free_gib === 50 &&
    requirements.storage.recommended?.type === "nvme" &&
    requirements.storage.recommended?.capacity_gb?.minimum === 100 &&
    requirements.storage.recommended?.capacity_gb?.maximum === 150,
  "storage minimum or recommendation is invalid",
);
assert(
  requirements.network.minimum.stable_internet === true &&
    same(requirements.network.minimum.public_endpoint?.accepted, [
      "ipv4",
      "dns",
    ]) &&
    requirements.network.minimum.public_endpoint?.stable_address === true,
  "network minimum is invalid",
);
assert(
  same(requirements.ingress.minimum.tcp_ports, [80, 443, 5000]) &&
    same(requirements.ingress.minimum.tcp_services, ["ssh"]) &&
    same(requirements.ingress.minimum.udp_ports, [443]),
  "ingress minimum is invalid",
);
assert(
  requirements.uptime.minimum.always_on === true &&
    requirements.uptime.minimum.sleep_disabled === true &&
    requirements.uptime.minimum.stable_address === true,
  "uptime minimum is invalid",
);

const model = profile.model_context;
assert(isObject(model), "model context is missing");
assert(model.active_model === "Qwen/Qwen3-0.6B", "active model is invalid");
assert(
  model.on_chain_profile?.v_ram_gb === 16 &&
    model.on_chain_profile?.registry_url ===
      "https://node0.gonka-dev.net/chain-api/productscience/inference/inference/models_all",
  "on-chain model profile is invalid",
);
assert(
  model.qualification?.tool === "gdc" &&
    model.qualification?.models_endpoint === "/v1/models" &&
    same(model.qualification?.checks, [
      "model_load",
      "models_endpoint",
      "completion",
      "vram_evidence",
    ]),
  "runtime qualification description is invalid",
);
assert(
  model.experimental_example?.gpu === "NVIDIA GeForce RTX 3070" &&
    model.experimental_example?.vram_gb === 8 &&
    model.experimental_example?.may_run_experimentally === true &&
    model.experimental_example?.guaranteed_supported === false,
  "experimental GPU example is invalid",
);
assert(
  typeof model.description === "string" &&
    model.description.trim() === model.description &&
    !model.description.includes(";"),
  "model context description is invalid",
);

const tableMatch = homepage.match(
  /<table class="join-requirements-table">([\s\S]*?)<\/table>/u,
);
assert(tableMatch, "homepage Host requirements table is missing");
assert(
  tableMatch[1].includes(
    '<thead><tr><th scope="col">Component</th><th scope="col">Minimum</th></tr></thead>',
  ),
  "homepage Host requirements table headings are missing",
);
const bodyMatch = tableMatch[1].match(/<tbody>([\s\S]*?)<\/tbody>/u);
assert(bodyMatch, "homepage Host requirements table body is missing");
const renderedEntries = bodyMatch[1].match(/<tr>/gu) || [];
assert(
  renderedEntries.length === profile.requirements.length,
  "homepage Host requirements count differs from the profile",
);
for (const requirement of profile.requirements) {
  const expected = `<tr><th scope="row">${escapeHtml(requirement.label)}</th><td>${escapeHtml(requirement.description)}</td></tr>`;
  assert(
    bodyMatch[1].includes(expected),
    `homepage does not match requirement ${requirement.id}`,
  );
}
const noteMatch = homepage.match(
  /<p class="join-requirements-note">([\s\S]*?)<\/p>/u,
);
assert(noteMatch, "homepage Host requirements note is missing");
const allowedNoteTags = new Set([
  "<code>",
  "</code>",
  `<a href="${escapeHtml(model.on_chain_profile.registry_url)}" target="_blank" rel="noopener">`,
  "</a>",
]);
const noteText = [];
for (const token of noteMatch[1].split(/(<[^>]*>)/u)) {
  if (!token) continue;
  if (token.startsWith("<")) {
    assert(allowedNoteTags.has(token), `unexpected homepage note tag ${token}`);
  } else {
    assert(
      !token.includes("&"),
      "homepage note contains an unsupported entity",
    );
    noteText.push(token);
  }
}
assert(
  noteText.join("").split(/\s+/u).join(" ").trim() === model.description,
  "homepage model context differs from the hardware profile",
);

process.stdout.write(
  "PASS Community DevNet hardware profile and informational site projection\n",
);
