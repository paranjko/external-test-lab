// @flow strict

type GeoLocation = {
  latitude: number,
  longitude: number,
  rawLatitude?: number,
  rawLongitude?: number,
  displayLatitude?: number,
  displayLongitude?: number,
  displaySource?: "operator" | "ip-geolocation" | "land-adjusted" | "unknown",
  adjustmentKm?: number,
  city: string,
  country: string,
  isp: string,
  source?: "operator" | "ip-geolocation" | "unknown",
  resolvedIp?: string,
  observedAt?: string,
  accuracy?: string,
  locationId?: string,
  locationLabel?: string,
};

type SiteNode = {
  name: string,
  address?: string,
  publicHost?: string,
  statusBase?: string,
  ip?: string,
  geo?: ?GeoLocation,
  mode?: string,
  reason?: string,
  participantStatus?: string,
  participantState?: string,
  participantKnown?: boolean,
  validatorKnown?: boolean,
  votingPower?: string,
  endpointState?: string,
  endpointDiagnostic?: string,
  catchingUp?: boolean,
  blocksBehind?: number,
  blockAgeSeconds?: number,
  progressing?: ?boolean,
  referenceKnown?: boolean,
  referenceAgrees?: boolean,
  isOnline?: boolean,
  serverStatus?: string,
  gpuProfile?: ?string,
  gpuHost?: ?string,
};

type SiteConfig = {
  chainId: string,
  model: string,
  gatewayNode?: string,
  chainRpcHost?: string,
  chainRpcOrigin?: string,
  telegramBot?: string,
  grafana?: string,
  grafanaNetwork?: string,
  grafanaInference: string,
  nodes: Array<SiteNode>,
  nodeCatalog?: Array<SiteNode>,
};

type GatewayAvailability = {
  state: string,
  available: boolean,
  message: string,
  startedAt?: string,
};

type GatewayStateApi = {
  classify: (
    state: any,
    healthyNodes: number,
    probe: any,
    nowMs?: number,
    maxAgeMs?: number,
  ) => GatewayAvailability,
};

type HostStateApi = {
  isActiveParticipant: (status: mixed) => boolean,
  classify: (state: any) => {
    state: "validating" | "active" | "inactive" | "unknown",
    stateLabel: string,
    reason: string,
    primaryLabel: string,
    primaryClass: string,
    votingPower: string,
    endpointLabel: string,
    syncLabel: string,
    validatorEffective: boolean,
  },
  endpointDiagnostic: (error: mixed) => string,
};

type ValidatorMapController = {
  update: (nodes: Array<SiteNode>) => void,
};

type MarkerState = "inactive" | "active" | "validating" | "unknown";

type Participant = {
  address: string,
  inference_url: string,
  status?: string,
  validator_key?: string,
};

type ConsensusValidator = {
  pub_key?: { value?: string },
  voting_power?: string,
};

type ParticipantDiscovery = {
  statusBase?: string,
  ip?: string,
  geo?: ?GeoLocation,
};

type ParticipantDiscoveryCache = {
  result: Promise<ParticipantDiscovery>,
  retryAt: number,
};

type GpuInventory = Map<string, Array<string>>;
type SoftwareInventory = Map<string, Array<any>>;
type SoftwareVersionsApi = {
  normalizeMlNodeVersion: (chain: string, reported: string) => string,
};

declare var GDC_SOFTWARE_VERSIONS: SoftwareVersionsApi;
declare var L: any;

type Validator = {
  ownerAddress: string,
  ip: string,
  licenseCount: number,
  online: boolean,
  markerState: MarkerState,
  stateReason: string,
  geo: {
    lat: number,
    lon: number,
    city: string,
    country: string,
    isp: string,
    source: "operator" | "ip-geolocation" | "unknown",
    resolvedIp: string,
    observedAt: string,
    accuracy: string,
    locationId: string,
    locationLabel: string,
    rawLatitude: number,
    rawLongitude: number,
    displaySource: string,
    adjustmentKm: number,
  },
};

type ValidatorGroup = {
  key: string,
  lat: number,
  lon: number,
  label: string,
  validators: Array<Validator>,
};

type HTMLElement = any;
type KeyboardEvent = { key: string };
type RequestOptions = {
  cache?: string,
  headers?: { [string]: string },
  signal?: mixed,
};
type Response = {
  ok: boolean,
  status: number,
  json: () => Promise<any>,
  text: () => Promise<string>,
};

declare var window: any;
declare var document: any;
declare var Intl: any;
declare var getComputedStyle: any;
declare function fetch(url: string, options: RequestOptions): Promise<Response>;
declare class AbortController {
  signal: mixed;
  abort(): void;
}
declare class URL {
  constructor(url: string): void;
  hostname: string;
}

const cfg: SiteConfig = (window: any).GDC_CONFIG;
const siteBuild: any = (window: any).GDC_SITE_BUILD || {};
const gatewayStatus: GatewayStateApi = (window: any).GDC_GATEWAY_STATE;
const hostState: HostStateApi = (window: any).GDC_HOST_STATE;
const $ = (id: string): any => document.getElementById(id);
const chainRpcHost =
  cfg.chainRpcHost ||
  cfg.nodes.find((node) => node.name === cfg.gatewayNode)?.publicHost ||
  cfg.nodes[0]?.publicHost;
const chainRpcOrigin =
  cfg.chainRpcOrigin || (chainRpcHost ? `https://${chainRpcHost}` : "");
$("chain-id").textContent = cfg.chainId;
$("model-id").textContent = cfg.model;
async function refreshTelegramConsumer(): Promise<void> {
  const link = $("contact");
  link.hidden = true;
  link.removeAttribute("href");
  if (!cfg.telegramBot) return;
  link.textContent = "Open Telegram conversation client ↗";
  link.href = cfg.telegramBot;
  link.target = "_blank";
  link.rel = "noopener";
  link.hidden = false;
  try {
    const health = await json("/status/telegram-consumer");
    if (health.status !== "ok" || health.inference_ready !== true) {
      link.title =
        "The Telegram client is available; inference is temporarily unavailable.";
      return;
    }
    link.removeAttribute("title");
  } catch {}
}
$("grafana-network").href = cfg.grafanaNetwork || cfg.grafana;
$("grafana-inference").href = cfg.grafanaInference;
const cards: Map<string, HTMLElement> = new Map();
let observedNodes: Array<SiteNode> = cfg.nodes.map((node) => ({ ...node }));
let cardGpuInventory: GpuInventory = new Map();
let cardSoftwareInventory: SoftwareInventory = new Map();

function nodeKey(node: SiteNode): string {
  return node.address || node.name;
}

function createCard(node: SiteNode): HTMLElement {
  const el = document.createElement("article");
  el.className = `node ${node.mode || "active"}`;
  el.innerHTML = `
    <h3></h3>
    <div class="status" data-k="status"></div>
    <small data-k="status-reason"></small>
    <small data-k="scope"></small>
    <div class="metric">
      <span>height</span>
      <b data-k="height"></b>
    </div>
    <div class="metric">
      <span>voting power</span>
      <b data-k="vp"></b>
    </div>
    <div class="metric">
      <span>chain sync</span>
      <b data-k="sync"></b>
    </div>
    <div class="metric">
      <span>endpoint</span>
      <b data-k="endpoint"></b>
    </div>
    <div class="metric">
      <span>peers</span>
      <b data-k="peers"></b>
    </div>
    <div class="metric software" data-k-row="software">
      <span>software</span>
      <b data-k="versions"></b>
    </div>
    <div class="metric gpu" data-k-row="gpu" hidden>
      <span>GPU</span>
      <b data-k="gpu"></b>
    </div>
  `;
  el.querySelector("h3").textContent = node.publicHost || node.name;
  set(el, "status", node.mode === "skip" ? "SKIP" : "checking…");
  set(el, "scope", node.mode === "skip" ? node.reason : node.address);
  set(el, "height", node.mode === "skip" ? "–" : "…");
  set(el, "vp", node.mode === "skip" ? "Unavailable" : "Unavailable");
  set(el, "sync", node.mode === "skip" ? "Unknown" : "Unknown");
  set(el, "endpoint", node.mode === "skip" ? "Unknown" : "Unknown");
  set(el, "peers", node.mode === "skip" ? "–" : "…");
  if (node.mode === "skip") set(el, "versions", "not running");
  else updateSoftware(cardSoftwareInventory, node, el);
  updateGpu(cardGpuInventory, node, el);
  if (node.mode === "skip")
    el.querySelector('[data-k="status"]').className = "status skip";
  $("nodes").append(el);
  cards.set(nodeKey(node), el);
  return el;
}

function updateGpu(
  inventory: GpuInventory,
  node: SiteNode,
  card: HTMLElement,
): void {
  const row = card.querySelector('[data-k-row="gpu"]');
  const gpuHost = node.gpuHost || node.name;
  // A dynamically discovered participant has its public DNS name from the
  // chain, whereas the exporter labels the same machine with its SSH alias.
  // refreshGpuInventory indexes both labels, so prefer the explicit GPU host
  // but also allow the stable public hostname to identify local hardware.
  const inventoryKey = [gpuHost, node.publicHost, node.name].find((key) =>
    inventory.has(key || ""),
  );
  const names = inventory.get(inventoryKey || "") || [];
  const connection =
    node.gpuHost && node.gpuHost !== node.name ? "net" : "local";
  const countedNames: Map<string, number> = new Map();
  for (const name of names) {
    countedNames.set(name, (countedNames.get(name) || 0) + 1);
  }
  const inventoryLabel = [...countedNames.entries()]
    .map(([name, count]) => {
      const displayName = name.replace(/^NVIDIA\s+/i, "");
      return count === 1 ? displayName : `${displayName} ×${count}`;
    })
    .join(" + ");
  if (node.mode === "skip") {
    row.hidden = true;
    return;
  }
  row.hidden = false;
  if (!inventoryLabel) {
    const configuredProfile = configuredGpuLabel(node.gpuProfile);
    if (configuredProfile) {
      set(
        card,
        "gpu",
        `${configuredProfile} – ${connection} (inventory unavailable)`,
      );
      card.querySelector('[data-k="gpu"]').title =
        `Configured GPU host: ${gpuHost}; live inventory has not reported it yet`;
      return;
    }
    set(card, "gpu", "temporarily unavailable");
    card.querySelector('[data-k="gpu"]').title =
      "GPU inventory has not reported this Host yet";
    return;
  }
  set(card, "gpu", `${inventoryLabel} – ${connection}`);
  card.querySelector('[data-k="gpu"]').title = `GPU host: ${gpuHost}`;
}

function configuredGpuLabel(profile: ?string): ?string {
  switch (profile) {
    case "a5000-24g":
      return "RTX A5000";
    case "4090-24g":
      return "GeForce RTX 4090";
    case "3090-24g":
      return "GeForce RTX 3090";
    case "t4-16g":
      return "Tesla T4";
    case "blackwell-16g":
      return "RTX PRO 2000 Blackwell";
    default:
      return null;
  }
}

function markSoftwareInventoryUnavailable(card: HTMLElement): void {
  const value = card.querySelector('[data-k="versions"]');
  value.textContent = "temporarily unavailable";
  value.title = "Software inventory has not reported this Host yet";
}

function updateSoftware(
  inventory: SoftwareInventory,
  node: SiteNode,
  card: HTMLElement,
): void {
  const key = [node.name, node.publicHost].find((candidate) =>
    inventory.has(candidate || ""),
  );
  const samples = inventory.get(key || "") || [];
  const components: Map<string, any> = new Map();
  for (const sample of samples) {
    const metric = sample?.metric || {};
    const raw = String(metric.component || "");
    const component =
      raw === "inference-chain" || raw === "node"
        ? "chain"
        : raw === "decentralized-api" || raw === "api"
          ? "DAPI"
          : raw === "mlnode"
            ? "MLNode"
            : "";
    if (!component || !metric.version) continue;
    const existing = components.get(component);
    if (!existing || metric.source === "runtime")
      components.set(component, metric);
  }
  const formatted: Array<string> = [];
  const chainVersion = String(components.get("chain")?.version || "unknown");
  for (const component of ["chain", "DAPI", "MLNode"]) {
    const metric = components.get(component);
    if (!metric) continue;
    const version =
      component === "MLNode"
        ? GDC_SOFTWARE_VERSIONS.normalizeMlNodeVersion(
            chainVersion,
            String(metric.version),
          )
        : metric.version;
    formatted.push(`${component} ${version}`);
  }
  const value = formatted.join(" · ");
  if (!value) {
    markSoftwareInventoryUnavailable(card);
    return;
  }
  const target = card.querySelector('[data-k="versions"]');
  target.textContent = value;
  target.title = "Software inventory collected by the monitoring agent";
}

async function refreshSoftwareInventory(): Promise<void> {
  const state = await json("/status/software");
  const next: SoftwareInventory = new Map();
  for (const sample of state?.data?.result || []) {
    const host = String(sample?.metric?.host || "");
    if (!host) continue;
    const values = next.get(host) || [];
    values.push(sample);
    next.set(host, values);
  }
  cardSoftwareInventory = next;
  for (const node of observedNodes) {
    const card = cards.get(nodeKey(node));
    if (card) updateSoftware(cardSoftwareInventory, node, card);
  }
}

async function refreshGpuInventory(): Promise<void> {
  const state = await json("/status/gpus");
  const next: GpuInventory = new Map();
  for (const sample of state?.data?.result || []) {
    const host = String(sample?.metric?.host || "");
    const instanceHost = String(sample?.metric?.instance || "").replace(
      /:\\d+$/,
      "",
    );
    const name = String(sample?.metric?.gpu_name || "");
    if (!host || !name) continue;
    for (const key of new Set([host, instanceHost])) {
      if (!key) continue;
      const names = next.get(key) || [];
      names.push(name);
      next.set(key, names);
    }
  }
  cardGpuInventory = next;
  for (const node of observedNodes) {
    const card = cards.get(nodeKey(node));
    if (card) updateGpu(cardGpuInventory, node, card);
  }
}
for (const node of observedNodes) createCard(node);
async function response(
  url: string,
  options: RequestOptions = {},
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 8000);
  try {
    const r = await fetch(url, {
      ...options,
      cache: "no-store",
      signal: controller.signal,
    });
    if (!r.ok) throw new Error(`${r.status}`);
    return r;
  } finally {
    clearTimeout(timer);
  }
}
async function json(url: string, options: ?RequestOptions): Promise<any> {
  return (await response(url, options || {})).json();
}

async function text(url: string): Promise<string> {
  return (await response(url)).text();
}

function set(card: HTMLElement, key: string, value: mixed): void {
  card.querySelector(`[data-k="${key}"]`).textContent = value;
}

const siteRevision = $("site-revision");
if (
  siteRevision &&
  typeof siteBuild.revision === "string" &&
  /^[0-9a-f]{40}$/.test(siteBuild.revision) &&
  typeof siteBuild.artifactDigest === "string" &&
  /^[0-9a-f]{64}$/.test(siteBuild.artifactDigest) &&
  typeof siteBuild.appDigest === "string" &&
  /^[0-9a-f]{64}$/.test(siteBuild.appDigest)
) {
  siteRevision.setAttribute("data-revision", siteBuild.revision);
  siteRevision.setAttribute("data-artifact-digest", siteBuild.artifactDigest);
  siteRevision.setAttribute("data-app-digest", siteBuild.appDigest);
}

function setUtcTime(id: string, date: Date, label: string): void {
  const el = $(id);
  el.dateTime = date.toISOString();
  const value = new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC",
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  })
    .format(date)
    .replace(",", "");
  el.textContent = `${label} ${value} UTC`;
}
function setRecoveryMessage(
  el: HTMLElement,
  availability: GatewayAvailability,
): void {
  el.replaceChildren(document.createTextNode(availability.message));
  const started = new Date(availability.startedAt || "");
  if (!Number.isFinite(started.getTime())) return;
  const time = document.createElement("time");
  const value = new Intl.DateTimeFormat("en-GB", {
    timeZone: "UTC",
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  })
    .format(started)
    .replace(",", "");
  time.dateTime = started.toISOString();
  time.textContent = `started ${value} UTC`;
  el.append(" – ", time);
}
function escapeHtml(value: mixed): string {
  const entities: { [string]: string } = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  };
  return String(value).replace(/[&<>'"]/g, (char) => entities[char]);
}

function markerStateLabel(state: MarkerState): string {
  switch (state) {
    case "validating":
      return "Validating";
    case "active":
      return "Active – not validating";
    case "unknown":
      return "Unknown – status unavailable";
    default:
      return "Inactive";
  }
}

function markerStateSummary(validators: Array<Validator>): string {
  const counts: { [MarkerState]: number } = {
    validating: 0,
    active: 0,
    inactive: 0,
    unknown: 0,
  };
  for (const validator of validators) counts[validator.markerState] += 1;
  return (["validating", "active", "inactive", "unknown"]: Array<MarkerState>)
    .filter((state) => counts[state] > 0)
    .map((state) => `${counts[state]} ${markerStateLabel(state).toLowerCase()}`)
    .join(" · ");
}

function renderHostState(card: HTMLElement, node: SiteNode): boolean {
  const display = displayHostState(node);
  set(card, "status", display.primaryLabel);
  set(card, "status-reason", display.reason);
  card.querySelector('[data-k="status"]').className = display.primaryClass;
  set(card, "vp", display.votingPower);
  set(card, "sync", display.syncLabel);
  set(card, "endpoint", display.endpointLabel);
  return display.validatorEffective;
}

function displayHostState(node: SiteNode): any {
  return hostState.classify({
    // Map fixture and a temporarily cached participant may have the public
    // status before the validator query completes. Use that observed status as
    // the fallback fact, not a separate marker-only state machine.
    participantKnown:
      node.participantKnown === undefined
        ? Boolean(node.participantState || node.participantStatus)
        : node.participantKnown,
    participantStatus: node.participantState || node.participantStatus,
    validatorKnown:
      node.validatorKnown === undefined
        ? Boolean(node.isOnline !== undefined || node.votingPower !== undefined)
        : node.validatorKnown,
    votingPower:
      node.votingPower === undefined
        ? node.isOnline === true || String(node.participantState).toUpperCase() === "ACTIVE"
          ? "1"
          : "0"
        : node.votingPower,
    endpointState:
      node.endpointState || (node.isOnline === true ? "reachable" : "unknown"),
    endpointDiagnostic: node.endpointDiagnostic,
    catchingUp: node.catchingUp || false,
    blocksBehind: node.blocksBehind === undefined ? 0 : node.blocksBehind,
    blockAgeSeconds:
      node.blockAgeSeconds === undefined ? 0 : node.blockAgeSeconds,
    progressing: node.progressing,
    referenceKnown: node.referenceKnown,
    referenceAgrees: node.referenceAgrees,
  });
}

const MAX_DYNAMIC_GEOIP_ADDRESSES = 4;
const GEOIP_FAILURE_RETRY_MS = 5 * 60 * 1000;
const participantDiscovery: Map<string, ParticipantDiscoveryCache> = new Map();

async function discoverParticipant(
  host: string,
): Promise<ParticipantDiscovery> {
  if (!host) return {};
  const cached = participantDiscovery.get(host);
  if (cached && (cached.retryAt === 0 || cached.retryAt > Date.now()))
    return cached.result;
  const discovery: Promise<ParticipantDiscovery> = (async () => {
    const statusBase = `https://${host}`;
    const dns = await json(
      `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=A`,
      { headers: { accept: "application/dns-json" } },
    );
    const ips = [...new Set(
      (dns.Answer || [])
        .map((answer) => String(answer.data || ""))
        .filter((value) => /^(?:\d{1,3}\.){3}\d{1,3}$/.test(value)),
    )];
    if (!ips.length) return { statusBase, ip: "", geo: null };
    if (ips.length > MAX_DYNAMIC_GEOIP_ADDRESSES)
      return { statusBase, ip: ips.join(", "), geo: null };
    const locations = await Promise.all(
      ips.map(async (ip) => {
        const location = await json(`https://ipwho.is/${encodeURIComponent(ip)}`);
        const latitude = Number(location.latitude);
        const longitude = Number(location.longitude);
        return location.success === true && Number.isFinite(latitude) && Number.isFinite(longitude)
          ? { latitude, longitude, city: location.city || "Unknown", country: location.country || "Unknown", isp: location.connection?.isp || "unknown", resolvedIp: ip }
          : null;
      }),
    );
    const known = locations.filter(Boolean);
    const labels = new Set(known.map((location) => `${location?.city}\u0000${location?.country}`));
    // Multiple A records with different GeoIP cities are not a location. Do
    // not place an apparently precise marker by silently selecting one of them.
    if (known.length !== ips.length || labels.size !== 1)
      return { statusBase, ip: ips.join(", "), geo: null };
    const location: any = known[0];
    return {
      statusBase,
      ip: location.resolvedIp,
      geo: {
        ...location,
        source: "ip-geolocation",
        observedAt: new Date().toISOString(),
        accuracy: "city",
        locationLabel: `${location.city}, ${location.country}`,
      },
    };
  })();
  participantDiscovery.set(host, { result: discovery, retryAt: 0 });
  try {
    return await discovery;
  } catch {
    const failure: ParticipantDiscovery = {
      statusBase: `https://${host}`,
      ip: "",
      geo: null,
    };
    participantDiscovery.set(host, {
      result: Promise.resolve(failure),
      retryAt: Date.now() + GEOIP_FAILURE_RETRY_MS,
    });
    return failure;
  }
}

async function participantNode(
  participant: Participant,
  validators: Map<string, ConsensusValidator>,
  validatorKnown: boolean,
): Promise<SiteNode> {
  let endpoint;
  try {
    endpoint = new URL(participant.inference_url);
  } catch {
    endpoint = null;
  }
  const host = endpoint?.hostname || "";
  const catalogEntries = cfg.nodeCatalog || cfg.nodes;
  const byAddress = catalogEntries.find((node) => node.address === participant.address);
  const byHost = catalogEntries.filter((node) => node.publicHost === host);
  const catalog = byAddress || (byHost.length === 1 ? byHost[0] : null);
  const discovered =
    !catalog || !catalog.ip || !catalog.geo
      ? await discoverParticipant(host)
      : {};
  const participantStatus = participant.status || "UNKNOWN";
  const validator = validators.get(String(participant.validator_key || ""));
  return {
    name: catalog?.name || host || `${participant.address.slice(0, 10)}…`,
    address: participant.address,
    publicHost: catalog?.publicHost || host,
    statusBase: catalog?.statusBase || discovered.statusBase || "",
    ip: catalog?.ip || discovered.ip || "",
    geo: catalog?.geo || discovered.geo || null,
    mode: catalog?.mode,
    reason: catalog?.reason,
    participantStatus: String(participantStatus),
    participantState: String(participantStatus),
    participantKnown: Boolean(participant.status),
    validatorKnown,
    votingPower: validator ? String(validator.voting_power || "") : "0",
    endpointState: "unknown",
    endpointDiagnostic: "Check endpoint",
    isOnline: false,
    serverStatus: String(participantStatus),
    gpuProfile: catalog?.gpuProfile,
    gpuHost: catalog?.gpuHost,
  };
}

async function reconcileParticipants(): Promise<number> {
  if (!chainRpcOrigin) throw new Error("chain RPC origin is missing");
  const [participantResult, validatorResult] = await Promise.allSettled([
    json("/status/participants"),
    json(`${chainRpcOrigin}/chain-rpc/validators?per_page=100`),
  ]);
  if (participantResult.status !== "fulfilled") {
    observedNodes = observedNodes.map((node) => ({
      ...node,
      participantKnown: false,
      validatorKnown: false,
      votingPower: "",
    }));
    for (const node of observedNodes) {
      const card = cards.get(nodeKey(node));
      if (card) renderHostState(card, node);
    }
    return 0;
  }
  const state = participantResult.value;
  const validatorKnown =
    validatorResult.status === "fulfilled" &&
    Array.isArray(validatorResult.value?.result?.validators);
  const validatorResponse = validatorKnown ? validatorResult.value : {};
  const participants = Array.isArray(state.participant)
    ? state.participant
    : [];
  const validators: Map<string, ConsensusValidator> = new Map(
    (validatorResponse?.result?.validators || [])
      .filter((validator) => validator?.pub_key?.value)
      .map((validator) => [String(validator.pub_key.value), validator]),
  );
  const next = (
    await Promise.all(
      participants.map((participant) =>
        participantNode(participant, validators, validatorKnown),
      ),
    )
  ).sort((left, right) => left.name.localeCompare(right.name));
  const liveKeys = new Set(next.map(nodeKey));
  for (const [key, card] of cards) {
    if (!liveKeys.has(key)) {
      card.remove();
      cards.delete(key);
    }
  }
  for (const node of next) {
    let card = cards.get(nodeKey(node));
    if (!card) card = createCard(node);
    card.querySelector("h3").textContent = node.publicHost || node.name;
    set(card, "scope", node.address);
    renderHostState(card, node);
  }
  observedNodes = next;
  return Number(state.block_height) || 0;
}

let validatorMapController: ?ValidatorMapController;

const WORLD_BOUNDS = [
  [-90, -180],
  [90, 180],
];

const DYNAMIC_LOCATION_CELLS_PER_DEGREE = 4;
const initialZoomOffset = 0.7;
const initialVerticalOffset = 80;
const dynamicLocationCenters: Map<string, MapCoordinate> = new Map();
type MapCoordinate = { lat: number, lon: number, ... };

function geoDistanceKm(
  left: MapCoordinate,
  right: MapCoordinate,
): number {
  const radians = Math.PI / 180;
  const dLat = (right.lat - left.lat) * radians;
  const dLon = (right.lon - left.lon) * radians;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(left.lat * radians) *
      Math.cos(right.lat * radians) *
      Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function centroid(validators: Array<Validator>): MapCoordinate {
  if (validators.length === 1)
    return { lat: validators[0].geo.lat, lon: validators[0].geo.lon };
  const radians = Math.PI / 180;
  const lat =
    validators.reduce((sum, validator) => sum + validator.geo.lat, 0) /
    validators.length;
  const x =
    validators.reduce(
      (sum, validator) => sum + Math.cos(validator.geo.lon * radians),
      0,
    ) / validators.length;
  const y =
    validators.reduce(
      (sum, validator) => sum + Math.sin(validator.geo.lon * radians),
      0,
    ) / validators.length;
  return { lat, lon: Math.atan2(y, x) / radians };
}

function groupValidators(validators: Array<Validator>): Array<ValidatorGroup> {
  const groups: Array<ValidatorGroup> = [];
  const dynamic: Map<string, ValidatorGroup> = new Map();
  const sorted = validators.slice().sort((left, right) =>
    `${left.geo.lat}\u0000${left.geo.lon}\u0000${left.ownerAddress}`.localeCompare(
      `${right.geo.lat}\u0000${right.geo.lon}\u0000${right.ownerAddress}`,
    ),
  );
  for (const validator of sorted) {
    const locationId = validator.geo.locationId;
    if (locationId) {
      let group = groups.find(
        (candidate) => candidate.key === `location:${locationId}`,
      );
      if (!group) {
        group = {
          key: `location:${locationId}`,
          lat: validator.geo.lat,
          lon: validator.geo.lon,
          label: validator.geo.locationLabel || locationId,
          validators: [],
        };
        groups.push(group);
      }
      group.validators.push(validator);
      continue;
    }
    const latCell = Math.floor(
      (validator.geo.lat + 90) * DYNAMIC_LOCATION_CELLS_PER_DEGREE,
    );
    const lonCell = Math.floor(
      (validator.geo.lon + 180) * DYNAMIC_LOCATION_CELLS_PER_DEGREE,
    );
    const key = `dynamic:${latCell}:${lonCell}`;
    let group = dynamic.get(key);
    if (!group) {
      group = { key, lat: validator.geo.lat, lon: validator.geo.lon, label: "", validators: [] };
      dynamic.set(key, group);
    }
    group.validators.push(validator);
    const center = centroid(group.validators);
    group.lat = center.lat;
    group.lon = center.lon;
  }
  for (const group of dynamic.values()) {
    // Dynamic GeoIP is city-level evidence. A fixed tenth-degree display cell
    // keeps the marker and its keyboard/popup identity stable while members
    // enter or leave that observed location.
    group.lat = Math.round(group.lat * 10) / 10;
    group.lon = Math.round(group.lon * 10) / 10;
    const locations = [
      ...new Set(
        group.validators.map(
          (validator) => `${validator.geo.city}, ${validator.geo.country}`,
        ),
      ),
    ];
    group.label = locations.length === 1 ? locations[0] : "Multiple locations";
    const retainedCenter = dynamicLocationCenters.get(group.key);
    if (retainedCenter) {
      group.lat = retainedCenter.lat;
      group.lon = retainedCenter.lon;
    } else {
      dynamicLocationCenters.set(group.key, { lat: group.lat, lon: group.lon });
    }
    groups.push(group);
  }
  const coincident: Map<string, ValidatorGroup> = new Map();
  for (const group of groups) {
    const coordinate = `${group.lat.toFixed(6)},${group.lon.toFixed(6)}`;
    const existing = coincident.get(coordinate);
    if (!existing) {
      coincident.set(coordinate, group);
      continue;
    }
    existing.validators.push(...group.validators);
    existing.label = [...new Set([existing.label, group.label])].join(" · ");
    existing.key = `coincident:${[existing.key, group.key].sort().join("|")}`;
  }
  return [...coincident.values()];
}

async function initValidatorMap(): Promise<?ValidatorMapController> {
  if (typeof window === "undefined") return;
  const container = $("validator-map");
  const shell = $("validator-map-shell");
  const button = $("validator-map-fullscreen");
  if (!container || !shell || !button) return;
  if (!L) throw new Error("local Leaflet is unavailable");
  const worldBounds = L.latLngBounds(WORLD_BOUNDS);
  const map = L.map(container, {
    crs: L.CRS.EPSG4326,
    center: [0, 0],
    zoom: 0,
    minZoom: -2,
    maxZoom: 6,
    zoomSnap: 0.05,
    scrollWheelZoom: false,
    worldCopyJump: false,
    zoomControl: true,
    attributionControl: false,
  });
  L.imageOverlay("world-map.svg", worldBounds, {
    interactive: false,
    className: "validator-map-world",
  }).addTo(map);
  let clampingWorld = false;
  let popupOpen = false;
  let restoreWorld = (): void => {};
  map.on("moveend", () => {
    const popupElement = container.querySelector(".leaflet-popup");
    if (
      clampingWorld ||
      popupOpen ||
      popupElement ||
      worldBounds.contains(map.getBounds())
    )
      return;
    clampingWorld = true;
    map.panInsideBounds(worldBounds, { animate: false });
    window.requestAnimationFrame(() => {
      clampingWorld = false;
    });
  });
  let landMask: ?any;
  const pointFromPixel = (x: number, y: number): MapCoordinate => ({
    lat: 90 - (y / 1000) * 180,
    lon: (x / 2000) * 360 - 180,
  });
  const pixelFromPoint = (point: MapCoordinate): { x: number, y: number } => ({
    x: Math.round(((point.lon + 180) / 360) * 2000),
    y: Math.round(((90 - point.lat) / 180) * 1000),
  });
  const landAt = (x: number, y: number): boolean =>
    Boolean(
      landMask &&
        x >= 0 &&
        x < landMask.width &&
        y >= 0 &&
        y < landMask.height &&
        landMask.data[(y * landMask.width + x) * 4 + 3] > 0,
    );
  const displayPosition = (geo: GeoLocation): ?{
    lat: number,
    lon: number,
    displaySource: string,
    adjustmentKm: number,
  } => {
    const raw = {
      lat: Number(geo.rawLatitude ?? geo.latitude),
      lon: Number(geo.rawLongitude ?? geo.longitude),
    };
    if (!Number.isFinite(raw.lat) || !Number.isFinite(raw.lon)) return null;
    if (geo.source !== "ip-geolocation") {
      return {
        lat: Number(geo.displayLatitude ?? raw.lat),
        lon: Number(geo.displayLongitude ?? raw.lon),
        displaySource: geo.displaySource || geo.source || "unknown",
        adjustmentKm: Number(geo.adjustmentKm || 0),
      };
    }
    // Dynamic GeoIP is only an approximate observation. Keep it unchanged if
    // it already lands on the local basemap; otherwise accept the closest land
    // pixel within 80 km and omit locations that cannot meet that bound.
    if (!landMask) return null;
    const rawPixel = pixelFromPoint(raw);
    let closest: ?MapCoordinate;
    let closestKm = Number.POSITIVE_INFINITY;
    for (let dy = -16; dy <= 16; dy += 1) {
      for (let dx = -16; dx <= 16; dx += 1) {
        const x = rawPixel.x + dx;
        const y = rawPixel.y + dy;
        if (!landAt(x, y)) continue;
        const candidate = pointFromPixel(x, y);
        const km = geoDistanceKm(raw, candidate);
        if (km <= 80 && km < closestKm) {
          closest = candidate;
          closestKm = km;
        }
      }
    }
    if (!closest) return null;
    return {
      lat: closest.lat,
      lon: closest.lon,
      displaySource: closestKm > 0.1 ? "land-adjusted" : "ip-geolocation",
      adjustmentKm: Math.round(closestKm * 10) / 10,
    };
  };
  map.createPane("validatorHits");
  map.getPane("validatorHits").style.zIndex = "410";
  map.getPane("validatorHits").style.pointerEvents = "auto";
  map.createPane("validatorMarkers");
  map.getPane("validatorMarkers").style.zIndex = "420";
  const markers = L.layerGroup().addTo(map);
  const markerRegistry: Map<string, any> = new Map();
  let latestMapNodes: Array<SiteNode> = observedNodes;
  let openMarkerKey: ?string;
  let tooltipMarker: ?any;
  let resizeFrame: ?number;
  const openMarkerPopup = (key: string, marker: any): void => {
    for (const [otherKey, otherMarker] of markerRegistry) {
      if (otherKey !== key && otherMarker.isPopupOpen()) otherMarker.closePopup();
      const popup = otherMarker.getPopup();
      if (popup) map.removeLayer(popup);
    }
    map.eachLayer((layer: any) => {
      if (layer instanceof L.Popup) map.closePopup(layer);
    });
    map.closePopup();
    // Leaflet can retain a detached bound-popup element while a marker layer
    // is reconciled. This map owns its popup pane, so clear only that pane
    // before attaching the one current popup.
    map.getPane("popupPane")?.replaceChildren();
    popupOpen = true;
    openMarkerKey = key;
    marker.openPopup();
  };
  const nearestMarkerAt = (event: any): ?any => {
    const pointerEvent = event.originalEvent || event;
    let nearest: ?any;
    for (const [key, marker] of markerRegistry) {
      const element = marker.getElement();
      if (!element) continue;
      const rect = element.getBoundingClientRect();
      const distance = Math.hypot(
        rect.left + rect.width / 2 - pointerEvent.clientX,
        rect.top + rect.height / 2 - pointerEvent.clientY,
      );
      if (
        distance <= 14 &&
        (!nearest ||
          distance < nearest.distance ||
          (distance === nearest.distance && key < nearest.key))
      )
        nearest = { key, marker, distance };
    }
    return nearest;
  };
  const isMarkerHitEvent = (event: any): boolean => {
    const target = (event.originalEvent || event).target;
    return Boolean(target?.closest?.(".validator-marker-hit"));
  };
  const showNearestTooltip = (event: any): void => {
    if (!isMarkerHitEvent(event)) {
      closeNearestTooltip();
      return;
    }
    const nearest = nearestMarkerAt(event);
    if (!nearest) return;
    if (tooltipMarker && tooltipMarker !== nearest.marker)
      tooltipMarker.closeTooltip();
    tooltipMarker = nearest.marker;
    nearest.marker.openTooltip();
  };
  const activateNearest = (event: any): void => {
    if (!isMarkerHitEvent(event)) return;
    const nearest = nearestMarkerAt(event);
    if (!nearest) return;
    openMarkerPopup(nearest.key, nearest.marker);
  };
  const closeNearestTooltip = (): void => {
    tooltipMarker?.closeTooltip();
    tooltipMarker = null;
  };
  // The transparent hit circles overlap by design. Capture only their browser
  // events before Leaflet dispatches to an arbitrary topmost SVG path, then
  // choose the closest visible marker ourselves. Controls remain controls.
  container.addEventListener("click", activateNearest, true);
  container.addEventListener("mousemove", showNearestTooltip, true);
  container.addEventListener("mouseleave", closeNearestTooltip, true);
  const popupMarkerKey = (): ?string => {
    for (const [key, marker] of markerRegistry) {
      if (marker.isPopupOpen()) return key;
    }
    return null;
  };
  map.on("popupopen", (event: any) => {
    for (const [key, marker] of markerRegistry) {
      if (marker.getPopup() === event.popup) {
        popupOpen = true;
        openMarkerKey = key;
        const popup: any = event.popup;
        window.requestAnimationFrame(() => {
          if (
            marker.isPopupOpen() &&
            typeof popup._adjustPan === "function"
          )
            popup._adjustPan();
        });
        return;
      }
    }
  });
  map.on("popupclose", (event: any) => {
    const closedMarkerKey = openMarkerKey;
    const marker: any = openMarkerKey
      ? markerRegistry.get(openMarkerKey)
      : null;
    if (marker?.getPopup() === event.popup)
      window.requestAnimationFrame(() => {
        if (marker.isPopupOpen() || openMarkerKey !== closedMarkerKey) return;
        openMarkerKey = null;
        if (!popupMarkerKey()) {
          popupOpen = false;
          restoreWorld();
        }
      });
  });
  const gridStyle = { color: "#73788e", weight: 1, opacity: 0.35 };
  for (let latitude = -60; latitude <= 60; latitude += 30)
    L.polyline(
      [
        [latitude, -180],
        [latitude, 180],
      ],
      gridStyle,
    ).addTo(map);
  for (let longitude = -150; longitude <= 150; longitude += 30)
    L.polyline(
      [
        [-90, longitude],
        [90, longitude],
      ],
      gridStyle,
    ).addTo(map);
  const fitWorld = (): void => {
    map.invalidateSize({ animate: false, pan: false });
    const size = map.getSize();
    const isFullscreen = shell.classList.contains("is-fullscreen");
    const worldPixels = isFullscreen
      ? Math.max(1, Math.min(size.x - 32, (size.y - 32) * 2))
      : Math.max(1, Math.min(size.x - 16, size.y * 2 - 16));
    // The local EPSG:4326 overlay is 512 CSS pixels wide at zoom zero. The
    // normal map keeps its established visual offset, while fullscreen must
    // fit the world itself so a narrow viewport cannot lose a valid marker.
    const zoomOffset = isFullscreen ? 0 : initialZoomOffset;
    const requestedZoom = Math.log2(worldPixels / 512) + zoomOffset;
    const step = map.options.zoomSnap || 1;
    const zoom = Math.floor(requestedZoom / step) * step;
    // The former desktop minimum must not prevent a smaller viewport from
    // fitting the whole world before its new minimum is installed.
    map.setMinZoom(-2);
    map.setView([0, 0], zoom, { animate: false });
    map.panBy([0, isFullscreen ? 0 : -initialVerticalOffset], {
      animate: false,
    });
    map.setMinZoom(zoom);
  };
  restoreWorld = (): void => {
    if (worldBounds.contains(map.getBounds())) return;
    clampingWorld = true;
    map.panInsideBounds(worldBounds, { animate: false });
    window.requestAnimationFrame(() => {
      clampingWorld = false;
    });
  };

  const setFullscreen = (open: boolean): void => {
    shell.classList.toggle("is-fullscreen", open);
    document.body.classList.toggle("validator-map-fullscreen-open", open);
    button.setAttribute("aria-pressed", String(open));
    button.textContent = open ? "Close" : "Fullscreen";
    window.requestAnimationFrame(fitWorld);
  };

  button.addEventListener("click", () =>
    setFullscreen(!shell.classList.contains("is-fullscreen")),
  );
  const onKeydown = (event: any): void => {
    if (event.key !== "Escape") return;
    if (shell.classList.contains("is-fullscreen")) {
      setFullscreen(false);
      button.focus();
      event.preventDefault();
      return;
    }
    const popupKey = openMarkerKey || popupMarkerKey();
    const popupOpen = popupKey || document.querySelector(".leaflet-popup");
    if (popupOpen) {
      let marker = popupKey ? markerRegistry.get(popupKey) : null;
      if (!marker)
        for (const candidate of markerRegistry.values()) {
          if (candidate.getElement() === document.activeElement) {
            marker = candidate;
            break;
          }
        }
      marker?.closePopup();
      map.closePopup();
      const closeButton = document.querySelector(".leaflet-popup-close-button");
      if (closeButton && typeof closeButton.click === "function")
        closeButton.click();
      const popup = document.querySelector(".leaflet-popup");
      if (popup && !marker?.isPopupOpen()) popup.remove();
      marker?.getElement()?.focus();
      openMarkerKey = null;
      event.preventDefault();
      event.stopPropagation();
    }
  };
  document.addEventListener("keydown", onKeydown, true);
  const observer = new window.ResizeObserver(() => {
    if (resizeFrame != null) window.cancelAnimationFrame(resizeFrame);
    resizeFrame = window.requestAnimationFrame(() => {
      resizeFrame = null;
      fitWorld();
    });
  });
  observer.observe(container);

  const update = (nodes: Array<SiteNode>): void => {
    latestMapNodes = nodes;
    const retainedPopupKey = openMarkerKey || popupMarkerKey();
    const validators: Array<Validator> = [];
    let validatorCount = 0;
    for (const node of nodes) {
      const geo = node.geo;
      if (!geo) continue;
      const position = displayPosition(geo);
      if (!position) continue;
      const latitude = position.lat;
      const longitude = position.lon;
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) continue;
      const display = displayHostState(node);
      const validator: Validator = {
        ownerAddress: node.address || "",
        ip: node.ip || "",
        licenseCount: 0,
        online: node.isOnline === true,
        markerState: display.state,
        stateReason: display.reason,
        geo: {
          lat: Math.max(-90, Math.min(90, latitude)),
          lon: Math.max(-180, Math.min(180, longitude)),
          city: geo.city || "Unknown",
          country: geo.country || "Unknown",
          isp: geo.isp || "unknown",
          source: geo.source || "unknown",
          resolvedIp: geo.resolvedIp || node.ip || "",
          observedAt: geo.observedAt || "",
          accuracy: geo.accuracy || "unknown",
          locationId: geo.locationId || "",
          locationLabel: geo.locationLabel || "",
          rawLatitude: Number(geo.rawLatitude ?? geo.latitude),
          rawLongitude: Number(geo.rawLongitude ?? geo.longitude),
          displaySource: position.displaySource,
          adjustmentKm: position.adjustmentKm,
        },
      };
      validators.push(validator);
      validatorCount += 1;
    }
    const groups = new Map(
      groupValidators(validators).map((group) => [group.key, group]),
    );
    for (const [key, marker] of markerRegistry) {
      if (groups.has(key)) continue;
      if (openMarkerKey === key) map.closePopup();
      if (marker.__countLabel) markers.removeLayer(marker.__countLabel);
      if (marker.__hitTarget) markers.removeLayer(marker.__hitTarget);
      markers.removeLayer(marker);
      markerRegistry.delete(key);
    }
    for (const [key, group] of groups) {
      const validators = group.validators;
      const first = validators
        .slice()
        .sort((left, right) =>
          `${left.geo.city}\u0000${left.geo.country}\u0000${left.ownerAddress}`.localeCompare(
            `${right.geo.city}\u0000${right.geo.country}\u0000${right.ownerAddress}`,
          ),
        )[0];
      const count = validators.length;
      const markerState: MarkerState = validators.some(
        (validator) => validator.markerState === "inactive",
      )
        ? "inactive"
        : validators.some((validator) => validator.markerState === "active")
          ? "active"
          : validators.some((validator) => validator.markerState === "validating")
            ? "validating"
            : "unknown";
      const stateLabel = markerStateLabel(markerState);
      const stateSummary = markerStateSummary(validators);
      const stateReasons = [
        ...new Set(validators.map((validator) => validator.stateReason)),
      ];
      const rows = validators
        .map(
          (v) =>
            `<li><span>${escapeHtml(v.geo.resolvedIp || v.ip || "IP unavailable")}</span><span>${escapeHtml(v.ownerAddress.slice(0, 10))}</span><span>${escapeHtml(v.licenseCount)}</span></li>`,
        )
        .join("");
      const sources = [...new Set(validators.map((v) => v.geo.source))]
        .map((source) =>
          source === "operator"
            ? "Operator-provided location"
            : source === "ip-geolocation"
              ? "IP geolocation snapshot"
              : "Unknown location source",
        )
        .join(", ");
      const observed = [...new Set(validators.map((v) => v.geo.observedAt).filter(Boolean))].join(", ");
      const accuracy = [...new Set(validators.map((v) => v.geo.accuracy).filter(Boolean))].join(", ");
      const adjustments = [
        ...new Set(
          validators.map((v) => v.geo.adjustmentKm).filter((km) => km > 0),
        ),
      ];
      const correction = adjustments.length
        ? `<p>Display correction: ${escapeHtml(adjustments.join(", "))} km to nearby land</p>`
        : "";
      const rawPositions = [
        ...new Set(
          validators.map(
            (v) =>
              `${v.geo.rawLatitude.toFixed(4)}, ${v.geo.rawLongitude.toFixed(4)} (${v.geo.displaySource})`,
          ),
        ),
      ];
      const popupHtml = `<strong>${escapeHtml(group.label)}</strong><p class="status validator-map-status--${markerState}">${escapeHtml(
        stateLabel,
      )}</p><p>${escapeHtml(stateSummary)}</p><p>${escapeHtml(stateReasons.join(" · "))}</p><p>${count} validator${count === 1 ? "" : "s"} at this location</p><p>Location source: ${escapeHtml(sources)}</p><p>Raw position: ${escapeHtml(rawPositions.join("; "))}</p><p>Accuracy: ${escapeHtml(accuracy || "unknown")}${observed ? `; observed ${escapeHtml(observed)}` : ""}</p>${correction}<ul>${rows}</ul>`;
      const radius = count === 1 ? 2.5 : Math.min(2.5 * Math.sqrt(count), 9);
      const color =
        markerState === "validating"
          ? "#78b83d"
          : markerState === "active"
            ? "#f5a623"
            : markerState === "inactive" ? "#ef6c65" : "#9aa0ad";
      const tooltip = `${group.label}: ${stateLabel}`;
      const ariaLabel = `${tooltip}; ${stateSummary}; ${count} validator${
        count === 1 ? "" : "s"
      }`;
      let marker: any = markerRegistry.get(key);
      if (!marker) {
        marker = L.circleMarker([group.lat, group.lon], {
          pane: "validatorMarkers",
          interactive: false,
          radius,
          weight: 1,
          color,
          fillColor: color,
          fillOpacity: 0.9,
          opacity: 1,
          className: `validator-marker validator-marker--${markerState}`,
        })
          .bindTooltip(tooltip, { direction: "top", offset: [0, -radius] })
          .bindPopup(popupHtml, {
            closeButton: true,
            maxWidth: 340,
            autoPanPadding: [32, 32],
          });
        marker.__tooltip = tooltip;
        marker.__popupHtml = popupHtml;
        marker
          .on("add", () => {
          const element = marker.getElement();
          if (!element) return;
          element.setAttribute("tabindex", "0");
          element.setAttribute("role", "button");
          element.setAttribute("pointer-events", "none");
          element.addEventListener("keydown", (event: any) => {
            if (event.key !== "Enter" && event.key !== " ") return;
            event.preventDefault();
            openMarkerPopup(key, marker);
          });
        })
        .addTo(markers);
        const hitTarget = L.circleMarker([group.lat, group.lon], {
          pane: "validatorHits",
          radius: 14,
          weight: 1,
          color: "#000",
          fillColor: "#000",
          opacity: 0.001,
          fillOpacity: 0.001,
          className: "validator-marker-hit",
        })
          .addTo(markers);
        marker.__hitTarget = hitTarget;
        hitTarget.getElement()?.setAttribute("pointer-events", "all");
        hitTarget.getElement().style.pointerEvents = "all";
        hitTarget.getElement().parentElement.style.pointerEvents = "auto";
        markerRegistry.set(key, marker);
      } else {
        marker.setLatLng([group.lat, group.lon]);
        marker.setStyle({ radius, color, fillColor: color });
        marker.__hitTarget?.setLatLng([group.lat, group.lon]);
        if (marker.__tooltip !== tooltip) {
          marker.setTooltipContent(tooltip);
          marker.__tooltip = tooltip;
        }
        if (marker.__popupHtml !== popupHtml) {
          marker.setPopupContent(popupHtml);
          marker.__popupHtml = popupHtml;
        }
      }
      const element = marker.getElement();
      if (element) {
        element.setAttribute("tabindex", "0");
        element.setAttribute("role", "button");
        element.setAttribute("pointer-events", "none");
        element.classList.remove(
          "validator-marker--inactive",
          "validator-marker--active",
          "validator-marker--validating",
        );
        element.classList.add("validator-marker", `validator-marker--${markerState}`);
        element.setAttribute("aria-label", ariaLabel);
      }
      let countLabel: any = marker.__countLabel;
      if (count > 1) {
        if (!countLabel) {
          countLabel = L.marker([group.lat, group.lon], {
            interactive: false,
            keyboard: false,
            icon: L.divIcon({
              className: "validator-marker-count",
              html: String(count),
              iconSize: [18, 18],
              iconAnchor: [9, 9],
            }),
          }).addTo(markers);
          marker.__countLabel = countLabel;
        } else {
          countLabel.setLatLng([group.lat, group.lon]);
          const labelElement = countLabel.getElement();
          if (labelElement) labelElement.textContent = String(count);
        }
      } else if (countLabel) {
        markers.removeLayer(countLabel);
        marker.__countLabel = null;
      }
    }
    container.dataset.validatorCount = String(validatorCount);
    container.dataset.markerCount = String(groups.size);
    if (retainedPopupKey && markerRegistry.has(retainedPopupKey)) {
      openMarkerPopup(retainedPopupKey, markerRegistry.get(retainedPopupKey));
    }
  };
  window.addEventListener(
    "pagehide",
    () => {
      document.removeEventListener("keydown", onKeydown, true);
      container.removeEventListener("click", activateNearest, true);
      container.removeEventListener("mousemove", showNearestTooltip, true);
      container.removeEventListener("mouseleave", closeNearestTooltip, true);
      document.body.classList.remove("validator-map-fullscreen-open");
      if (resizeFrame != null) window.cancelAnimationFrame(resizeFrame);
      observer.disconnect();
      map.remove();
    },
    { once: true },
  );
  const landImage = new window.Image();
  landImage.onload = () => {
    const canvas: any = document.createElement("canvas");
    canvas.width = 2000;
    canvas.height = 1000;
    const context = canvas.getContext("2d");
    context.drawImage(landImage, 0, 0, 2000, 1000);
    landMask = context.getImageData(0, 0, 2000, 1000);
    if (latestMapNodes === observedNodes) update(observedNodes);
  };
  // Same-origin static asset – reading its alpha channel does not introduce a
  // map provider or a runtime network dependency.
  landImage.src = "world-map.svg";
  update(observedNodes);
  fitWorld();
  return { update };
}
initValidatorMap()
  .then((controller) => {
    validatorMapController = controller;
    validatorMapController?.update(observedNodes);
  })
  .catch(() => {
    $("validator-map").textContent = "Validator map is unavailable";
  });
async function refresh(): Promise<void> {
  let healthy = 0;
  let best = 0;
  let referenceKnown = false;
  let referenceHeight = 0;
  refreshTelegramConsumer();
  refreshGpuInventory().catch(() => {});
  refreshSoftwareInventory().catch(() => {});
  try {
    best = await reconcileParticipants();
  } catch {}
  try {
    if (!chainRpcOrigin) throw new Error("chain RPC origin is missing");
    const reference = await json(`${chainRpcOrigin}/chain-rpc/status`);
    referenceHeight = Number(reference.result.sync_info.latest_block_height);
    if (Number.isFinite(referenceHeight) && referenceHeight > 0) {
      best = Math.max(best, referenceHeight);
      referenceKnown = true;
    }
  } catch {}
  await Promise.all(
    observedNodes
      .filter((n) => n.mode !== "skip")
      .map(async (n) => {
        const card = cards.get(nodeKey(n));
        if (!card) return;
        if (!n.statusBase) {
          n.endpointState = "unknown";
          n.endpointDiagnostic = "Check endpoint";
          n.isOnline = false;
          n.serverStatus = "endpoint unknown";
          set(card, "height", best ? best.toLocaleString() : "–");
          set(card, "peers", "–");
          renderHostState(card, n);
          updateSoftware(cardSoftwareInventory, n, card);
          return;
        }
        const statusBase = n.statusBase;
        try {
          const [s, net] = await Promise.all([
            json(`${statusBase}/chain-rpc/status`),
            json(`${statusBase}/chain-rpc/net_info`),
          ]);
          n.endpointState = "reachable";
          n.endpointDiagnostic = "";
          const h = Number(s.result.sync_info.latest_block_height);
          const peers = Number(net.result.n_peers);
          n.catchingUp = Boolean(s.result.sync_info.catching_up);
          n.blocksBehind = referenceKnown
            ? Math.abs(referenceHeight - h)
            : undefined;
          const blockTime = Date.parse(
            String(s.result.sync_info.latest_block_time || ""),
          );
          n.blockAgeSeconds = Number.isFinite(blockTime)
            ? Math.max(0, (Date.now() - blockTime) / 1000)
            : undefined;
          n.progressing =
            n.blockAgeSeconds !== undefined && n.blockAgeSeconds <= 90;
          n.referenceKnown = referenceKnown;
          n.referenceAgrees =
            referenceKnown &&
            n.blocksBehind !== undefined &&
            n.blocksBehind <= 5;
          best = Math.max(best, h);
          const validatorEffective = renderHostState(card, n);
          n.isOnline =
            validatorEffective &&
            hostState.classify({
              endpointState: n.endpointState,
              catchingUp: n.catchingUp,
              blocksBehind: n.blocksBehind,
              blockAgeSeconds: n.blockAgeSeconds,
              progressing: n.progressing,
              referenceKnown: n.referenceKnown,
              referenceAgrees: n.referenceAgrees,
            }).syncLabel === "Synced";
          n.serverStatus = "endpoint reachable";
          set(card, "height", h.toLocaleString());
          set(card, "peers", peers);
          if (validatorEffective) healthy++;
          updateSoftware(cardSoftwareInventory, n, card);
        } catch (e) {
          n.endpointState = "unavailable";
          n.endpointDiagnostic = hostState.endpointDiagnostic(e);
          n.isOnline = false;
          n.serverStatus = "endpoint unavailable";
          set(card, "height", "–");
          set(card, "peers", "–");
          renderHostState(card, n);
          updateSoftware(cardSoftwareInventory, n, card);
        }
      }),
  );
  validatorMapController?.update(observedNodes);
  $("best-height").textContent = best ? best.toLocaleString() : "–";
  setUtcTime("updated", new Date(), "Updated");
  try {
    if (!chainRpcOrigin) throw new Error("chain RPC origin is missing");
    const v = await json(
      `${chainRpcOrigin}/chain-rpc/validators?per_page=100`,
    );
    const vals = v.result.validators || [];
    const powers = vals.map((x) => BigInt(x.voting_power));
    const total = powers.reduce((a, b) => a + b, 0n);
    const max = powers.reduce((a, b) => (a > b ? a : b), 0n);
    const share = total ? Number((max * 10000n) / total) / 100 : 0;
    const unsafe = total > 0n && max * 3n >= total;
    $("power-share").textContent = `${share.toFixed(2)}%`;
    $("power-share").style.color = unsafe ? "var(--bad)" : "var(--ok)";
  } catch {
    $("power-share").textContent = "–";
  }
  let gatewayState: any = null;
  let gatewayProbe: any = null;
  try {
    [gatewayState, gatewayProbe] = await Promise.all([
      json("/status/gateway/v1/status"),
      json("/status/gateway-health"),
    ]);
  } catch {}
  try {
    if (!gatewayStatus.classify(gatewayState, healthy, gatewayProbe).available)
      throw new Error("gateway unavailable");
    const runtime = gatewayState.escrow_id
      ? gatewayState
      : (gatewayState.devshards || []).find(
          (item) =>
            item.active && item.phase === "active" && !item.requests_blocked,
        );
    if (!runtime?.id && !runtime?.escrow_id)
      throw new Error("no active unblocked escrow");
    const escrowId = runtime.id || runtime.escrow_id;
    $("gateway-access").hidden = false;
    $("gateway-detail").textContent =
      `Escrow #${escrowId} is ACTIVE – authenticated chain-accounted inference is accepting requests`;
  } catch (error) {
    $("gateway-access").hidden = true;
  }
  try {
    const availability = gatewayStatus.classify(
      gatewayState,
      healthy,
      gatewayProbe,
    );
    if (!availability.available) throw new Error(availability.message);
    const metricText = await text("/status/gateway/metrics");
    const metricValue = (name: string): number =>
      [
        ...metricText.matchAll(
          new RegExp(`^${name}(?:\\{[^}]*\\})?\\s+([0-9.e+-]+)$`, "gm"),
        ),
      ].reduce((total, match) => total + Number(match[1]), 0);
    const inflight = metricValue("devshard_gateway_inflight_requests");
    const tokens = metricValue("devshard_gateway_inflight_input_tokens");
    const accepted = metricValue("devshard_gateway_requests_total");
    const rejected = metricValue("devshard_gateway_limit_rejections_total");
    const capacity = metricValue("devshard_gateway_capacity_scale");
    const values = [
      String(inflight),
      tokens.toLocaleString(),
      accepted.toLocaleString(),
      rejected.toLocaleString(),
      `${Math.round(capacity * 100)}%`,
    ];
    [...$("quality-metrics").children].forEach(
      (card, index) =>
        (card.querySelector("strong").textContent = values[index]),
    );
    $("quality-active").textContent = inflight;
    $("quality-accepted").textContent = accepted;
    $("quality-rejected").textContent = rejected;
    const health = $("quality-health");
    const state = inflight > 0 ? "active" : "idle";
    health.dataset.state = state;
    $("quality-health-state").textContent =
      inflight > 0
        ? "READY – verified inference; processing requests"
        : "READY – verified inference; no requests in flight";
    $("quality-recovery").hidden = true;
    setUtcTime("quality-updated", new Date(), "Updated");
  } catch (error) {
    const availability = gatewayStatus.classify(
      gatewayState,
      healthy,
      gatewayProbe,
    );
    const recovery = $("quality-recovery");
    $("quality-health-state").textContent = availability.state;
    $("quality-health").dataset.state =
      availability.state === "PENDING" || availability.state === "RECOVERING"
        ? "degraded"
        : "down";
    setRecoveryMessage(recovery, availability);
    recovery.hidden = false;
    if (gatewayProbe?.checked_at)
      setUtcTime(
        "quality-updated",
        new Date(gatewayProbe.checked_at),
        "Checked",
      );
    else
      $("quality-updated").textContent =
        "Gateway health has not been checked yet";
  }
}
refresh();
setInterval(refresh, 15000);
