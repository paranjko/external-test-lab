// @flow strict

type GeoLocation = {
  latitude: number,
  longitude: number,
  city: string,
  country: string,
  isp: string,
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

type ValidatorMapNavigation = {
  fit: () => void,
  remove: () => void,
};

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

type GpuInventory = Map<string, Array<string>>;
type SoftwareInventory = Map<string, Array<any>>;
type SoftwareVersionsApi = {
  normalizeMlNodeVersion: (chain: string, reported: string) => string,
};

declare var GDC_SOFTWARE_VERSIONS: SoftwareVersionsApi;

type Validator = {
  ownerAddress: string,
  ip: string,
  licenseCount: number,
  online: boolean,
  geo: {
    lat: number,
    lon: number,
    city: string,
    country: string,
    isp: string,
  },
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
declare class ResizeObserver {
  constructor(callback: () => void): void;
  observe(element: HTMLElement): void;
  disconnect(): void;
}
declare class URL {
  constructor(url: string): void;
  hostname: string;
}

const cfg: SiteConfig = (window: any).GDC_CONFIG;
const gatewayStatus: GatewayStateApi = (window: any).GDC_GATEWAY_STATE;
const hostState: HostStateApi = (window: any).GDC_HOST_STATE;
const $ = (id: string): any => document.getElementById(id);
const chainRpcHost =
  cfg.chainRpcHost ||
  cfg.nodes.find((node) => node.name === cfg.gatewayNode)?.publicHost ||
  cfg.nodes[0]?.publicHost;
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
      link.title = "The Telegram client is available; inference is temporarily unavailable.";
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
  const connection = node.gpuHost && node.gpuHost !== node.name ? "net" : "local";
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
      set(card, "gpu", `${configuredProfile} – ${connection} (inventory unavailable)`);
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
    const component = raw === "inference-chain" || raw === "node"
      ? "chain"
      : raw === "decentralized-api" || raw === "api"
        ? "DAPI"
        : raw === "mlnode"
          ? "MLNode"
          : "";
    if (!component || !metric.version) continue;
    const existing = components.get(component);
    if (!existing || metric.source === "runtime") components.set(component, metric);
  }
  const formatted: Array<string> = [];
  const chainVersion = String(components.get("chain")?.version || "unknown");
  for (const component of ["chain", "DAPI", "MLNode"]) {
    const metric = components.get(component);
    if (!metric) continue;
    const version = component === "MLNode"
      ? GDC_SOFTWARE_VERSIONS.normalizeMlNodeVersion(chainVersion, String(metric.version))
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
    const instanceHost = String(sample?.metric?.instance || "").replace(/:\\d+$/, "");
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
  return String(value).replace(
    /[&<>'"]/g,
    (char) => entities[char],
  );
}
function renderHostState(card: HTMLElement, node: SiteNode): boolean {
  const display = hostState.classify({
    participantKnown: node.participantKnown,
    participantStatus: node.participantState || node.participantStatus,
    validatorKnown: node.validatorKnown,
    votingPower: node.votingPower,
    endpointState: node.endpointState,
    endpointDiagnostic: node.endpointDiagnostic,
    catchingUp: node.catchingUp,
    blocksBehind: node.blocksBehind,
    blockAgeSeconds: node.blockAgeSeconds,
    progressing: node.progressing,
    referenceKnown: node.referenceKnown,
    referenceAgrees: node.referenceAgrees,
  });
  set(card, "status", display.primaryLabel);
  card.querySelector('[data-k="status"]').className = display.primaryClass;
  set(card, "vp", display.votingPower);
  set(card, "sync", display.syncLabel);
  set(card, "endpoint", display.endpointLabel);
  return display.validatorEffective;
}

const participantDiscovery: Map<string, Promise<ParticipantDiscovery>> =
  new Map();

async function discoverParticipant(host: string): Promise<ParticipantDiscovery> {
  if (!host) return {};
  const cached = participantDiscovery.get(host);
  if (cached) return cached;
  const discovery: Promise<ParticipantDiscovery> = (async () => {
    const statusBase = `https://${host}`;
    const dns = await json(
      `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(host)}&type=A`,
      { headers: { accept: "application/dns-json" } },
    );
    const ip =
      (dns.Answer || [])
        .map((answer) => String(answer.data || ""))
        .find((value) => /^(?:\d{1,3}\.){3}\d{1,3}$/.test(value)) || "";
    if (!ip) return { statusBase, ip: "", geo: null };
    const location = await json(`https://ipwho.is/${encodeURIComponent(ip)}`);
    const latitude = Number(location.latitude);
    const longitude = Number(location.longitude);
    const geo =
      location.success === true &&
      Number.isFinite(latitude) &&
      Number.isFinite(longitude)
        ? {
            latitude,
            longitude,
            city: location.city || "Unknown",
            country: location.country || "Unknown",
            isp: location.connection?.isp || "unknown",
          }
        : null;
    return { statusBase, ip, geo };
  })();
  participantDiscovery.set(host, discovery);
  try {
    return await discovery;
  } catch {
    participantDiscovery.delete(host);
    return { statusBase: `https://${host}`, ip: "", geo: null };
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
  const catalog = (cfg.nodeCatalog || cfg.nodes).find(
    (node) => node.address === participant.address || node.publicHost === host,
  );
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
  if (!chainRpcHost) throw new Error("chain RPC host is missing");
  const [participantResult, validatorResult] = await Promise.allSettled([
    json("/status/participants"),
    json(`https://${chainRpcHost}/chain-rpc/validators?per_page=100`),
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
  const next = (await Promise.all(
    participants.map((participant) =>
      participantNode(participant, validators, validatorKnown),
    ),
  )).sort(
    (left, right) => left.name.localeCompare(right.name),
  );
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

const VALIDATOR_BOUNDS = [
  [-58, -175],
  [84, 175],
];
const WEB_MERCATOR_BOUNDS = [
  [-85.05112878, -180],
  [85.05112878, 180],
];
const WHEEL_ZOOM_STEP = 0.3;
const WHEEL_ZOOM_SETTLE_MS = 80;

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

function wheelPixels(event: any): number {
  if (event.deltaMode === 1) return event.deltaY * 20;
  if (event.deltaMode === 2) return event.deltaY * 60;
  return event.deltaY;
}

function installSmoothWheelZoom(
  map: any,
  container: HTMLElement,
  prepareBounds: (number) => void,
): () => void {
  // Leaflet batches small wheel deltas before animating them. On a trackpad
  // that feels like a pause followed by a jump, so update once per paint.
  let animationFrame: ?number;
  let settleTimer: ?number;
  let zooming = false;
  let pendingZoomDelta = 0;
  let pointer = null;

  const finishZoom = (): void => {
    settleTimer = null;
    if (!zooming) return;
    zooming = false;
    map._moveEnd(true);
  };

  const centerZoomOnPointer = (
    zoomPointer: any,
    nextZoom: number,
    currentZoom: number,
  ): any => {
    const viewCenter = map.getSize().divideBy(2);
    const scale = map.getZoomScale(nextZoom, currentZoom);
    const offset = zoomPointer
      .subtract(viewCenter)
      .multiplyBy(1 - 1 / scale);
    return map._limitCenter(
      map.containerPointToLatLng(viewCenter.add(offset)),
      nextZoom,
      map.options.maxBounds,
    );
  };

  const renderZoom = (): void => {
    animationFrame = null;
    const currentZoom = map.getZoom();
    const nextZoom = clamp(
      currentZoom +
        clamp(pendingZoomDelta, -WHEEL_ZOOM_STEP, WHEEL_ZOOM_STEP),
      map.getMinZoom(),
      map.getMaxZoom(),
    );
    pendingZoomDelta = 0;
    const zoomPointer = pointer;
    if (!zoomPointer || Math.abs(nextZoom - currentZoom) < 0.001) return;

    prepareBounds(nextZoom);
    if (!zooming) {
      zooming = true;
      map._moveStart(true, false);
    }
    // This is the same live transform path Leaflet uses for touch pinch. It
    // keeps loaded tiles visible instead of rebuilding them for every delta.
    map._move(centerZoomOnPointer(zoomPointer, nextZoom, currentZoom), nextZoom, {
      pinch: true,
      round: false,
    });
    if (settleTimer != null) window.clearTimeout(settleTimer);
    settleTimer = window.setTimeout(finishZoom, WHEEL_ZOOM_SETTLE_MS);
  };

  const onWheel = (event: any): void => {
    if (!event.ctrlKey && event.deltaY === 0) return;
    event.preventDefault();
    event.stopPropagation();
    const sensitivity = event.ctrlKey ? 60 : 120;
    pendingZoomDelta += clamp(
      -wheelPixels(event) / sensitivity,
      -WHEEL_ZOOM_STEP,
      WHEEL_ZOOM_STEP,
    );
    pointer = map.mouseEventToContainerPoint(event);
    if (animationFrame == null)
      animationFrame = window.requestAnimationFrame(renderZoom);
  };

  container.addEventListener("wheel", onWheel, { passive: false });
  return () => {
    container.removeEventListener("wheel", onWheel);
    if (animationFrame != null) window.cancelAnimationFrame(animationFrame);
    if (settleTimer != null) window.clearTimeout(settleTimer);
  };
}

function installValidatorMapNavigation(
  map: any,
  tiles: any,
  container: HTMLElement,
): ValidatorMapNavigation {
  let useWorldBounds = false;

  const recordZoom = (): void => {
    container.dataset.zoom = String(map.getZoom());
  };

  const prepareBounds = (
    zoom: number = map.getZoom(),
    allowTighterBounds: boolean = true,
  ): void => {
    const north = map.project(VALIDATOR_BOUNDS[1], zoom).y;
    const south = map.project(VALIDATOR_BOUNDS[0], zoom).y;
    const validatorBoundsFit = south - north >= map.getSize().y - 1;
    const nextUseWorldBounds = !validatorBoundsFit;

    // Keep the wider bounds until an active gesture ends. Tightening them in
    // the middle of a zoom makes Leaflet jump back toward the validator area.
    if (!nextUseWorldBounds && useWorldBounds && !allowTighterBounds) return;
    if (nextUseWorldBounds === useWorldBounds) return;
    useWorldBounds = nextUseWorldBounds;
    map.setMaxBounds(useWorldBounds ? WEB_MERCATOR_BOUNDS : VALIDATOR_BOUNDS);
  };

  const onZoom = (): void => {
    prepareBounds(map.getZoom(), false);
    // Leaflet waits until touchend to update tiles during a native pinch.
    // Updating the active level here keeps the viewport covered mid-gesture.
    tiles._update();
    recordZoom();
  };

  const onZoomEnd = (): void => {
    tiles._noPrune = false;
    tiles._pruneTiles();
    prepareBounds();
    map.panInsideBounds(
      useWorldBounds ? WEB_MERCATOR_BOUNDS : VALIDATOR_BOUNDS,
      { animate: false },
    );
    map.invalidateSize({ animate: false, pan: false });
    recordZoom();
  };

  const fit = (): void => {
    map.invalidateSize({ animate: false, pan: false });
    const minimumWorldZoom = Math.max(
      1,
      Math.ceil(Math.log2(map.getSize().y / 256)),
    );
    map.setMinZoom(minimumWorldZoom);
    map.fitBounds(VALIDATOR_BOUNDS, { animate: false });
    prepareBounds();
    if (useWorldBounds) {
      map.setView([0, 0], map.getZoom(), { animate: false });
    } else {
      map.panInsideBounds(VALIDATOR_BOUNDS, { animate: false });
    }
    recordZoom();
  };

  const removeWheelZoom = installSmoothWheelZoom(map, container, (zoom) =>
    prepareBounds(zoom, false),
  );
  map.on("zoom", onZoom);
  map.on("zoomend", onZoomEnd);

  return {
    fit,
    remove: () => {
      removeWheelZoom();
      map.off("zoom", onZoom);
      map.off("zoomend", onZoomEnd);
    },
  };
}

async function initValidatorMap(): Promise<?ValidatorMapController> {
  if (typeof window === "undefined") return;
  const container = $("validator-map");
  const shell = $("validator-map-shell");
  const button = $("validator-map-fullscreen");
  if (!container || !shell || !button) return;
  const module = await import(
    // Flow cannot resolve an HTTP module specifier, but the browser can.
    // $FlowFixMe[cannot-resolve-module]
    "https://unpkg.com/leaflet@1.9.4/dist/leaflet-src.esm.js"
  );
  const L = module.default ?? module;
  const darkTiles =
    "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png";
  const lightTiles =
    "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png";
  const isLight = () =>
    getComputedStyle(document.documentElement).colorScheme.includes("light");
  const map = L.map(container, {
    center: [20, 0],
    zoom: 2,
    minZoom: 1,
    maxZoom: 10,
    zoomSnap: 0.05,
    scrollWheelZoom: false,
    maxBounds: VALIDATOR_BOUNDS,
    maxBoundsViscosity: 1,
    worldCopyJump: true,
    zoomControl: true,
    attributionControl: false,
    bounceAtZoomLimits: false,
  });
  const tiles = L.tileLayer(isLight() ? lightTiles : darkTiles, {
    subdomains: "abcd",
    maxZoom: 20,
    updateInterval: 40,
  }).addTo(map);
  const markers = L.layerGroup().addTo(map);
  const okColor = getComputedStyle(document.documentElement)
    .getPropertyValue("--lime")
    .trim();
  const badColor = getComputedStyle(document.documentElement)
    .getPropertyValue("--red")
    .trim();
  const primary = getComputedStyle(document.documentElement)
    .getPropertyValue("--primary-color")
    .trim();
  const update = (nodes: Array<SiteNode>): void => {
    markers.clearLayers();
    const groups: Map<string, Array<Validator>> = new Map();
    let validatorCount = 0;
    for (const node of nodes) {
      const geo = node.geo;
      const lat = Number(geo?.latitude);
      const lon = Number(geo?.longitude);
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
      if (!geo) continue;
      const validator = {
        ownerAddress: node.address || "",
        ip: node.ip || "",
        licenseCount: 0,
        online: node.isOnline === true,
        geo: {
          lat,
          lon,
          city: geo.city || "Unknown",
          country: geo.country || "Unknown",
          isp: geo.isp || "unknown",
        },
      };
      const key = `${lat.toFixed(1)},${lon.toFixed(1)}`;
      if (!groups.has(key)) groups.set(key, []);
      const group = groups.get(key);
      if (group) group.push(validator);
      validatorCount += 1;
    }
    for (const validators of groups.values()) {
      const first = validators[0];
      const count = validators.length;
      const radius = Math.min(5 + Math.sqrt(count) * 3, 18) / 4;
      const onlineCount = validators.filter((validator) => validator.online).length;
      const allOnline = onlineCount === count && count > 0;
      const onlineColor = allOnline
        ? okColor || primary
        : badColor || primary;
      const popupStatusClass = allOnline ? "ok" : "bad";
      const popupStatus =
        onlineCount === 0
          ? "not online"
          : onlineCount === count
            ? "online"
            : `${onlineCount}/${count} online`;
      const rows = validators
        .map(
          (v) =>
            `<li><span>${escapeHtml(v.ip || "IP unavailable")}</span><span>${escapeHtml(v.ownerAddress.slice(0, 10))}</span><span>${escapeHtml(v.licenseCount)}</span></li>`,
        )
        .join("");
      const popup = `<section class="validator-popup"><strong>${escapeHtml(first.geo.city)}, ${escapeHtml(first.geo.country)}</strong><p class="status ${popupStatusClass}">${escapeHtml(
        popupStatus,
      )}</p><p>${count} validator${count === 1 ? "" : "s"} at this location</p><ul>${rows}</ul></section>`;
      L.circleMarker([first.geo.lat, first.geo.lon], {
        radius,
        color: onlineColor,
        weight: 1,
        opacity: 0.95,
        fillColor: onlineColor,
        fillOpacity: 0.7,
        className: `validator-marker validator-marker--${allOnline ? "online" : "offline"}`,
      })
        .addTo(markers)
        .bindPopup(popup, { closeButton: true, maxWidth: 340 });
    }
    container.dataset.validatorCount = String(validatorCount);
    container.dataset.markerCount = String(groups.size);
  };
  const navigation = installValidatorMapNavigation(map, tiles, container);
  const observer = new ResizeObserver(navigation.fit);
  observer.observe(container);
  const setFullscreen = (open: boolean): void => {
    shell.classList.toggle("is-fullscreen", open);
    button.setAttribute("aria-pressed", String(open));
    button.textContent = open ? "Close" : "Fullscreen";
    navigation.fit();
    setTimeout(navigation.fit, 240);
  };
  button.addEventListener("click", () =>
    setFullscreen(!shell.classList.contains("is-fullscreen")),
  );
  const onKeydown = (event: KeyboardEvent): void => {
    if (event.key === "Escape" && shell.classList.contains("is-fullscreen"))
      setFullscreen(false);
  };
  document.addEventListener("keydown", onKeydown);
  const theme = window.matchMedia("(prefers-color-scheme: light)");
  const onTheme = (): void => tiles.setUrl(isLight() ? lightTiles : darkTiles);
  theme.addEventListener("change", onTheme);
  window.addEventListener(
    "pagehide",
    () => {
      observer.disconnect();
      theme.removeEventListener("change", onTheme);
      document.removeEventListener("keydown", onKeydown);
      navigation.remove();
      map.remove();
    },
    { once: true },
  );
  update(observedNodes);
  navigation.fit();
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
    if (!chainRpcHost) throw new Error("chain RPC host is missing");
    const reference = await json(`https://${chainRpcHost}/chain-rpc/status`);
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
          n.blocksBehind = referenceKnown ? Math.abs(referenceHeight - h) : undefined;
          const blockTime = Date.parse(String(s.result.sync_info.latest_block_time || ""));
          n.blockAgeSeconds = Number.isFinite(blockTime)
            ? Math.max(0, (Date.now() - blockTime) / 1000)
            : undefined;
          n.progressing = n.blockAgeSeconds !== undefined && n.blockAgeSeconds <= 90;
          n.referenceKnown = referenceKnown;
          n.referenceAgrees = referenceKnown && n.blocksBehind !== undefined && n.blocksBehind <= 5;
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
  validatorMapController?.update(
    observedNodes,
  );
  $("best-height").textContent = best ? best.toLocaleString() : "–";
  setUtcTime("updated", new Date(), "Updated");
  try {
    if (!chainRpcHost) throw new Error("chain RPC host is missing");
    const v = await json(
      `https://${chainRpcHost}/chain-rpc/validators?per_page=100`,
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
