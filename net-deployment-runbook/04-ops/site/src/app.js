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
  statusAlias?: string,
  address?: string,
  publicHost?: string,
  dapiUrl?: string,
  rpcIdentityVerified?: boolean,
  statusBase?: string,
  validatorRpcBase?: string,
  ip?: string,
  geo?: ?GeoLocation,
  mode?: string,
  reason?: string,
  participantStatus?: string,
  participantState?: string,
  participantKnown?: boolean,
  validatorKnown?: boolean,
  observationComplete?: boolean,
  networkObserved?: boolean,
  networkActive?: boolean,
  votingPower?: string,
  validatorAddress?: string,
  rpcHeight?: number,
  rpcChainId?: string,
  rpcBlockTimeMs?: number,
  rpcObservedAt?: number,
  chainDiagnostic?: string,
  endpointState?: string,
  endpointDiagnostic?: string,
  peerCount?: ?number,
  peerState?: string,
  catchingUp?: boolean,
  blocksBehind?: number,
  blockAgeSeconds?: number,
  progressing?: ?boolean,
  referenceKnown?: boolean,
  referenceAgrees?: boolean,
  isOnline?: boolean,
  serverStatus?: string,
  softwareVersions?: ?any,
  observedSoftwareVersions?: ?any,
  observedModelRegistry?: ?any,
  observedInferenceVersion?: string,
  inferenceObservationRejected?: boolean,
  devShardHealth?: ?any,
  gpuHost?: ?string,
  participantAddress?: ?string,
  activity?: any,
  bootstrapRpc?: string,
  bootstrapNodeId?: string,
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
  statusBase?: string,
  bootstrapOrigin?: string,
  publicBootstrap?: boolean,
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
    admission?: any,
  ) => GatewayAvailability,
};

type HostStateApi = {
  isActiveParticipant: (status: mixed) => boolean,
  classify: (state: any) => {
    state: "validating" | "active" | "degraded" | "inactive" | "unknown",
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
  update: (nodes: Array<SiteNode>, validatorSet?: any) => void,
};

type MarkerState = "waiting" | "unavailable" | "active" | "validating";

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

type GpuRecord = {
  name: string,
  memoryBytes: ?number,
  memoryLabel?: string,
};
type GpuInventory = Map<string, Array<GpuRecord>>;
type SoftwareInventory = Map<string, Array<any>>;
type HardwareNode = {
  local_id?: string,
  version?: string,
  host?: string,
  port?: string,
  hardware?: Array<{ type?: string, count?: number }>,
};
type HardwareInventoryEntry = {
  state: "observed" | "unavailable",
  nodes: Array<HardwareNode>,
};
type HardwareInventory = Map<string, HardwareInventoryEntry>;
type DevShardHealth = {
  state: "checking" | "observed" | "not_exposed" | "unavailable",
  runtimes: Array<any>,
};
type DevShardVersion = {
  name: string,
  sha256: string,
};
type SoftwareVersionsApi = {
  displayVersion: (reported: string) => string,
  normalizeMlNodeVersion: (chain: string, reported: string) => string,
  formatMlNodes: (chain: string, mlnodes: Array<{ version?: string, node_id?: string, host?: string, port?: string }>) => string,
  describeMlNodes: (
    chain: string,
    mlnodes: Array<{ version?: string, node_id?: string, host?: string, port?: string }>,
  ) => Array<string>,
  selectLatestInventory: (samples: Array<any>, nowSeconds?: number, maxAgeSeconds?: number) => Map<string, any>,
  freshInventoryVersion: (reported: string, samples: Array<any>, component: string) => string,
  freshPayloadVersion: (state: any, component: string) => string,
  freshNetworkInferenceVersion: (inferenced: any, chainRpc: any, nodeId: string, chainId: string) => string,
  selectMlNodes: (versions: any, hardware: any) => {observed: boolean, source: string, nodes: Array<{version?: string, node_id?: string, host?: string, port?: string}>},
  emptyMlNodeLabel: (observation: {observed: boolean, source: string, nodes: Array<{version?: string, node_id?: string, host?: string, port?: string}>}) => string,
  selectDevShardIdentity: (samples: Array<any>, host: string, timestamp: number) => Map<string, any>,
};

declare var GDC_SOFTWARE_VERSIONS: SoftwareVersionsApi;
declare var GDC_NETWORK_OBSERVATION: {
  nodeState: (observation: any) => ?any,
  observeRpc: (base: string, nodeId: ?string, getJson: (url: string) => Promise<any>) => Promise<any>,
  peerCount: (observation: any) => string,
  loadCurrentValidatorSet: (reference: any, expectedChainId: string, getJson: (url: string) => Promise<any>) => Promise<any>,
  loadParticipants: (apiOrigin: string, reference: any, expectedChainId: string, getJson: (url: string) => Promise<any>) => Promise<Array<any>>,
  verifyChainApiReference: (apiOrigin: string, reference: any, expectedChainId: string, getJson: (url: string) => Promise<any>) => Promise<number>,
  participantAddressForNode: (participants: Array<any>, node: any) => ?string,
  currentVotingPower: (nodeAddress: any, validatorSet: any) => ?string,
  applyCurrentVotingPower: (node: any, validatorSet: any) => ?string,
  validatorSet: (response: any, referenceHeight: number, expectedChainId: string, observedChainId: string) => any,
  referenceProgressed: (previous: any, height: number, chainId: string, nowMs: number, maxAgeMs?: number) => boolean,
  selectProgressingReference: (samples: Array<any>, previousByNode: Map<string, any>, expectedChainId: string, nowMs: number) => ?any,
  selectFreshReference: (samples: Array<any>, expectedChainId: string, nowMs: number) => ?any,
  effectiveValidatorCount: (states: Array<any>) => number,
  loadActivity: (base: string, getJson: (url: string) => Promise<any>) => Promise<any>,
  activityState: (evidence: any, participant: ?string, nowMs?: number) => any,
  inferenceState: (health: any) => any,
};
declare var L: any;
declare var WebSocket: any;

type Validator = {
  name: string,
  ownerAddress: string,
  ip: string,
  licenseCount: number,
  online: boolean,
  markerState: MarkerState,
  stateReason: string,
  currentValidator: ?boolean,
  gpuCount: number,
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

type MarkerStateCounts = {
  validating: number,
  active: number,
  waiting: number,
  unavailable: number,
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
  protocol: string;
  hostname: string;
  username: string;
  password: string;
  origin: string;
}

const cfg: SiteConfig = (window: any).GDC_CONFIG;
const siteBuild: any = (window: any).GDC_SITE_BUILD || {};
const gatewayStatus: GatewayStateApi = (window: any).GDC_GATEWAY_STATE;
const hostState: HostStateApi = (window: any).GDC_HOST_STATE;
const $ = (id: string): any => document.getElementById(id);

function renderModelList(models: Array<string>, title: string = "", emptyLabel: string = "Not reported"): void {
  const target = $("model-id");
  target.replaceChildren();
  for (const model of models.length ? models : [emptyLabel]) {
    const item = document.createElement("li");
    item.textContent = model;
    target.append(item);
  }
  target.title = title;
}
const previewMatch = String((window: any).location?.pathname || "").match(
  /^\/preview\/([1-9][0-9]*)(?:\/|$)/,
);
const previewHostMatch =
  String((window: any).location?.hostname || "").toLowerCase() ===
  "preview.gonka-dev.net"
    ? String((window: any).location?.pathname || "").match(
        /^\/([1-9][0-9]*)(?:\/|$)/,
      )
    : null;
const previewNumber = previewMatch?.[1] || previewHostMatch?.[1] || "";
const previewPrefix = previewMatch ? `/preview/${previewMatch[1]}` : "";
let statusBase = "";
let chainRpcCatalog: Array<SiteNode> = [];
let chainRpcHost = "";
let chainRpcNodeMatches: Array<SiteNode> = [];
let chainRpcNode = "";
let chainRpcOrigin = "";
let chainApiOrigin = "";

function configureNetwork(): void {
  statusBase = String(
    previewPrefix ? `${previewPrefix}/status` : cfg.statusBase || "/status",
  ).replace(/\/$/, "");
  chainRpcCatalog = cfg.publicBootstrap === true ? [] : cfg.nodeCatalog || cfg.nodes || [];
  chainRpcHost =
    cfg.chainRpcHost ||
    chainRpcCatalog.find((node) => node.name === cfg.gatewayNode)?.publicHost ||
    chainRpcCatalog[0]?.publicHost || "";
  chainRpcNodeMatches = chainRpcCatalog.filter(
    (node) => node.publicHost === chainRpcHost,
  );
  chainRpcNode = chainRpcNodeMatches.length === 1
    ? String(chainRpcNodeMatches[0].statusAlias || chainRpcNodeMatches[0].name)
    : "";
  chainRpcOrigin = cfg.publicBootstrap === true ? "" :
    previewPrefix && chainRpcNode
      ? `${statusBase}/${chainRpcNode}`
      : cfg.chainRpcOrigin || (chainRpcHost ? `https://${chainRpcHost}` : "");
  // A preview must use its selected status proxy for both RPC and chain API
  // reads. Direct Host chain API requests are cross-origin and therefore can
  // leave validator membership and MLNode inventory unavailable in browsers.
  chainApiOrigin = cfg.publicBootstrap === true ? "" : chainRpcOrigin;
  $("chain-id").textContent = cfg.chainId;
  renderModelList([], "Waiting for effective network model assignments");
  $("model-label").textContent = "Allocated models";
  $("grafana-network").href = cfg.grafanaNetwork || cfg.grafana || "#";
  $("grafana-inference").href = cfg.grafanaInference || "#";
  const source = $("network-source");
  if (source) source.textContent = "LIVE NETWORK";
  const networkHeading = document.querySelector("#network .section-title h2");
  if (networkHeading) networkHeading.textContent = "Participant status";
}

function renderNetworkObservationStatus(status: "pending" | "unavailable" | "invalid"): void {
  const source = $("network-source");
  const updated = $("updated");
  if (status === "pending") {
    if (source) source.textContent = "NETWORK OBSERVATION PENDING";
    updated.removeAttribute("datetime");
    updated.textContent = "Waiting for a fresh network observation";
  } else if (status === "invalid") {
    if (source) source.textContent = "NETWORK OBSERVATION INVALID";
    updated.removeAttribute("datetime");
    updated.textContent = "Network observer returned an invalid snapshot";
  } else {
    if (source) source.textContent = "NETWORK OBSERVATION UNAVAILABLE";
    updated.removeAttribute("datetime");
    updated.textContent = "Network observer unavailable";
  }
}

const statusUrl = (path: string): string => {
  const url = `${statusBase}${path}`;
  return cfg.publicBootstrap === true && path === "/network"
    ? `${url}?chainId=${encodeURIComponent(cfg.chainId)}`
    : url;
};

let telegramStatusFetch = 0;
let telegramProjection: any = null;
let telegramProjectionRevision = -1;
function renderTelegramProjection(): void {
  const link = $("contact");
  const projection = telegramProjection;
  const timestamp = Date.now() / 1000;
  const fresh = (input: any, maxAge: number = 30): boolean =>
    typeof input?.observed_at === "number" &&
    typeof input?.expires_at === "number" &&
    Number.isFinite(input.observed_at) && input.expires_at === input.observed_at + maxAge &&
    input.observed_at <= timestamp && timestamp <= input.expires_at;
  let combined = String(projection?.combined_state || "UNVERIFIED");
  const backends = Array.isArray(projection?.backends) ? projection.backends : [];
  const eligible = backends.filter((item) => item.state === "ELIGIBLE" && fresh(item));
  if (combined === "LIVE" && (
    projection?.model !== cfg.model || !eligible.length ||
    projection?.bot?.state !== "OK" || !fresh(projection?.bot) ||
    projection?.delivery?.state !== "RECENT" || !fresh(projection?.delivery, 120)
  )) combined = "UNVERIFIED";
  if (combined === "BOT_FAILED" && !(
    (projection?.bot?.state === "FAILED" && fresh(projection?.bot)) ||
    (projection?.delivery?.state === "DELIVERY_FAILED" && fresh(projection?.delivery, 120))
  )) combined = "UNVERIFIED";
  if (combined === "UNAVAILABLE" && !backends.every((item) => fresh(item) && item.state === "UNAVAILABLE"))
    combined = "UNVERIFIED";
  link.textContent = `Telegram: ${combined} ↗`;
  link.dataset.state = combined;
  link.title = projection
    ? `${cfg.model}; gateway ${projection.gateway_state}; bot ${projection.bot.state}; delivery ${projection.delivery.state}; observed ${projection.delivery.observed_at ?? "unknown"}; expires ${projection.delivery.expires_at ?? "unknown"}; telemetry ${projection.telemetry.state}; ${projection.reason.replaceAll("_", " ")}`
    : "Telegram status is unverified, current observations could not be read";
  for (const route of ["a", "b"]) {
    const state = $("gateway-" + route + "-state");
    const detail = $("gateway-" + route + "-detail");
    const observation = backends.find((item) => item.backend === route.toUpperCase() && item.model === cfg.model);
    state.textContent = observation && fresh(observation) ? observation.state : "UNVERIFIED";
    detail.textContent = observation
      ? `${cfg.model}; ${observation.reason.replaceAll("_", " ")}; observed ${observation.observed_at}; expires ${observation.expires_at}`
      : `${cfg.model}; current backend observation missing`;
  }
  const native = projection?.telemetry;
  const traffic = native?.scope === "native_gateway_requests_including_bot_and_direct_clients" && native?.model === cfg.model && Array.isArray(native?.backends)
    ? native.backends : [];
  const currentTraffic = traffic.filter((item) => item.model === cfg.model && ["A", "B"].includes(item.backend) && traffic.filter((other) => other.backend === item.backend).length === 1 && item.state === "FRESH" && fresh(item) && Array.isArray(item.counters) && item.counters.length && new Set(item.counters.map((entry) => `${entry.outcome}:${entry.reason}`)).size === item.counters.length && item.counters.every((entry) => typeof entry.outcome === "string" && typeof entry.reason === "string" && typeof entry.value === "number" && Number.isFinite(entry.value) && entry.value >= 0));
  const measured = currentTraffic.map((item) => item.backend);
  const trafficState = new Set(measured).size === 2 ? "CURRENT" : measured.length ? "PARTIAL" : "UNVERIFIED";
  const total = (outcome: string): string => measured.length && currentTraffic.every((item) => item.counters.some((entry) => entry.outcome === outcome))
    ? currentTraffic.reduce((sum, item) => sum + item.counters.filter((entry) => entry.outcome === outcome).reduce((count, entry) => count + entry.value, 0), 0).toLocaleString()
    : "unknown";
  const gateway = eligible.length === backends.length && backends.length ? "AVAILABLE" : eligible.length ? "DEGRADED" :
    backends.length && backends.every((item) => item.model === cfg.model && fresh(item) && item.state === "UNAVAILABLE") ? "UNAVAILABLE" : "UNVERIFIED";
  const values = ["unknown", "unknown", total("success"), total("failed"), "unknown"];
  const labels = ["Active native requests", "Input tokens", "Successful native requests", "Failed native requests", "Network capacity"];
  [...$("quality-metrics").children].forEach((card, index) => {
    card.querySelector("strong").textContent = values[index];
    card.querySelector("span").textContent = labels[index];
    card.querySelector("small").textContent = index === 2 || index === 3
      ? `Native ${measured.join(" + ") || "unknown"}; includes bot and direct clients; other backend data not inferred`
      : "Not measured by native request counters";
  });
  $("quality-active").textContent = "unknown";
  $("quality-accepted").textContent = total("success");
  $("quality-rejected").textContent = total("failed");
  $("quality-failure-label").textContent = "failed native requests since restart";
  $("quality-health-state").textContent = `A/B ${gateway}; telemetry ${trafficState}`;
  $("quality-health").dataset.state = eligible.length ? "idle" : gateway === "UNAVAILABLE" ? "down" : "degraded";
  $("quality-recovery").hidden = true;
  $("quality-updated").textContent = `Native ${measured.join(" + ") || "unknown"}; source ${currentTraffic.map((item) => `${item.backend} observed ${item.observed_at}, expires ${item.expires_at}`).join("; ") || "unverified"}`;
  for (const item of currentTraffic) {
    $("gateway-" + item.backend.toLowerCase() + "-detail").textContent +=
      `; native traffic ${item.counters.map((entry) => `${entry.outcome}:${entry.reason}=${entry.value}`).join(", ")}; metrics observed ${item.observed_at}, expires ${item.expires_at}`;
  }
}
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
  const fetchOrder = ++telegramStatusFetch;
  try {
    const health = await json(statusUrl("/telegram-consumer"));
    if (fetchOrder !== telegramStatusFetch) return;
    const projection = health.readiness_projection;
    if (health.status !== "ok" || projection?.schema_version !== 1 ||
        projection?.scope !== "telegram_model_backend" || projection?.model !== cfg.model ||
        !Number.isInteger(projection.revision) || !Array.isArray(projection.backends) ||
        !projection.bot || !projection.delivery || !projection.telemetry ||
        typeof projection.reason !== "string" ||
        !["LIVE", "BOT_FAILED", "UNAVAILABLE", "UNVERIFIED"].includes(projection.combined_state) ||
        !projection.backends.every((item) => item && typeof item.reason === "string" && typeof item.state === "string"))
      throw new Error("projection unverified");
    if (projection.revision < telegramProjectionRevision) return;
    telegramProjectionRevision = projection.revision;
    telegramProjection = projection;
  } catch {
    if (fetchOrder !== telegramStatusFetch) return;
    telegramProjection = null;
  }
  renderTelegramProjection();
}
const cards: Map<string, HTMLElement> = new Map();
// Configuration supplies display fallbacks only. A card exists only for a
// Host in the current bootstrap/P2P observation.
let observedNodes: Array<SiteNode> = [];
let cardGpuInventory: GpuInventory = new Map();
let cardSoftwareInventory: SoftwareInventory = new Map();
let cardDevShardInventory: SoftwareInventory = new Map();
let devShardInventoryWatermarks: Map<string, any> = new Map();
let devShardInventoryRequest = 0;
let cardHardwareInventory: HardwareInventory = new Map();
let retainedValidatorSet: any = null;
let validatorSetObservedAt = 0;
let publicChainState: any = null;
// Snapshot capability is independent of choosing another network. Production
// keeps its gateway configuration while consuming the same evidence as local.
let observerSnapshotMode = cfg.publicBootstrap === true;
let networkSnapshot: any = null;
let networkSocket: any = null;
let networkSocketRetry: ?TimeoutID = null;
let detailsInFlight: ?Promise<void> = null;
let expandedCardKeys: Array<string> = [];
let selectedCardKey = "";
let cardSequence = 0;
let hostDeckResizeFrame: ?number;

function nodeKey(node: SiteNode): string {
  return node.address || node.name;
}

function chainApiReferenceNode(): ?SiteNode {
  // The operator alias in the catalog (for example gdc-node0) is not the
  // network's advertised node name (node0).  The public hostname is the
  // common, externally observable identity used to select the chain API.
  if (chainRpcNodeMatches.length !== 1) return null;
  const expectedHost = String(chainRpcHost || "").toLowerCase();
  const matches = observedNodes.filter(
    (node) => String(node.publicHost || "").toLowerCase() === expectedHost,
  );
  return matches.length === 1 ? matches[0] : null;
}

function hostCardCapacity(totalCards: number): number {
  const width = document.documentElement.clientWidth || window.innerWidth;
  if (width <= 900) return 1;
  // A four-Host network is still a small enough inventory to keep every
  // desktop card open. Preserve normal card width and horizontal reachability
  // rather than turning the fourth Host into an unreadable vertical rail.
  if (totalCards <= 4) return totalCards;
  let capacity = Math.min(width < 1200 ? 2 : 4, totalCards);
  const deckWidth = $("nodes")?.clientWidth || width;
  const collapsedWidth = 32;
  const minimumExpandedWidth = 320;
  while (
    capacity > 1 &&
    (deckWidth - (totalCards - capacity) * collapsedWidth) / capacity <
      minimumExpandedWidth
  )
    capacity -= 1;
  return capacity;
}

function updateCardToggleLabel(card: HTMLElement): void {
  const button = card.querySelector(".node-toggle");
  if (!button) return;
  const host = card.querySelector('[data-k="host"]')?.textContent || "Host";
  const status = card.querySelector('[data-k="status"]')?.textContent || "Unknown";
  const expanded = card.classList.contains("is-expanded");
  button.setAttribute("aria-expanded", String(expanded));
  button.setAttribute(
    "aria-label",
    `${expanded ? "Host details for" : "Expand Host"} ${host}, status ${status}`,
  );
  button.title = expanded ? `${host} details are open` : `Expand ${host}`;
}

function setCardExpanded(card: HTMLElement, expanded: boolean): void {
  card.classList.toggle("is-expanded", expanded);
  card.classList.toggle("is-collapsed", !expanded);
  const details = card.querySelector(".node-details");
  if (details) details.hidden = !expanded;
  updateCardToggleLabel(card);
}

function layoutHostCards(): void {
  const deck = $("nodes");
  if (!deck) return;
  const orderedCards = [...deck.querySelectorAll(".node")];
  const orderedKeys = orderedCards
    .map((card) => card.dataset.nodeKey || "")
    .filter(Boolean);
  if (!orderedKeys.length) {
    expandedCardKeys = [];
    selectedCardKey = "";
    deck.dataset.expandedCount = "0";
    return;
  }
  const liveKeys = new Set(orderedKeys);
  expandedCardKeys = expandedCardKeys.filter((key) => liveKeys.has(key));
  if (!selectedCardKey || !liveKeys.has(selectedCardKey))
    selectedCardKey = expandedCardKeys[0] || orderedKeys[0];
  const capacity = hostCardCapacity(orderedKeys.length);
  if (!expandedCardKeys.length) {
    expandedCardKeys = orderedKeys.slice(0, capacity);
  } else {
    if (!expandedCardKeys.includes(selectedCardKey))
      expandedCardKeys.push(selectedCardKey);
    while (expandedCardKeys.length > capacity) {
      const removable = expandedCardKeys.findIndex(
        (key) => key !== selectedCardKey,
      );
      expandedCardKeys.splice(removable < 0 ? 0 : removable, 1);
    }
    for (const key of orderedKeys) {
      if (expandedCardKeys.length >= capacity) break;
      if (!expandedCardKeys.includes(key)) expandedCardKeys.push(key);
    }
  }
  const expanded = new Set(expandedCardKeys);
  for (const card of orderedCards)
    setCardExpanded(card, expanded.has(card.dataset.nodeKey || ""));
  deck.dataset.expandedCount = String(expandedCardKeys.length);
  deck.dataset.layout = window.innerWidth <= 700 ? "mobile" : "rail";
}

function activateHostCard(key: string): void {
  if (!cards.has(key)) return;
  selectedCardKey = key;
  if (!expandedCardKeys.includes(key)) expandedCardKeys.push(key);
  layoutHostCards();
}

function moveHostCardFocus(event: any, key: string): void {
  const buttons = [...$("nodes").querySelectorAll(".node-toggle")];
  const current = buttons.indexOf(cards.get(key)?.querySelector(".node-toggle"));
  if (current < 0) return;
  let next = current;
  if (event.key === "ArrowRight" || event.key === "ArrowDown")
    next = (current + 1) % buttons.length;
  else if (event.key === "ArrowLeft" || event.key === "ArrowUp")
    next = (current - 1 + buttons.length) % buttons.length;
  else if (event.key === "Home") next = 0;
  else if (event.key === "End") next = buttons.length - 1;
  else return;
  event.preventDefault();
  buttons[next]?.focus();
}

function createCard(node: SiteNode): HTMLElement {
  const key = nodeKey(node);
  const el = document.createElement("article");
  const detailsId = `host-details-${++cardSequence}`;
  el.className = `node ${node.mode || "active"} is-collapsed`;
  el.dataset.nodeKey = key;
  el.dataset.nodeName = node.name;
  el.setAttribute("role", "listitem");
  el.innerHTML = `
    <h3>
      <button class="node-toggle" type="button" aria-expanded="false" aria-controls="${detailsId}">
        <span class="node-host" data-k="host"></span>
        <span class="status" data-k="status"></span>
      </button>
    </h3>
    <div class="node-details" id="${detailsId}" hidden>
      <small class="node-identity" data-k-row="node-id" hidden>
        <span>node id</span>
        <div class="copy-field">
          <code data-k="node-id"></code>
          <button class="copy-value" type="button" data-copy-value="node-id" data-copy-label="Copy node ID" data-copy-success="Node ID copied" title="Copy node ID">
            <svg class="copy-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <rect x="9" y="9" width="10" height="10" rx="1"></rect>
              <path d="M15 9V6a1 1 0 0 0-1-1H6a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h3"></path>
            </svg>
            <svg class="copy-success-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <path d="m5 12 4.2 4.2L19 6.5"></path>
            </svg>
            <span class="sr-only">Copy node ID</span>
          </button>
          <span class="sr-only" data-k="copy-status" aria-live="polite"></span>
        </div>
      </small>
      <div class="metric">
        <span>height</span>
        <b data-k="height"></b>
      </div>
      <div class="metric">
        <span>voting power</span>
        <b data-k="vp"></b>
      </div>
      <div class="metric account" data-k-row="account" hidden>
        <span>account</span>
        <div class="copy-field">
          <code data-k="account"></code>
          <button class="copy-value" type="button" data-copy-value="account" data-copy-label="Copy account address" data-copy-success="Account address copied" title="Copy account address">
            <svg class="copy-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <rect x="9" y="9" width="10" height="10" rx="1"></rect>
              <path d="M15 9V6a1 1 0 0 0-1-1H6a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h3"></path>
            </svg>
            <svg class="copy-success-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
              <path d="m5 12 4.2 4.2L19 6.5"></path>
            </svg>
            <span class="sr-only">Copy account address</span>
          </button>
          <span class="sr-only" data-k="copy-status" aria-live="polite"></span>
        </div>
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
      <div class="metric"><span>PoC contribution</span><b data-k="poc">Checking…</b></div>
      <div class="metric" data-k-row="cpoc"><span>cPoC contribution</span><b data-k="cpoc">Checking…</b></div>
      <div class="metric"><span>inference traffic</span><b data-k="inference">Checking…</b></div>
      <div class="metric inferenced" data-k-row="inferenced">
        <span>inferenced</span>
        <b data-k="inferenced"></b>
      </div>
      <div class="metric dapi" data-k-row="dapi">
        <span>DAPI</span>
        <b data-k="dapi"></b>
      </div>
      <div class="metric devshard" data-k-row="devshard">
        <span>DevShard</span>
        <b data-k="devshard"></b>
      </div>
      <div class="metric mlnode" data-k-row="mlnode" hidden>
        <span>MLNode</span>
        <ul class="mlnode-list" data-k="mlnode"></ul>
      </div>
      <div class="metric models" data-k-row="models">
        <span>Models</span>
        <ul class="mlnode-list" data-k="models"></ul>
      </div>
    </div>
  `;
  set(el, "host", node.publicHost || node.name);
  set(el, "status", node.mode === "skip" ? "SKIP" : "checking…");
  set(el, "height", node.mode === "skip" ? "–" : "…");
  set(el, "vp", node.mode === "skip" ? "Unavailable" : "Unavailable");
  set(el, "sync", node.mode === "skip" ? "Unknown" : "Unknown");
  set(el, "endpoint", node.mode === "skip" ? "Unknown" : "Unknown");
  set(el, "peers", node.mode === "skip" ? "–" : "…");
  updateSoftware(cardSoftwareInventory, node, el);
  updateMlNodes(cardSoftwareInventory, cardHardwareInventory, node, el);
  updateNodeModels(node, el);
  updateDevShards(node, el);
  renderNodeIdentity(el, node);
  if (node.mode === "skip")
    el.querySelector('[data-k="status"]').className = "status skip";
  $("nodes").append(el);
  cards.set(key, el);
  el.querySelector(".node-toggle").addEventListener("click", () =>
    activateHostCard(key),
  );
  el.querySelector(".node-toggle").addEventListener("keydown", (event) =>
    moveHostCardFocus(event, key),
  );
  for (const button of el.querySelectorAll(".copy-value")) {
    button.addEventListener("click", (event) => {
      const target: any = event.currentTarget;
      const key = String(target?.dataset.copyValue || "");
      const value = String(el.querySelector('[data-k="' + key + '"]')?.textContent || "").trim();
      const label = String(target?.dataset.copyLabel || "Copy value");
      const success = String(target?.dataset.copySuccess || "Copied");
      if (value) copyValue(value, target, label, success);
    });
  }
  updateCardToggleLabel(el);
  return el;
}

function copyValue(value: string, target: HTMLElement, label: string, success: string): void {
  const copied = (): void => {
    target.title = "Copied";
    target.setAttribute("aria-label", success);
    target.dataset.copied = "true";
    const status = target.parentElement?.querySelector('[data-k="copy-status"]');
    if (status) status.textContent = success;
    window.setTimeout(() => {
      target.title = label;
      target.removeAttribute("data-copied");
      target.setAttribute("aria-label", `${label} ${value}`);
      if (status) status.textContent = "";
    }, 1500);
  };
  const clipboard = (window: any).navigator?.clipboard;
  if (clipboard?.writeText) {
    clipboard.writeText(value).then(copied).catch(() => {});
    return;
  }
  const input: any = document.createElement("textarea");
  input.value = value;
  input.setAttribute("readonly", "");
  input.style.position = "fixed";
  input.style.opacity = "0";
  document.body.append(input);
  input.select();
  try { if (document.execCommand("copy")) copied(); } finally { input.remove(); }
}

function updateDevShardVersions(
  versions: Array<DevShardVersion>,
): void {
  const target = $("devshard-versions");
  if (!versions.length) {
    target.textContent = "None approved";
    target.title = "Chain state reports no approved DevShard versions";
    return;
  }
  target.textContent = versions.map((version) => version.name).join(" · ");
  target.title = versions
    .map((version) => `${version.name}: ${version.sha256}`)
    .join("\n");
}

function markDevShardVersionsUnavailable(): void {
  const target = $("devshard-versions");
  target.textContent = "Unavailable";
  target.title = "Approved DevShard versions could not be read from verified chain state";
}

function formatEpochDuration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.ceil((total % 3600) / 60);
  if (days) return `${days}d ${hours}h`;
  if (hours) return `${hours}h ${minutes}m`;
  if (minutes) return `${minutes} min`;
  return "under 1 min";
}

function normalizedCpocEvents(cpoc: any): Array<any> {
  if (cpoc?.state !== "observed" || !Array.isArray(cpoc.recent_events)) return [];
  return cpoc.recent_events.map((event) => ({
    epoch: String(event?.epoch_index || ""),
    sequence: String(event?.event_sequence || ""),
    trigger: String(event?.trigger_height || ""),
    generation: String(event?.generation_start_height || ""),
    phase: String(event?.phase || "").replace(/^CONFIRMATION_POC_/, "").replaceAll("_", " ").toLowerCase(),
  })).filter((event) => /^[1-9]\d*$/.test(event.epoch) && /^\d+$/.test(event.sequence) &&
    /^[1-9]\d*$/.test(event.trigger) && event.phase);
}

function renderEpochOverview(epoch: any, reference: any, cpoc: any): void {
  const overview = $("epoch-overview");
  if (!overview) return;
  const index = String(epoch?.latest_epoch?.index || "");
  const start = Number(epoch?.latest_epoch?.poc_start_block_height);
  const end = Number(epoch?.latest_epoch?.end_height);
  const height = Number(reference?.height);
  const reportedRemaining = Number(epoch?.latest_epoch?.blocks_remaining);
  if (!/^[1-9]\d*$/.test(index) || !Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
    !Number.isSafeInteger(height) || start <= 0 || end <= start || height < start) {
    overview.hidden = true;
    return;
  }
  const remaining = Number.isSafeInteger(reportedRemaining) && reportedRemaining >= 0
    ? reportedRemaining : Math.max(0, end - height);
  const progress = Math.max(0, Math.min(100, ((height - start) / (end - start)) * 100));
  const estimatedSeconds = Number(epoch?.estimated_remaining_seconds);
  const blockInterval = Number(epoch?.block_interval_seconds);
  const hasEstimate = Number.isFinite(estimatedSeconds) && estimatedSeconds >= 0;
  const countdown = hasEstimate ? `≈ ${formatEpochDuration(estimatedSeconds)} left` : `${remaining.toLocaleString()} blocks left`;
  const interval = Number.isFinite(blockInterval) && blockInterval > 0
    ? ` · ~${blockInterval.toFixed(blockInterval % 1 ? 1 : 0)} s/block` : "";
  $("epoch-label").textContent = `Epoch ${index}`;
  $("epoch-progress-bar").style.width = `${progress.toFixed(1)}%`;
  $("epoch-progress-track").setAttribute("aria-valuenow", String(Math.round(progress)));
  $("epoch-progress-track").setAttribute("aria-valuetext", `${remaining.toLocaleString()} blocks left in epoch ${index}`);
  $("epoch-progress-detail").textContent = `Height ${height.toLocaleString()} of ${end.toLocaleString()}`;
  $("epoch-remaining").textContent = countdown;
  $("epoch-remaining").title = hasEstimate
    ? "Estimate from the observed interval between recent blocks"
    : "Block timing is not available from the current chain observation";
  $("epoch-end").textContent = `${remaining.toLocaleString()} blocks remaining${interval}`;
  $("epoch-poc-state").textContent = `Current stage starts at height ${start.toLocaleString()}`;
  const cpocState = $("epoch-cpoc-state");
  const cpocDetail = $("epoch-cpoc-detail");
  const events = normalizedCpocEvents(cpoc);
  if (cpoc?.state !== "observed") {
    cpocState.textContent = "Not reported";
    cpocDetail.textContent = "The current chain observation did not include cPoC state.";
  } else if (cpoc.active === true) {
    const phase = String(cpoc?.event?.phase || "").replace(/^CONFIRMATION_POC_/, "").replaceAll("_", " ").toLowerCase();
    const trigger = Number(cpoc?.event?.trigger_height);
    const generation = Number(cpoc?.event?.generation_start_height);
    cpocState.textContent = phase ? `Active · ${phase}` : "Active";
    const eventDetail = Number.isSafeInteger(trigger) && trigger > 0
      ? `Trigger height ${trigger.toLocaleString()}${Number.isSafeInteger(generation) && generation > 0 ? ` · generation starts at ${generation.toLocaleString()}` : ""}.`
      : "The active event did not include its stage height.";
    cpocDetail.textContent = events.length
      ? `${eventDetail} Latest recorded: ${events.map((event) => `E${event.epoch} #${event.sequence} ${event.phase}`).join(" · ")}.`
      : eventDetail;
  } else {
    cpocState.textContent = "No active event";
    cpocDetail.textContent = events.length
      ? `Latest recorded: ${events.map((event) => `E${event.epoch} #${event.sequence} ${event.phase}; trigger ${event.trigger}${/^[1-9]\d*$/.test(event.generation) ? `; generation ${event.generation}` : ""}`).join(" · ")}.`
      : cpoc.recent_events_state === "observed"
        ? "No cPoC events were recorded in the observed epoch window."
        : "Recent cPoC events were not reported.";
  }
  overview.hidden = false;
}

function formatChainQuantity(value: any): string {
  const raw = String(value ?? "");
  return /^\d+$/.test(raw) ? raw.replace(/\B(?=(\d{3})+(?!\d))/g, ",") : "–";
}

function resultParticipantLabel(address: string): {label: string, title: string} {
  return {label: address.length > 18 ? `${address.slice(0, 10)}…${address.slice(-6)}` : address, title: address};
}

function resultCommitments(result: any, address: string): {label: string, detail: string, state: string} {
  if (!Array.isArray(result?.poc_commits))
    return {label: "Unavailable", detail: "The finalized PoC commitment query was unavailable.", state: "unavailable"};
  const commitments = result.poc_commits.filter((commit) => String(commit?.participant_address || "") === address);
  if (!commitments.length)
    return {label: "No commitment recorded", detail: "No commitment was recorded for this participant at the finalized epoch PoC stage.", state: "observed"};
  const detail = commitments.map((commit) => `${String(commit?.model_id || "model not reported")}: ${formatChainQuantity(commit?.count)} artifacts`).join(" · ");
  return {label: detail, detail: "Committed artifacts are evidence of submission, not a validation outcome.", state: "observed"};
}

function validationTally(submissions: Array<any>): {accepted: number, rejected: number, unavailable: number} {
  let accepted = 0;
  let rejected = 0;
  let unavailable = 0;
  for (const submission of submissions) {
    const raw = String(submission?.validated_weight || "");
    if (!/^-?\d+$/.test(raw)) unavailable += 1;
    else if (BigInt(raw) > 0n) accepted += 1;
    else rejected += 1;
  }
  return {accepted, rejected, unavailable};
}

function attestationsLabel(tally: {accepted: number, rejected: number, unavailable: number}): string {
  return [
    `${tally.accepted} accepted`,
    `${tally.rejected} rejected`,
    tally.unavailable ? `${tally.unavailable} unreadable` : "",
  ].filter(Boolean).join(" · ");
}

function resultAttestations(result: any, address: string): {label: string, detail: string, state: string} {
  if (!Array.isArray(result?.poc_votes))
    return {label: "Unavailable", detail: "The finalized PoC validation query was unavailable.", state: "unavailable"};
  const submissions = result.poc_votes.filter((vote) => String(vote?.participant_address || "") === address &&
    String(vote?.poc_stage_start_block_height || "") === String(result?.poc_start_block_height || ""));
  if (!submissions.length)
    return {label: "No attestation recorded", detail: "No validator attestation was recorded for this participant at the finalized PoC stage.", state: "observed"};
  return {
    label: attestationsLabel(validationTally(submissions)),
    detail: "Each attestation is a validator's vote on this participant's PoC work. It is not the complete epoch outcome.",
    state: "observed",
  };
}

function resultValidatorState(value: any): string {
  if (value?.state === "observed") return formatChainQuantity(value.voting_power);
  if (value?.state === "not_in_set") return "Not in set";
  if (value?.state === "unmapped") return "Not mapped";
  return "Unavailable";
}

function appendVerificationCell(row: HTMLElement, label: string, detail: string, state: string = "observed"): void {
  const cell = document.createElement("td");
  cell.textContent = label;
  cell.title = detail;
  cell.dataset.state = state;
  row.append(cell);
}

function appendVerificationEmpty(body: HTMLElement, columns: number, message: string): void {
  const row = document.createElement("tr");
  const cell = document.createElement("td");
  cell.colSpan = columns;
  cell.textContent = message;
  row.append(cell);
  body.append(row);
}

function consensusSummary(rows: Array<any>): {label: string, detail: string, state: string} {
  const observed = rows.filter((row) => row?.effective_validator?.state === "observed");
  const comparable = rows.filter((row) => {
    const previous = String(row?.previous_effective_validator?.state || "");
    const effective = String(row?.effective_validator?.state || "");
    return ["observed", "not_in_set"].includes(previous) && ["observed", "not_in_set"].includes(effective);
  });
  if (!comparable.length)
    return {label: "Unavailable", detail: "The complete historical validator-set comparison was unavailable.", state: "unavailable"};
  const membershipChanges = comparable.filter((row) =>
    String(row.previous_effective_validator?.state) !== String(row.effective_validator?.state)).length;
  const powerChanges = comparable.filter((row) => row.previous_effective_validator?.state === "observed" &&
    row.effective_validator?.state === "observed" &&
    String(row.previous_effective_validator?.voting_power) !== String(row.effective_validator?.voting_power)).length;
  const detail = `${membershipChanges} membership change${membershipChanges === 1 ? "" : "s"} · ${powerChanges} power change${powerChanges === 1 ? "" : "s"}`;
  return {label: `${observed.length} member${observed.length === 1 ? "" : "s"}`, detail, state: "observed"};
}

function pocSummary(result: any): {label: string, detail: string, state: string} {
  if (!Array.isArray(result?.poc_commits) || !Array.isArray(result?.poc_votes))
    return {label: "Unavailable", detail: "The finalized PoC commitment or validation query was unavailable.", state: "unavailable"};
  const committers = new Set(result.poc_commits.map((commit) => String(commit?.participant_address || "")).filter(Boolean));
  const votes = result.poc_votes.filter((vote) => String(vote?.poc_stage_start_block_height || "") === String(result?.poc_start_block_height || ""));
  return {
    label: `${committers.size} participant${committers.size === 1 ? "" : "s"} committed · ${votes.length} validator attestation${votes.length === 1 ? "" : "s"}`,
    detail: attestationsLabel(validationTally(votes)),
    state: "observed",
  };
}

function cpocSummary(events: any, epoch: string): {label: string, detail: string, state: string} {
  if (!Array.isArray(events))
    return {label: "Unavailable", detail: "The cPoC event-history query was unavailable.", state: "unavailable"};
  if (!events.length)
    return {label: "No event", detail: `No cPoC event was recorded in epoch ${formatChainQuantity(epoch)}.`, state: "observed"};
  const completed = events.filter((event) => String(event?.phase || "") === "CONFIRMATION_POC_COMPLETED").length;
  const eventDetail = events.map((event) => `#${String(event?.event_sequence || "?")} ${String(event?.phase || "unknown").replace(/^CONFIRMATION_POC_/, "").replaceAll("_", " ").toLowerCase()} at trigger ${formatChainQuantity(event?.trigger_height)}`).join(" · ");
  return {label: `${events.length} event${events.length === 1 ? "" : "s"}`, detail: `${completed} completed · ${eventDetail}`, state: "observed"};
}

function renderFinalizedEpochResults(result: any): void {
  const section = $("verification-results");
  if (!section) return;
  const epoch = String(result?.epoch_index || "");
  const stage = String(result?.poc_start_block_height || "");
  const effectiveHeight = String(result?.effective_block_height || "");
  const rows = Array.isArray(result?.participants) ? result.participants : null;
  if (result?.state !== "observed" || !/^[1-9]\d*$/.test(epoch) || !/^[1-9]\d*$/.test(stage) ||
    !/^[1-9]\d*$/.test(effectiveHeight) || rows === null) {
    section.hidden = true;
    return;
  }
  const previousEpoch = String(result?.previous_epoch_index || "");
  const previousHeight = String(result?.previous_effective_block_height || "");
  $("verification-epoch-label").textContent = `E${formatChainQuantity(epoch)}`;
  $("verification-results-summary").textContent = /^[1-9]\d*$/.test(previousEpoch) && /^[1-9]\d*$/.test(previousHeight)
    ? `PoC stage ${formatChainQuantity(stage)} · effective at ${formatChainQuantity(effectiveHeight)} · previous effective height ${formatChainQuantity(previousHeight)}`
    : `PoC stage ${formatChainQuantity(stage)} · effective at ${formatChainQuantity(effectiveHeight)}`;
  const poc = pocSummary(result);
  $("verification-poc-state").textContent = poc.label;
  $("verification-poc-detail").textContent = poc.detail;
  $("verification-poc-state").dataset.state = poc.state;
  const events = Array.isArray(result?.cpoc_events) ? result.cpoc_events : null;
  const cpoc = cpocSummary(events, epoch);
  $("verification-cpoc-events").textContent = cpoc.label;
  $("verification-cpoc-detail").textContent = cpoc.detail;
  $("verification-cpoc-events").dataset.state = cpoc.state;
  const consensus = consensusSummary(rows);
  $("verification-consensus-state").textContent = consensus.label;
  $("verification-consensus-detail").textContent = consensus.detail;
  $("verification-consensus-state").dataset.state = consensus.state;
  const pocBody = $("verification-poc-result-rows");
  const consensusBody = $("verification-consensus-result-rows");
  pocBody.replaceChildren();
  consensusBody.replaceChildren();
  const ordered = rows.slice().sort((left, right) => String(left?.participant_address || "").localeCompare(String(right?.participant_address || "")));
  if (!ordered.length) {
    appendVerificationEmpty(pocBody, 3, "No participant weights were recorded for this finalized epoch.");
    appendVerificationEmpty(consensusBody, 4, "No participant weights were recorded for this finalized epoch.");
  }
  for (const resultRow of ordered) {
    const address = String(resultRow?.participant_address || "");
    if (!/^gonka1[0-9a-z]+$/i.test(address)) continue;
    const participant = resultParticipantLabel(address);
    const pocRow = document.createElement("tr");
    appendVerificationCell(pocRow, participant.label, participant.title);
    const commitments = resultCommitments(result, address);
    appendVerificationCell(pocRow, commitments.label, commitments.detail, commitments.state);
    const attestations = resultAttestations(result, address);
    appendVerificationCell(pocRow, attestations.label, attestations.detail, attestations.state);
    pocBody.append(pocRow);
    const consensusRow = document.createElement("tr");
    appendVerificationCell(consensusRow, participant.label, participant.title);
    const previous = resultValidatorState(resultRow?.previous_effective_validator);
    const effective = resultValidatorState(resultRow?.effective_validator);
    const currentState = String(resultRow?.effective_validator?.state || "unavailable");
    appendVerificationCell(consensusRow, previous,
      "Complete consensus validator set at the previous effective height.", String(resultRow?.previous_effective_validator?.state || "unavailable"));
    appendVerificationCell(consensusRow, effective,
      "Complete consensus validator set at this epoch's activation height.", currentState);
    const change = previous === effective ? "Unchanged" : `${previous} → ${effective}`;
    appendVerificationCell(consensusRow, change,
      "Observed membership and power change between complete validator sets. This is not a causal diagnosis.", currentState);
    consensusBody.append(consensusRow);
  }
  section.hidden = false;
}

function publicEndpointLabel(value: any): string {
  try {
    const parsed = new URL(String(value || ""));
    return String(parsed.origin || "").replace(/^https?:\/\//, "") || String(value || "");
  } catch { return String(value || ""); }
}

function devShardEndpointObservations(nodes: Array<SiteNode>): Array<any> {
  const endpoints: Map<string, any> = new Map();
  for (const node of nodes) {
    const health = node.devShardHealth;
    const endpoint = normalizedPublicOrigin(health?.source_endpoint || node.dapiUrl);
    const previous = endpoints.get(endpoint);
    if (endpoint && (!previous || (Date.parse(String(health?.observed_at || "")) || 0) >
      (Date.parse(String(previous.health?.observed_at || "")) || 0))) endpoints.set(endpoint, {endpoint, health});
  }
  return [...endpoints.values()].sort((left, right) => left.endpoint.localeCompare(right.endpoint));
}

function runningDevShardRuntimes(health: any): Array<any> {
  if (health?.state !== "observed" || !Array.isArray(health.runtimes)) return [];
  return health.runtimes.filter((runtime) => String(runtime?.name || "").trim() &&
    String(runtime?.status || "").toLowerCase() === "running")
    .sort((left, right) => String(left.name).localeCompare(String(right.name), undefined, {numeric: true}));
}

function devShardRuntimeLabel(runtime: any): string {
  const name = String(runtime?.name || "unknown").trim();
  const binary = String(runtime?.binary_version || "").trim();
  return binary && binary !== name ? `${name} (${binary})` : name;
}

function devShardObservationFresh(value: any): boolean {
  const observedAt = Date.parse(String(value?.observed_at || ""));
  return value?.state === "observed" && Number.isFinite(observedAt) &&
    observedAt <= Date.now() && Date.now() - observedAt <= 90000;
}

function devShardSessionFresh(value: any): boolean {
  if (!devShardObservationFresh(value) || !Array.isArray(value?.active_escrows)) return false;
  const observedAt = Date.parse(String(value.observed_at)) / 1000;
  const cachedAt = Number(value.cached_at);
  const ttl = Number(value.cache_ttl_seconds);
  return Number.isFinite(cachedAt) && cachedAt > 0 && Number.isFinite(ttl) && ttl >= 0 &&
    cachedAt <= observedAt + 5 && observedAt - cachedAt <= ttl + 5;
}

function renderDevShardExecution(approvals: ?Array<any>, nodes: Array<SiteNode>): void {
  const section = $("devshard-execution");
  if (!section) return;
  const endpoints = devShardEndpointObservations(nodes);
  if (!endpoints.length) {
    section.hidden = true;
    return;
  }
  const observed = endpoints.filter((entry) => devShardObservationFresh(entry.health));
  const runtimes = observed.flatMap((entry) => runningDevShardRuntimes(entry.health));
  const approved = new Map(
    (approvals || []).filter((entry) => String(entry?.name || "") && /^[0-9a-f]{64}$/i.test(String(entry?.sha256 || "")))
      .map((entry) => [String(entry.name), String(entry.sha256).toLowerCase()]),
  );
  const matching = runtimes.filter((runtime) =>
    approved.get(String(runtime?.name || "")) === String(runtime?.sha256 || "").toLowerCase());
  const stats = observed.map((entry) => entry.health?.stats).filter(devShardSessionFresh);
  const escrows = new Set(stats.flatMap((value) => Array.isArray(value?.active_escrows) ? value.active_escrows : []));
  const endpointLabel = `${observed.length} / ${endpoints.length} observed`;
  $("devshard-endpoint-state").textContent = endpointLabel;
  $("devshard-endpoint-detail").textContent = "Health responses from distinct public endpoints in the peer observation.";
  if (!observed.length) {
    $("devshard-runtime-state").textContent = "Unavailable";
    $("devshard-runtime-detail").textContent = "No fresh public health response is available.";
  } else if (!runtimes.length) {
    $("devshard-runtime-state").textContent = "No running runtime";
    $("devshard-runtime-detail").textContent = "No running runtime was reported by the observed public health endpoints.";
  } else if (!approvals) {
    $("devshard-runtime-state").textContent = "Approval unavailable";
    $("devshard-runtime-detail").textContent = `${runtimes.length} running runtime report${runtimes.length === 1 ? "" : "s"}; the chain-approved catalog could not be read.`;
  } else if (!approved.size) {
    $("devshard-runtime-state").textContent = "No approved runtime";
    $("devshard-runtime-detail").textContent = `${runtimes.length} running runtime report${runtimes.length === 1 ? "" : "s"}; the chain-approved catalog is empty.`;
  } else {
    $("devshard-runtime-state").textContent = `${matching.length} / ${runtimes.length} SHA match`;
    $("devshard-runtime-detail").textContent = "Running runtime hashes compared with the current chain-approved catalog.";
  }
  if (stats.length) {
    $("devshard-session-state").textContent = `${escrows.size} reported escrow${escrows.size === 1 ? "" : "s"}`;
    $("devshard-session-detail").textContent = `${stats.length} responding endpoint${stats.length === 1 ? "" : "s"} · primary runtime only · duplicate escrow IDs counted once.`;
  } else {
    $("devshard-session-state").textContent = "Not observed";
    $("devshard-session-detail").textContent = "No fresh host-local session snapshot is available.";
  }
  const observedAt = Math.min(...observed.map((entry) => Date.parse(String(entry.health.observed_at))));
  $("devshard-execution-summary").textContent = Number.isFinite(observedAt)
    ? `Health observed ${new Date(observedAt).toISOString().slice(11, 19)} UTC`
    : "Waiting for fresh health observations";
  const body = $("devshard-execution-rows");
  body.replaceChildren();
  for (const entry of endpoints) {
    const row = document.createElement("tr");
    appendVerificationCell(row, publicEndpointLabel(entry.endpoint), "Public endpoint deduplicated from the current peer observation.", String(entry.health?.state || "unavailable"));
    const fresh = devShardObservationFresh(entry.health);
    const endpointRuntimes = fresh ? runningDevShardRuntimes(entry.health) : [];
    const runtimeDetail = endpointRuntimes.length
      ? endpointRuntimes.map((runtime) => {
        const expected = approved.get(String(runtime?.name || ""));
        const received = String(runtime?.sha256 || "").toLowerCase();
        const hashState = !approvals ? "SHA unverified" : !expected ? "Not approved"
          : !/^[0-9a-f]{64}$/.test(received) ? "SHA unavailable" : expected === received ? "SHA match" : "SHA differs";
        return `${devShardRuntimeLabel(runtime)} · ${hashState}`;
      }).join("\n")
      : fresh ? "No running runtime" : entry.health?.state === "observed" ? "Stale health response" : "Unavailable";
    appendVerificationCell(row,
      runtimeDetail,
      String(entry.health?.error || "Running binaries compared by protocol name and reported SHA with the chain-approved catalog."), fresh ? "observed" : "unavailable");
    const session = entry.health?.stats;
    if (fresh && devShardSessionFresh(session)) {
      const active = [...new Set(session.active_escrows)];
      const version = devShardRuntimeLabel({name: session.protocol_version, binary_version: session.binary_version});
      const list = active.map((id) => {
        const shard = Array.isArray(session.shards) ? session.shards.find((item) => item?.escrow_id === id) : null;
        return `#${id}${shard ? ` · E${formatChainQuantity(shard.epoch_id)}` : ""}`;
      });
      appendVerificationCell(row, [`${active.length} active escrow${active.length === 1 ? "" : "s"}`, version, ...list].join("\n"),
        `Snapshot ${new Date(Number(session.cached_at) * 1000).toISOString()} · cache TTL ${session.cache_ttl_seconds}s · host epoch ${formatChainQuantity(session.current_epoch_id)}.`, "observed");
    } else if (session?.state === "observed") {
      appendVerificationCell(row, "Stale snapshot", "The cached session list or its observation has expired.", "unavailable");
    } else if (session?.state === "not_exposed") {
      appendVerificationCell(row, "Not exposed", "A v4+ runtime was not reported, so this endpoint's host-local session list was not queried.", "not_exposed");
    } else {
      appendVerificationCell(row, "Unavailable", String(session?.error || "The host-local session snapshot was unavailable."), "unavailable");
    }
    body.append(row);
  }
  section.hidden = false;
}

function monitoredGpuRecords(inventory: GpuInventory, keys: Array<?string>): Array<GpuRecord> {
  const key = keys.find((candidate) => inventory.has(String(candidate || "")));
  return inventory.get(String(key || "")) || [];
}

function reportedGpuRecords(runtime: any): Array<GpuRecord> {
  const records: Array<GpuRecord> = [];
  if (!Array.isArray(runtime?.hardware)) return records;
  for (const item of runtime.hardware) {
    const [name, reportedMemory] = String(item?.type || "")
      .split("|", 2)
      .map((part) => part.trim());
    const count = Number(item?.count || 0);
    if (!name || !Number.isSafeInteger(count) || count <= 0) continue;
    // Public inventory must not control unbounded browser allocations. Reject
    // an oversized runtime report instead of truncating its apparent capacity.
    if (count > 256 || records.length + count > 256) return [];
    const memoryMatch = String(reportedMemory || "").match(/^(\d+(?:\.\d+)?)\s*(?:gi?b|gb)$/i);
    const memoryLabel = memoryMatch ? `${memoryMatch[1]} GiB` : "";
    records.push(...Array(count).fill({ name, memoryBytes: null, memoryLabel }));
  }
  return records;
}

function runtimeLocation(runtime: any): string {
  const host = String(runtime?.host || "").trim().toLowerCase();
  return !host || ["inference", "localhost", "127.0.0.1"].includes(host)
    ? "local"
    : "net";
}

function runtimeGpuRecords(node: SiteNode, runtime: any, inventory: GpuInventory): Array<GpuRecord> {
  const host = String(runtime?.host || "").trim();
  const local = runtimeLocation(runtime) === "local";
  const monitored = monitoredGpuRecords(inventory, local
    ? [node.gpuHost, node.publicHost, node.name]
    : [host]);
  return monitored.length ? monitored : reportedGpuRecords(runtime);
}

function gpuInventory(node: SiteNode, inventory: GpuInventory, hardwareInventory: HardwareInventory): {
  gpus: Array<GpuRecord>,
  hardwareObserved: boolean,
} {
  const hardware = node.address ? hardwareInventory.get(node.address) : null;
  const gpus = hardware?.state === "observed" && hardware.nodes.length
    ? hardware.nodes.flatMap((runtime) => runtimeGpuRecords(node, runtime, inventory))
    : monitoredGpuRecords(inventory, [node.gpuHost, node.publicHost, node.name]);
  return { gpus, hardwareObserved: hardware?.state === "observed" };
}

function gpuCount(node: SiteNode): number {
  return gpuInventory(node, cardGpuInventory, cardHardwareInventory).gpus.length;
}

function formatGpuRecords(gpus: Array<GpuRecord>): string {
  if (!gpus.length) return "GPU not reported";
  const grouped: Map<string, number> = new Map();
  for (const gpu of gpus) {
    const name = String(gpu.name || "").replace(/^NVIDIA\s+/i, "").trim();
    const gib = Number(gpu.memoryBytes) / (1024 ** 3);
    const memory = gpu.memoryLabel
      ? ` · ${gpu.memoryLabel}`
      : Number.isFinite(gib) && gib > 0 ? ` · ${Math.round(gib)} GiB` : "";
    const label = `${name || "GPU"}${memory}`;
    grouped.set(label, (grouped.get(label) || 0) + 1);
  }
  return [...grouped.entries()].map(([label, count]) =>
    count === 1 ? label : `${label} ×${count}`,
  ).join(" + ");
}

function reportedSoftwareVersion(node: SiteNode, component: string): string {
  const state: any = node.softwareVersions;
  if (component === "chain") {
    if (node.observedInferenceVersion) return node.observedInferenceVersion;
    if (node.inferenceObservationRejected) return "";
    return GDC_SOFTWARE_VERSIONS.freshPayloadVersion(state, "chain");
  }
  if (component === "DAPI") return GDC_SOFTWARE_VERSIONS.freshPayloadVersion(state, "DAPI");
  return "";
}

function reportedSoftwareMetadata(node: SiteNode, component: string): boolean {
  const state: any = node.softwareVersions;
  if (component === "chain") return Boolean(
    node.observedInferenceVersion ||
    (!node.inferenceObservationRejected && GDC_SOFTWARE_VERSIONS.freshPayloadVersion(state, "chain")),
  );
  if (component === "DAPI") return Boolean(GDC_SOFTWARE_VERSIONS.freshPayloadVersion(state, "DAPI"));
  return false;
}

function softwareInventoryKeys(node: SiteNode): Array<string> {
  const keys: Set<string> = new Set();
  for (const value of [node.name, node.publicHost]) {
    const match = String(value || "").toLowerCase().match(/^(?:gdc-)?(node[0-9]+)(?:\.|$)/);
    if (!match) continue;
    keys.add(match[1]);
    keys.add(`gdc-${match[1]}`);
  }
  return [...keys];
}

function softwareDisplayValue(version: string): string {
  return GDC_SOFTWARE_VERSIONS.displayVersion(String(version || ""));
}

function observedNetworkChainVersion(inventory: SoftwareInventory): string {
  const versions: Set<string> = new Set();
  for (const samples of inventory.values()) {
    const reported = String(
      GDC_SOFTWARE_VERSIONS.selectLatestInventory(samples, Date.now() / 1000, 300).get("chain")?.version || "",
    );
    const version = softwareDisplayValue(reported);
    if (version && version !== "unreported") versions.add(version);
  }
  return versions.size === 1 ? String([...versions][0]) : "";
}

function updateSoftware(
  inventory: SoftwareInventory,
  node: SiteNode,
  card: HTMLElement,
): void {
  const key = softwareInventoryKeys(node).find((candidate) =>
    inventory.has(candidate || ""),
  );
  const samples = inventory.get(key || "") || [];
  for (const [component, field] of [["chain", "inferenced"], ["DAPI", "dapi"]]) {
    const reported = reportedSoftwareVersion(node, component);
    const rawVersion = reported || (component === "chain" && node.inferenceObservationRejected
      ? ""
      : GDC_SOFTWARE_VERSIONS.freshInventoryVersion("", samples, component));
    const version = rawVersion && rawVersion !== "unreported"
      ? softwareDisplayValue(rawVersion)
      : "";
    const target = card.querySelector(`[data-k="${field}"]`);
    target.textContent = version && version !== "unreported"
      ? version
      : reportedSoftwareMetadata(node, component)
        ? "Version unavailable"
        : "Unavailable";
    if (/^(?:sha256:)?[a-f0-9]{64}$/i.test(String(rawVersion))) {
      target.title = `${component}: container image digest ${rawVersion}`;
    } else if (version && version !== "unreported") {
      target.title = "Runtime version when available, otherwise the most recent software inventory observed within five minutes";
    } else if (reportedSoftwareMetadata(node, component)) {
      target.title = `${component} responds, but its version endpoint does not report a version and no current inventory version is available`;
    } else {
      target.title = "No current version was available from the Host or monitoring inventory";
    }
  }
}

function updateDevShards(node: SiteNode, card: HTMLElement): void {
  const inference = GDC_NETWORK_OBSERVATION.inferenceState(node.devShardHealth);
  set(card, "inference", inference.label);
  card.querySelector('[data-k="inference"]').title = inference.detail;
  const state: ?DevShardHealth = node.devShardHealth;
  const target = card.querySelector('[data-k="devshard"]');
  const key = softwareInventoryKeys(node).find((host) => cardDevShardInventory.has(host));
  const identities = GDC_SOFTWARE_VERSIONS.selectDevShardIdentity(cardDevShardInventory.get(key || "") || [], key || "", Date.now() / 1000);
  if (identities.size) {
    const values = [...identities.values()].sort((left, right) => left.slot.localeCompare(right.slot));
    const unknown = [...new Set((state?.runtimes || []).filter((item) => item.status === "running" && ["v3", "v4", "v5"].includes(item.name) && !identities.has(item.name)).map((item) => item.name))].sort();
    target.textContent = [...values.map((item) => `${item.slot} ${item.version === "unreported" ? "version unknown" : item.version}`), ...unknown.map((slot) => `${slot} identity unknown`)].join(" · ");
    target.title = [...values.map((item) => `${item.slot}; observed binary SHA-256 ${item.binarySha256}; archive SHA-256 ${item.archiveSha256 || "unreported"}; observed ${item.observedAt}; expires ${item.observedAt + 90}`), ...unknown.map((slot) => `${slot}; health reports running, observed binary identity unverified`)].join("\n");
    return;
  }
  if (!state || state.state === "checking") {
    target.textContent = "Checking…";
    target.title = "Checking the Host DevShard health endpoint";
    return;
  }
  if (state.state === "not_exposed") {
    target.textContent = "Not exposed";
    target.title = "This Host does not expose the DevShard health endpoint";
    return;
  }
  if (state.state !== "observed") {
    target.textContent = "Unavailable";
    target.title = "The Host DevShard health endpoint could not be read";
    return;
  }
  const runtimes = state.runtimes.filter((runtime) =>
    String(runtime?.status || "").toLowerCase() === "running" &&
    String(runtime?.name || "").trim(),
  ).sort((left, right) =>
    String(left.name).localeCompare(String(right.name), undefined, { numeric: true }),
  );
  if (!runtimes.length) {
    target.textContent = "Not running";
    target.title = "The Host exposes DevShard health but has no running runtime";
    return;
  }
  target.textContent = runtimes.map((runtime) => String(runtime.name)).join(" · ");
  target.title = runtimes.map((runtime) => {
    const port = String(runtime?.port || "").trim();
    return [String(runtime.name), "Observed binary identity unverified", port ? `port ${port}` : ""]
      .filter(Boolean)
      .join(" · ");
  }).join("\n");
}

async function refreshDevShardInventory(): Promise<void> {
  const request = ++devShardInventoryRequest;
  const next: SoftwareInventory = new Map();
  try {
    const response = await json(statusUrl("/devshard-runtime"));
    if (response?.status !== "success" || response?.data?.resultType !== "vector" || !Array.isArray(response?.data?.result)) throw new Error("Unverified runtime inventory");
    for (const sample of response.data.result) {
      const host = String(sample?.metric?.host || "");
      if (host) next.set(host, [...(next.get(host) || []), sample]);
    }
  } catch {}
  if (request !== devShardInventoryRequest) return;
  for (const [host, samples] of next) {
    const identities = GDC_SOFTWARE_VERSIONS.selectDevShardIdentity(samples, host, Date.now() / 1000);
    const accepted = [];
    for (const sample of samples) {
      const identity = identities.get(sample?.metric?.slot);
      if (!identity) continue;
      const key = `${host}:${identity.slot}`;
      const fingerprint = JSON.stringify(identity);
      const previous = devShardInventoryWatermarks.get(key);
      if (previous && (identity.observedAt < previous.observedAt ||
          (identity.observedAt === previous.observedAt && fingerprint !== previous.fingerprint))) continue;
      devShardInventoryWatermarks.set(key, { observedAt: identity.observedAt, fingerprint });
      accepted.push(sample);
    }
    next.set(host, accepted);
  }
  cardDevShardInventory = next;
  renderDevShardInventory();
}

function renderDevShardInventory(): void {
  for (const node of observedNodes) {
    const card = cards.get(nodeKey(node));
    if (card) updateDevShards(node, card);
  }
}

function updateMlNodes(
  inventory: SoftwareInventory,
  hardwareInventory: HardwareInventory,
  node: SiteNode,
  card: HTMLElement,
): void {
  const row = card.querySelector('[data-k-row="mlnode"]');
  const target = card.querySelector('[data-k="mlnode"]');
  const hardware = node.address ? hardwareInventory.get(node.address) : null;
  const observation = GDC_SOFTWARE_VERSIONS.selectMlNodes(node.softwareVersions, hardware);
  const runtimes = observation.nodes;
  row.hidden = false;
  target.replaceChildren();
  if (!runtimes.length) {
    const item = document.createElement("li");
    item.textContent = GDC_SOFTWARE_VERSIONS.emptyMlNodeLabel(observation);
    target.append(item);
    target.title = observation.source;
    return;
  }
  for (const runtime of runtimes) {
    const item = document.createElement("li");
    const endpoint = runtimeLocation(runtime);
    const reported = String(runtime?.version || "").trim();
    const version = reported && reported !== "unreported"
      ? GDC_SOFTWARE_VERSIONS.displayVersion(reported)
      : "Version unavailable";
    const reportedRuntime = (hardware?.nodes || []).find((candidate) =>
      String(candidate?.local_id || "") === String(runtime?.node_id || "") ||
      (String(candidate?.host || "") === String(runtime?.host || "") &&
        String(candidate?.port || "") === String(runtime?.port || "")),
    ) || runtime;
    item.textContent = `${endpoint} · ${version} · ${formatGpuRecords(runtimeGpuRecords(node, reportedRuntime, cardGpuInventory))}`;
    target.append(item);
  }
  target.title = observation.source;
}

async function refreshSoftwareInventory(): Promise<void> {
  const state = await json(statusUrl("/software"));
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
    if (card) {
      updateSoftware(cardSoftwareInventory, node, card);
      updateMlNodes(cardSoftwareInventory, cardHardwareInventory, node, card);
      updateDevShards(node, card);
    }
  }
}

async function refreshGpuInventory(): Promise<void> {
  const state = await json(statusUrl("/gpus"));
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
      const gpus = next.get(key) || [];
      const memory = Number(sample?.value?.[1]);
      gpus.push({ name, memoryBytes: Number.isFinite(memory) && memory > 0 ? memory : null });
      next.set(key, gpus);
    }
  }
  cardGpuInventory = next;
  for (const node of observedNodes) {
    const card = cards.get(nodeKey(node));
    if (card) updateMlNodes(cardSoftwareInventory, cardHardwareInventory, node, card);
  }
  validatorMapController?.update(observedNodes);
}

async function refreshHardwareInventory(): Promise<void> {
  if (!chainApiOrigin) {
    for (const node of observedNodes) renderActivity(node);
    return;
  }
  const next: HardwareInventory = new Map();
  const referenceNode = chainApiReferenceNode();
  let participants: Array<any>;
  try {
    if (!referenceNode?.address || !referenceNode.rpcIdentityVerified ||
      referenceNode.rpcChainId !== cfg.chainId)
      throw new Error("selected chain API peer identity is unavailable");
    participants = await GDC_NETWORK_OBSERVATION.loadParticipants(
      chainApiOrigin,
      { nodeId: referenceNode.address, chainId: referenceNode.rpcChainId, identityVerified: true },
      cfg.chainId,
      json,
    );
  } catch {
    for (const node of observedNodes) {
      node.participantAddress = null;
      renderActivity(node);
    }
    for (const node of observedNodes)
      if (node.address) next.set(node.address, { state: "unavailable", nodes: [] });
    cardHardwareInventory = next;
    for (const node of observedNodes) {
      const card = cards.get(nodeKey(node));
      if (!card) continue;
      updateMlNodes(cardSoftwareInventory, cardHardwareInventory, node, card);
      updateDevShards(node, card);
    }
    validatorMapController?.update(observedNodes);
    return;
  }
  const mapped = observedNodes.map((node) => ({
    node,
    participant: GDC_NETWORK_OBSERVATION.participantAddressForNode(participants, node),
  }));
  for (const {node, participant} of mapped) {
    node.participantAddress = participant;
    renderActivity(node);
  }
  refreshActivity();
  await Promise.all(mapped.map(async ({node, participant}) => {
    const address = node.address;
    if (!address) return;
    if (!participant) {
      next.set(address, { state: "unavailable", nodes: [] });
      return;
    }
    try {
      const state = await json(
        `${chainApiOrigin}/chain-api/productscience/inference/inference/hardware_nodes/${encodeURIComponent(participant)}`,
      );
      if (state?.nodes?.participant !== participant || !Array.isArray(state?.nodes?.hardware_nodes))
        throw new Error("hardware response identity or schema mismatch");
      next.set(address, { state: "observed", nodes: state.nodes.hardware_nodes });
    } catch {
      next.set(address, { state: "unavailable", nodes: [] });
    }
  }));
  cardHardwareInventory = next;
  for (const node of observedNodes) {
    const card = cards.get(nodeKey(node));
    if (!card) continue;
    updateMlNodes(cardSoftwareInventory, cardHardwareInventory, node, card);
    updateDevShards(node, card);
  }
  validatorMapController?.update(observedNodes);
}

let activityInFlight: ?Promise<void> = null;
function renderActivity(node: SiteNode): void {
  const card = cards.get(nodeKey(node));
  if (!card) return;
  const account = String(node.participantAddress || "").trim();
  const accountRow = card.querySelector('[data-k-row="account"]');
  accountRow.hidden = !account;
  if (account) {
    set(card, "account", account);
    const target = card.querySelector('[data-copy-value="account"]');
    target.title = "Copy account address";
    target.setAttribute("aria-label", `Copy account address ${account}`);
  }
  const state = GDC_NETWORK_OBSERVATION.activityState(node.activity, node.participantAddress);
  set(card, "poc", state.poc.label);
  card.querySelector('[data-k="poc"]').title = state.poc.detail;
  const cpocRow = card.querySelector('[data-k-row="cpoc"]');
  cpocRow.hidden = state.cpoc.active !== true;
  if (state.cpoc.active === true) {
    set(card, "cpoc", state.cpoc.label);
    card.querySelector('[data-k="cpoc"]').title = state.cpoc.detail;
  }
}

function renderNodeIdentity(card: HTMLElement, node: SiteNode): void {
  const nodeId = String(node.address || "").trim();
  const row = card.querySelector('[data-k-row="node-id"]');
  const valid = /^[0-9a-f]{40}$/i.test(nodeId);
  row.hidden = !valid;
  if (!valid) return;
  set(card, "node-id", nodeId);
  const target = row.querySelector('[data-copy-value="node-id"]');
  target.title = "Copy node ID";
  target.setAttribute("aria-label", `Copy node ID ${nodeId}`);
}

function refreshActivity(): void {
  if (activityInFlight || !chainApiOrigin) return;
  activityInFlight = GDC_NETWORK_OBSERVATION.loadActivity(chainApiOrigin, json)
    .then((evidence) => {
      for (const node of observedNodes) { node.activity = evidence; renderActivity(node); }
    }).catch(() => {
      for (const node of observedNodes) { node.activity = null; renderActivity(node); }
    }).finally(() => { activityInFlight = null; });
}

async function refreshCurrentValidatorSet(reference: any): Promise<any> {
  return GDC_NETWORK_OBSERVATION.loadCurrentValidatorSet(reference, cfg.chainId, json);
}

async function refreshDevShardVersions(): Promise<void> {
  if (!chainApiOrigin) throw new Error("chain RPC origin is missing");
  const referenceNode = chainApiReferenceNode();
  if (!referenceNode?.address || !referenceNode.rpcIdentityVerified ||
    referenceNode.rpcChainId !== cfg.chainId)
    throw new Error("selected chain API peer identity is unavailable");
  await GDC_NETWORK_OBSERVATION.verifyChainApiReference(
    chainApiOrigin,
    { nodeId: referenceNode.address, chainId: referenceNode.rpcChainId, identityVerified: true },
    cfg.chainId,
    json,
  );
  const state = await json(
    `${chainApiOrigin}/chain-api/productscience/inference/inference/devshard_approved_versions`,
  );
  const approved = state?.versions;
  if (!Array.isArray(approved)) throw new Error("approved DevShard versions are missing or malformed");
  const seen: Set<string> = new Set();
  const versions: Array<DevShardVersion> = [];
  for (const version of approved) {
    const name = String(version?.name || "").trim();
    const binary = String(version?.binary || "").trim();
    const sha256 = String(version?.sha256 || "").trim().toLowerCase();
    if (!/^v[0-9][A-Za-z0-9._-]*$/.test(name) || !binary ||
      !/^[0-9a-f]{64}$/.test(sha256) || seen.has(name))
      throw new Error("approved DevShard versions contain an invalid or duplicate entry");
    seen.add(name);
    versions.push({ name, sha256 });
  }
  versions.sort((left, right) => left.name.localeCompare(right.name, undefined, { numeric: true }));
  updateDevShardVersions(versions);
}
for (const node of observedNodes) createCard(node);
layoutHostCards();
window.addEventListener("resize", () => {
  if (hostDeckResizeFrame != null)
    window.cancelAnimationFrame(hostDeckResizeFrame);
  hostDeckResizeFrame = window.requestAnimationFrame(() => {
    hostDeckResizeFrame = null;
    layoutHostCards();
  });
});
async function response(
  url: string,
  options: RequestOptions = {},
  format: string = "json",
): Promise<any> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 8000);
  try {
    const r = await fetch(url, {
      ...options,
      cache: "no-store",
      signal: controller.signal,
    });
    if (!r.ok) throw new Error(`${r.status}`);
    return await (format === "text" ? r.text() : r.json());
  } finally {
    clearTimeout(timer);
  }
}
async function json(url: string, options: ?RequestOptions): Promise<any> {
  return response(url, options || {});
}

async function text(url: string): Promise<string> {
  return response(url, {}, "text");
}

async function readSoftwareVersions(statusBase: string): Promise<any> {
  const url = `${statusBase}/v1/versions`;
  try {
    return await json(url);
  } catch (error) {
    // This is a read-only observation. One retry avoids presenting a
    // short-lived proxy restart as a missing DAPI version, without masking a
    // persistent endpoint failure.
    if (!/\b(?:503|504)\b/.test(String(error))) throw error;
    return json(url);
  }
}

function set(card: HTMLElement, key: string, value: mixed): void {
  card.querySelector(`[data-k="${key}"]`).textContent = value;
  if (key === "host" || key === "status") updateCardToggleLabel(card);
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

const footerGithub = $("footer-github");
if (footerGithub && previewNumber) {
  const pullRequestUrl = `https://github.com/paranjko/external-test-lab/pull/${previewNumber}`;
  footerGithub.href = pullRequestUrl;
  footerGithub.title = `Open pull request #${previewNumber} on GitHub`;
  footerGithub.setAttribute(
    "aria-label",
    `External Test Lab pull request #${previewNumber}`,
  );
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
      return "Active";
    default:
      return "Wait";
  }
}

const MARKER_STATE_ORDER: Array<MarkerState> = [
  "validating",
  "active",
  "waiting",
  "unavailable",
];

const MARKER_STATE_COLORS: { [MarkerState]: string } = {
  validating: "var(--state-validating)",
  active: "var(--state-active)",
  waiting: "var(--state-waiting)",
  unavailable: "var(--state-waiting)",
};

function markerStateForDisplay(state: string): MarkerState {
  if (state === "validating") return "validating";
  if (state === "active") return "active";
  return "waiting";
}

function markerStateCounts(validators: Array<Validator>): MarkerStateCounts {
  const counts: MarkerStateCounts = {
    validating: 0,
    active: 0,
    waiting: 0,
    unavailable: 0,
  };
  for (const validator of validators) counts[validator.markerState] += 1;
  return counts;
}

function markerStateSummary(counts: MarkerStateCounts): string {
  return MARKER_STATE_ORDER
    .filter((state) => counts[state] > 0)
    .map((state) => `${counts[state]} ${markerStateLabel(state)}`)
    .join(" · ");
}

function markerGroupState(counts: MarkerStateCounts): {
  state: MarkerState,
  label: string,
  mixed: boolean,
} {
  const states = MARKER_STATE_ORDER.filter((state) => counts[state] > 0);
  return {
    state: states[0] || "waiting",
    label: states.length > 1 ? "Mixed" : markerStateLabel(states[0] || "waiting"),
    mixed: states.length > 1,
  };
}

function markerRadius(gpus: number): number {
  // Radius grows with sqrt(GPU count), therefore visual area represents
  // capacity rather than the number of Hosts at one location. A Host with
  // unavailable inventory remains visible at the one-GPU minimum.
  if (gpus <= 1) return 6;
  return Math.min(7.5 * Math.sqrt(gpus), 18);
}

function maidenheadLocator(latitude: number, longitude: number, precision: number = 4): string {
  const lon = Math.max(0, Math.min(360 - Number.EPSILON, longitude + 180));
  const lat = Math.max(0, Math.min(180 - Number.EPSILON, latitude + 90));
  const fieldLon = Math.floor(lon / 20);
  const fieldLat = Math.floor(lat / 10);
  const squareLon = Math.floor((lon % 20) / 2);
  const squareLat = Math.floor(lat % 10);
  const locator = `${String.fromCharCode(65 + fieldLon)}${String.fromCharCode(65 + fieldLat)}${squareLon}${squareLat}`;
  if (precision < 6) return locator;
  const subLon = Math.floor(((lon % 2) / 2) * 24);
  const subLat = Math.floor((lat % 1) * 24);
  return `${locator}${String.fromCharCode(97 + subLon)}${String.fromCharCode(97 + subLat)}`;
}

function markerFill(counts: MarkerStateCounts, count: number): string {
  let start = 0;
  const slices = MARKER_STATE_ORDER.filter((state) => counts[state] > 0).map(
    (state) => {
      const end = start + (counts[state] / count) * 360;
      const slice = `${MARKER_STATE_COLORS[state]} ${start.toFixed(3)}deg ${end.toFixed(3)}deg`;
      start = end;
      return slice;
    },
  );
  return `conic-gradient(${slices.join(", ")})`;
}

function markerIcon(gpus: number, counts: MarkerStateCounts, nodes: number): any {
  const radius = markerRadius(gpus);
  const diameter = radius * 2;
  return L.divIcon({
    className: "validator-marker",
    html: `<span class="validator-marker-face" style="--validator-marker-fill: ${markerFill(counts, nodes)}"></span>`,
    iconSize: [diameter, diameter],
    iconAnchor: [radius, radius],
  });
}

function renderHostState(card: HTMLElement, node: SiteNode): boolean {
  const display = displayHostState(node);
  set(card, "status", display.primaryLabel);
  const status = card.querySelector('[data-k="status"]');
  status.className = display.primaryClass;
  status.title = display.reason;
  updateCardToggleLabel(card);
  set(card, "vp", display.votingPower);
  set(card, "sync", display.syncLabel);
  set(card, "endpoint", display.endpointLabel);
  renderNodeIdentity(card, node);
  // Update both views in the same turn, including pending and failed reads.
  // Previously cards changed throughout refresh while the map kept old data.
  validatorMapController?.update(observedNodes);
  return display.validatorEffective;
}

function displayHostState(node: SiteNode): any {
  if (node.networkObserved === true) {
    return hostState.classify({
      networkObserved: true,
      networkActive: node.networkActive === true,
      endpointState: node.endpointState,
      endpointDiagnostic: node.endpointDiagnostic,
      chainDiagnostic: node.chainDiagnostic,
      validatorKnown: node.validatorKnown,
      observationComplete: node.observationComplete,
      votingPower: node.votingPower,
      catchingUp: node.catchingUp,
      blocksBehind: node.blocksBehind,
      blockAgeSeconds: node.blockAgeSeconds,
      progressing: node.progressing,
      referenceKnown: node.referenceKnown,
      referenceAgrees: node.referenceAgrees,
    });
  }
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
const DYNAMIC_STATUS_HOST = /^node[0-9]+\.gonka-dev\.net$/i;
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

function networkNode(observation: any): SiteNode {
  const network = GDC_NETWORK_OBSERVATION.nodeState(observation);
  if (!network) throw new Error("invalid network observation node");
  const inferenceComponent = observation?.components?.inferenced;
  const chainRpcComponent = observation?.components?.chain_rpc;
  const peersComponent = observation?.components?.peers;
  const peerCount = Number(peersComponent?.count);
  const observedInferenceVersion = GDC_SOFTWARE_VERSIONS.freshNetworkInferenceVersion(
    inferenceComponent, chainRpcComponent, network.nodeId, cfg.chainId,
  );
  const inferenceObservationRejected =
    (inferenceComponent?.state === "observed" && !observedInferenceVersion) ||
    (chainRpcComponent?.state === "observed" &&
      (String(chainRpcComponent?.p2p_node_id || "").toLowerCase() !== network.nodeId ||
        String(chainRpcComponent?.chain_id || "") !== cfg.chainId));
  const dapiUrl = network.dapiUrl;
  let endpoint;
  try {
    endpoint = new URL(dapiUrl);
  } catch {
    endpoint = null;
  }
  const host = endpoint?.hostname || "";
  const bootstrapHost = String(observation?.public_host || "").toLowerCase();
  const catalogEntries = cfg.nodeCatalog || cfg.nodes;
  const byHost = catalogEntries.filter((node) =>
    node.publicHost === (bootstrapHost || host),
  );
  const byName = catalogEntries.filter((node) => node.name === network.nodeName);
  const catalog =
    byHost.length === 1 ? byHost[0] : byName.length === 1 ? byName[0] : null;
  // A public participant location is always a GeoIP observation of its
  // advertised endpoint.  The catalog is only a fallback for an unavailable
  // DNS or GeoIP lookup, so catalog and dynamically joined Hosts share one
  // grouping rule on the map.
  const previous = observedNodes.find((node) => node.address === network.nodeId && node.dapiUrl === dapiUrl);
  // Public status only proxies the fixed catalog routes and the Community
  // DevNet nodeN hostnames. A participant may advertise another hostname,
  // but it must not turn this origin into an open proxy merely to monitor it.
  // A preview retains the catalog route alias through its own status overlay.
  // The alias may differ from the network node name (gdc-node0 versus node0).
  const catalogStatusAlias = String(catalog?.statusBase || "")
    .match(/(?:^|\/)status\/([^/?#]+)\/?$/)?.[1] || catalog?.name;
  const networkStatusBase = cfg.publicBootstrap === true
    ? ""
    : previewPrefix && catalogStatusAlias && DYNAMIC_STATUS_HOST.test(host)
      ? `${statusBase}/${catalogStatusAlias}`
      : catalog?.statusBase ||
        (DYNAMIC_STATUS_HOST.test(host) ? `${statusBase}/${host}` : "");
  // Validator queries stay on the status origin. A browser must not depend
  // on a cross-origin RPC CORS policy to determine current membership.
  const validatorRpcBase = networkStatusBase;
  return {
    ...previous,
    name: network.nodeName || catalog?.name || host || network.nodeId,
    address: network.nodeId,
    publicHost: bootstrapHost || host || catalog?.publicHost,
    dapiUrl: network.dapiUrl,
    statusBase: networkStatusBase,
    validatorRpcBase,
    ip: observation?.geo?.resolvedIp || previous?.ip || catalog?.ip || "",
    geo: observation?.geo || previous?.geo || catalog?.geo || null,
    mode: catalog?.mode,
    reason: catalog?.reason,
    networkObserved: true,
    networkActive: network.active,
    endpointState: previous?.endpointState || network.endpointState,
    endpointDiagnostic: previous?.endpointDiagnostic || network.endpointDiagnostic,
    peerCount: peersComponent?.state === "observed" && Number.isSafeInteger(peerCount) && peerCount >= 0
      ? peerCount : null,
    peerState: String(peersComponent?.state || ""),
    catchingUp: network.catchingUp,
    softwareVersions:
      observation?.components?.versions?.state === "observed"
        ? observation.components.versions
        : null,
    observedSoftwareVersions:
      observation?.components?.versions?.state === "observed"
        ? observation.components.versions
        : null,
    observedModelRegistry:
      observation?.components?.models?.state === "observed"
        ? observation.components.models
        : null,
    observedInferenceVersion,
    inferenceObservationRejected,
    devShardHealth: observation?.components?.devshard || null,
    isOnline: network.active,
    serverStatus: network.active ? "active" : "inactive",
    gpuHost: catalog?.gpuHost,
  };
}

function updateNodeModels(node: SiteNode, card: HTMLElement): void {
  const target = card.querySelector('[data-k="models"]');
  const assignment = publicChainState?.model_assignments;
  const available = observerSnapshotMode && ["observed", "partial"].includes(assignment?.state) && Array.isArray(assignment?.groups);
  const models = available && node.participantAddress
    ? assignment.groups.filter((group) => group.state === "observed" &&
      Array.isArray(group.participants) && group.participants.some((member) => member.address === node.participantAddress))
      .map((group) => String(group.model_id))
    : [];
  target.replaceChildren();
  for (const model of models.length ? models : [available && node.participantAddress && assignment.state === "observed" ? "No allocated models" : "Not reported"]) {
    const item = document.createElement("li");
    item.textContent = model;
    target.append(item);
  }
  target.title = available ? `Effective epoch ${String(assignment.epoch_index)} · network allocation, not a serving-health check` : "Model assignments unavailable";
}

function updatePublicModelRegistry(nodes: Array<SiteNode>): void {
  $("model-label").textContent = "Allocated models";
  const assignment = publicChainState?.model_assignments;
  for (const node of nodes) {
    const card = cards.get(nodeKey(node));
    if (card) updateNodeModels(node, card);
  }
  if (!observerSnapshotMode || !["observed", "partial"].includes(assignment?.state) || !Array.isArray(assignment?.groups)) {
    renderModelList([], "Effective network model assignments unavailable");
    return;
  }
  const context = `Effective epoch ${String(assignment.epoch_index)} · ${assignment.state === "partial" ? "partial data" : "observed"}`;
  const allocated: Array<string> = [];
  for (const group of assignment.groups) {
    const members = group.state === "observed" && Array.isArray(group.participants) ? group.participants : null;
    const model = String(group.model_id || "Unknown model");
    if (members && members.length) {
      allocated.push(model);
    }
  }
  renderModelList(allocated, context, assignment.state === "partial" ? "Not reported" : "No allocated models");
}

function normalizedPublicOrigin(value: mixed): string {
  try {
    const parsed = new URL(String(value || ""));
    return ["http:", "https:"].includes(parsed.protocol) &&
      !parsed.username && !parsed.password ? parsed.origin : "";
  } catch { return ""; }
}

function applyPublicChainState(chain: any): void {
  if (!observerSnapshotMode && !publicChainState) return;
  const age = Date.now() - Date.parse(String(chain?.observed_at || ""));
  publicChainState = observerSnapshotMode && chain?.state === "observed" && Number.isFinite(age) && age >= 0 && age <= 90000 ? chain : null;
  if (!publicChainState) {
    updatePublicModelRegistry(observedNodes);
    retainedValidatorSet = null;
    validatorSetObservedAt = 0;
    markDevShardVersionsUnavailable();
    renderEpochOverview(null, null, null);
    renderFinalizedEpochResults(null);
    renderDevShardExecution(null, observedNodes);
    return;
  }
  const validators = Array.isArray(chain.validators) ? chain.validators : [];
  const validValidators = validators.length > 0 && validators.every((entry) =>
    /^[0-9a-f]{40}$/i.test(String(entry?.address || "")) &&
    /^\d+$/.test(String(entry?.voting_power || "")),
  );
  retainedValidatorSet = validValidators
    ? {state: "observed", verified: true, complete: true, blockHeight: String(chain?.reference?.height || ""), validators}
    : null;
  validatorSetObservedAt = retainedValidatorSet ? Date.now() : 0;
  const participants = Array.isArray(chain.participants) ? chain.participants : [];
  const byOrigin: Map<string, any> = new Map();
  for (const participant of participants) {
    const origin = normalizedPublicOrigin(participant?.inference_url);
    // A public URL can belong to multiple historical accounts. Never label
    // their allocations with an arbitrary first matching Host identity.
    if (origin) byOrigin.set(origin, byOrigin.has(origin) ? null : participant);
  }
  const hardware: Map<string, Array<any>> = new Map();
  for (const record of Array.isArray(chain.hardware_nodes) ? chain.hardware_nodes : []) {
    const address = String(record?.address || "").trim();
    if (/^gonka1[0-9a-z]+$/i.test(address) && Array.isArray(record?.nodes))
      hardware.set(address, record.nodes);
  }
  const observedAt = Date.parse(String(chain.observed_at || ""));
  const epoch = chain?.activity?.epoch;
  const cpoc = chain?.activity?.cpoc;
  renderEpochOverview(epoch, chain?.reference, cpoc);
  renderFinalizedEpochResults(chain?.activity?.finalized_epoch);
  const stage = String(epoch?.latest_epoch?.poc_start_block_height || "");
  const activity = Number.isFinite(observedAt) && /^[1-9]\d*$/.test(stage)
    ? {
      observedAt,
      epoch: String(epoch?.latest_epoch?.index || ""),
      poc: {
        height: stage,
        commits: Array.isArray(chain?.activity?.commits?.commits) ? chain.activity.commits.commits : null,
        votes: Array.isArray(chain?.activity?.votes?.poc_validation) ? chain.activity.votes.poc_validation : null,
      },
      cpoc: cpoc?.state === "observed" && cpoc.active === true && cpoc.event
        ? {
          height: String(cpoc.event.trigger_height || ""),
          commits: Array.isArray(cpoc.commits?.commits) ? cpoc.commits.commits : null,
          votes: Array.isArray(cpoc.votes?.poc_validation) ? cpoc.votes.poc_validation : null,
        }
        : null,
      confirmationActive: cpoc?.state === "observed" ? cpoc.active : null,
      confirmationPhase: String(cpoc?.event?.phase || "").replace(/^CONFIRMATION_POC_/, ""),
    }
    : null;
  cardHardwareInventory = new Map();
  for (const node of observedNodes) {
    const validatorAddress = String(node.validatorAddress || "").toUpperCase();
    const validator = validators.find((entry) => String(entry.address).toUpperCase() === validatorAddress);
    const keyMatches = validator?.validator_key
      ? participants.filter((entry) => entry.validator_key === validator.validator_key)
      : [];
    const participant = keyMatches.length === 1 ? keyMatches[0] : byOrigin.get(normalizedPublicOrigin(node.dapiUrl));
    node.participantAddress = String(participant?.address || "") || null;
    node.participantStatus = String(participant?.status || "") || undefined;
    node.participantKnown = Boolean(participant);
    node.activity = activity;
    const nodeAddress = String(node.address || "");
    if (nodeAddress) {
      const nodes = hardware.get(String(node.participantAddress || ""));
      cardHardwareInventory.set(nodeAddress, {
        state: Array.isArray(nodes) ? "observed" : "unavailable",
        nodes: Array.isArray(nodes) ? nodes : [],
      });
    }
    applyRetainedMembership(node);
  }
  const approvals = Array.isArray(chain.approved_devshards) ? chain.approved_devshards : [];
  updateDevShardVersions(approvals);
  updatePublicModelRegistry(observedNodes);
  renderDevShardExecution(approvals, observedNodes);
}

async function reconcileNetwork(): Promise<{status: "observed" | "pending", height: number}> {
  const snapshotAge = Date.now() - Date.parse(String(networkSnapshot?.observed_at || ""));
  let state: any;
  try {
    state = networkSnapshot && snapshotAge >= 0 && snapshotAge <= 90000
      ? networkSnapshot : await json(statusUrl("/network"));
  } catch (error) {
    if (String(error?.name || "") === "SyntaxError")
      throw new Error("network observation is malformed");
    throw error;
  }
  if (state?.state === "observation_pending" && state?.chain_id === cfg.chainId)
    return {status: "pending", height: 0};
  const nodes = Array.isArray(state?.nodes) ? state.nodes : [];
  if (state?.schema_version !== 1 || !Array.isArray(state?.nodes) || state?.chain_id !== cfg.chainId)
    throw new Error("network observation is malformed");
  if (!nodes.length) {
    const chain = state?.chain;
    const observedAt = Date.parse(String(chain?.observed_at || ""));
    const age = Date.now() - observedAt;
    const reference = chain?.reference || {};
    if (chain?.state !== "observed" || !Number.isFinite(age) || age < 0 || age > 90000 ||
      !/^[0-9a-f]{40}$/i.test(String(reference.node_id || "")) ||
      !Number.isSafeInteger(Number(reference.height)) || Number(reference.height) <= 0)
      throw new Error("network observation is malformed");
  }
  observerSnapshotMode = cfg.publicBootstrap === true || state.chain !== undefined;
  const source = $("network-source");
  if (source) source.textContent = observerSnapshotMode ? "LIVE NETWORK" : "NETWORK OBSERVER UPDATE REQUIRED";
  if (!observerSnapshotMode) {
    renderEpochOverview(null, null, null);
    renderFinalizedEpochResults(null);
  }
  connectNetworkObservation();
  const next = nodes.map((observation) => {
    const candidate = networkNode(observation);
    const previous = observedNodes.find((node) => node.address === candidate.address && node.dapiUrl === candidate.dapiUrl);
    // Detail requests retain this object while discovery refreshes its fields.
    if (previous) for (const key of Object.keys(candidate)) (previous: any)[key] = (candidate: any)[key];
    const node = previous || candidate;
    const rpc = observation?.components?.chain_rpc;
    const observedAt = Date.parse(String(rpc?.observed_at || ""));
    if (rpc?.state === "observed" && Date.now() - observedAt <= 90000 && observedAt <= Date.now() &&
      rpc?.p2p_node_id === node.address && rpc?.chain_id === cfg.chainId &&
      (!node.rpcObservedAt || observedAt > node.rpcObservedAt)) {
      recordRpc(node, {result: {
        node_info: {id: rpc.p2p_node_id, network: rpc.chain_id},
        sync_info: rpc,
        validator_info: {address: rpc.validator_address || node.validatorAddress},
      }}, observedAt);
      if (observerSnapshotMode && /^\d+$/.test(String(rpc?.validator_voting_power || ""))) {
        node.validatorKnown = true;
        node.votingPower = String(rpc.validator_voting_power);
      }
    } else if (!previous && rpc?.state !== "unavailable") {
      node.endpointState = "unknown";
    }
    return node;
  }).sort((left, right) => left.name.localeCompare(right.name));
  const liveKeys = new Set(next.map(nodeKey));
  for (const [key, card] of cards) {
    if (!liveKeys.has(key)) {
      card.remove();
      cards.delete(key);
    }
  }
  observedNodes = next;
  applyPublicChainState(state.chain);
  updatePublicModelRegistry(next);
  for (const node of next) {
    let card = cards.get(nodeKey(node));
    if (!card) card = createCard(node);
    set(card, "host", node.publicHost || node.name);
    renderHostState(card, node);
    renderActivity(node);
    updateMlNodes(cardSoftwareInventory, cardHardwareInventory, node, card);
    if (node.rpcHeight) set(card, "height", node.rpcHeight.toLocaleString());
    if (Number.isSafeInteger(node.peerCount) && Number(node.peerCount) >= 0)
      set(card, "peers", String(node.peerCount));
    else if (node.peerState === "unavailable" || node.peerState === "not_exposed")
      set(card, "peers", "–");
    if (!observerSnapshotMode && !node.geo) discoverParticipant(node.publicHost || "").then((discovered) => {
      if (!observedNodes.includes(node)) return;
      node.ip = discovered.ip || node.ip;
      node.geo = discovered.geo || node.geo;
      validatorMapController?.update(observedNodes);
    }).catch(() => {});
  }
  layoutHostCards();
  return {
    status: "observed",
    height: Math.max(0, ...nodes.map((node) => Number(node?.components?.chain_rpc?.latest_block_height) || 0)),
  };
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
    // keeps the QTH marker and its keyboard/popup identity stable while
    // members enter or leave that observed location.
    group.lat = Math.round(group.lat * 10) / 10;
    group.lon = Math.round(group.lon * 10) / 10;
    group.label = maidenheadLocator(group.lat, group.lon);
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
    // A shared city label is not evidence of co-location: unrelated cloud
    // addresses often resolve to the same metro area. Group only an explicit
    // operator location ID or the exact display coordinate shown on this map.
    const location = group.key.startsWith("location:")
      ? group.key
      : `coordinate:${coordinate}`;
    const existing = coincident.get(location);
    if (!existing) {
      coincident.set(location, group);
      continue;
    }
    existing.validators.push(...group.validators);
    existing.label = [...new Set([existing.label, group.label])].join(" · ");
    existing.key = `coincident:${[existing.key, group.key].sort().join("|")}`;
  }
  for (const group of coincident.values())
    group.label = maidenheadLocator(group.lat, group.lon);
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
  let restoreWorld = (): void => {};
  const worldCoversMap = (): boolean => {
    const mapRect = container.getBoundingClientRect();
    const worldRect = container
      .querySelector(".validator-map-world")
      ?.getBoundingClientRect();
    return Boolean(
      worldRect
        ? worldRect.left <= mapRect.left + 1 &&
            worldRect.right >= mapRect.right - 1 &&
            worldRect.top <= mapRect.top + 1 &&
            worldRect.bottom >= mapRect.bottom - 1
        : worldBounds.contains(map.getBounds()),
    );
  };
  map.on("moveend", () => {
    const popupElement = container.querySelector(".leaflet-popup");
    const mapRect = container.getBoundingClientRect();
    const worldRect = container
      .querySelector(".validator-map-world")
      ?.getBoundingClientRect();
    const fullscreenWorldOutside =
      shell.classList.contains("is-fullscreen") &&
      Boolean(
        worldRect &&
          (worldRect.left < mapRect.left - 1 ||
            worldRect.right > mapRect.right + 1 ||
            worldRect.top < mapRect.top - 1 ||
            worldRect.bottom > mapRect.bottom + 1),
      );
    const coversMap = worldCoversMap();
    if (
      clampingWorld ||
      popupElement ||
      (!fullscreenWorldOutside && coversMap)
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
  let popupMode: ?("hover" | "click" | "pinned");
  let hoverTooltip: ?HTMLElement;
  let resizeFrame: ?number;
  const removeHoverTooltip = (): void => {
    hoverTooltip?.remove();
    hoverTooltip = null;
  };
  const positionHoverTooltip = (marker: any): void => {
    const tooltip = hoverTooltip;
    if (!tooltip) return;
    const anchor = marker.getElement()?.getBoundingClientRect();
    if (!anchor) return;
    const margin = 10;
    tooltip.style.maxWidth = `${Math.max(160, Math.min(460, window.innerWidth - margin * 2))}px`;
    const width = tooltip.offsetWidth;
    const height = tooltip.offsetHeight;
    const left = Math.max(
      margin,
      Math.min(window.innerWidth - width - margin, anchor.left + anchor.width / 2 - width / 2),
    );
    let top = anchor.top - height - 12;
    if (top < margin) top = anchor.bottom + 12;
    top = Math.max(margin, Math.min(window.innerHeight - height - margin, top));
    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${top}px`;
  };
  const showMarkerDetail = (key: string, marker: any, pinned: boolean = false): void => {
    const popup = marker.getPopup();
    const content = String(marker.__popupHtml || popup?.getContent?.() || "");
    if (!content) return;
    if (!hoverTooltip) {
      const tooltip = document.createElement("aside");
      tooltip.className = "validator-map-tooltip";
      tooltip.setAttribute("role", "tooltip");
      tooltip.setAttribute("aria-live", "polite");
      document.body.append(tooltip);
      hoverTooltip = tooltip;
    }
    const tooltip = hoverTooltip;
    if (!tooltip) return;
    tooltip.dataset.markerKey = key;
    tooltip.classList.toggle("is-pinned", pinned);
    tooltip.setAttribute("role", pinned ? "dialog" : "tooltip");
    tooltip.innerHTML = content;
    if (pinned) {
      const closeButton = document.createElement("button");
      closeButton.type = "button";
      closeButton.className = "validator-map-tooltip-close";
      closeButton.setAttribute("aria-label", "Close validator details");
      closeButton.textContent = "×";
      closeButton.addEventListener("click", () => {
        if (popupMode !== "click" || openMarkerKey !== key) return;
        removeHoverTooltip();
        openMarkerKey = null;
        popupMode = null;
        restoreWorld();
      });
      tooltip.prepend(closeButton);
    }
    positionHoverTooltip(marker);
  };
  const refreshMarkerDetail = (): void => {
    const key = openMarkerKey;
    if (!popupMode || !key) return;
    const marker = markerRegistry.get(key);
    if (marker && (popupMode === "hover" || popupMode === "click"))
      showMarkerDetail(key, marker, popupMode === "click");
  };
  const openMarkerPopup = (
    key: string,
    marker: any,
    mode: "hover" | "click" | "pinned" = "pinned",
  ): void => {
    if (mode === "hover") {
      if (openMarkerKey !== key || popupMode !== "hover") {
        for (const [otherKey, otherMarker] of markerRegistry) {
          if (otherKey !== key && otherMarker.isPopupOpen()) otherMarker.closePopup();
          const popup = otherMarker.getPopup();
          if (popup) map.removeLayer(popup);
        }
        map.closePopup();
        map.getPane("popupPane")?.replaceChildren();
      }
      openMarkerKey = key;
      popupMode = "hover";
      showMarkerDetail(key, marker);
      return;
    }
    if (mode === "click") {
      removeHoverTooltip();
      for (const [otherKey, otherMarker] of markerRegistry) {
        if (otherKey !== key && otherMarker.isPopupOpen()) otherMarker.closePopup();
        const popup = otherMarker.getPopup();
        if (popup) map.removeLayer(popup);
      }
      map.closePopup();
      map.getPane("popupPane")?.replaceChildren();
      openMarkerKey = key;
      popupMode = "click";
      showMarkerDetail(key, marker, true);
      return;
    }
    removeHoverTooltip();
    if (openMarkerKey === key && marker.isPopupOpen()) {
      popupMode = mode;
      const popup = marker.getPopup();
      if (popup) {
        popup.options.autoPan = mode === "pinned" && container.clientWidth >= 500;
        popup.update();
        if (mode === "pinned") schedulePopupLayout(marker, popup);
      }
      return;
    }
    for (const [otherKey, otherMarker] of markerRegistry) {
      if (otherKey !== key && otherMarker.isPopupOpen()) otherMarker.closePopup();
      const popup = otherMarker.getPopup();
      if (popup) map.removeLayer(popup);
    }
    map.eachLayer((layer: any) => {
      if (layer instanceof L.Popup) map.closePopup(layer);
    });
    map.closePopup();
    map.getPane("popupPane")?.replaceChildren();
    openMarkerKey = key;
    popupMode = mode;
    const popup = marker.getPopup();
    if (popup) {
      marker.options.autoPanPadding = popupAutoPanPadding();
      popup.options.autoPan = mode === "pinned" && container.clientWidth >= 500;
      popup.options.maxWidth = popupMaxWidth();
      popup.options.autoPanPadding = popupAutoPanPadding();
    }
    marker.openPopup();
    if (popup && mode === "pinned") schedulePopupLayout(marker, popup);
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
  const closeHoverPopup = (): void => {
    if (popupMode !== "hover") return;
    removeHoverTooltip();
    openMarkerKey = null;
    popupMode = null;
    restoreWorld();
  };
  const showNearestPopup = (event: any): void => {
    if (!isMarkerHitEvent(event)) {
      closeHoverPopup();
      return;
    }
    const nearest = nearestMarkerAt(event);
    if (!nearest) return;
    const pinnedMarker: any = openMarkerKey ? markerRegistry.get(openMarkerKey) : null;
    if (popupMode === "click") return;
    if (popupMode === "pinned" && pinnedMarker?.isPopupOpen()) return;
    // A popup may have been closed through Leaflet's close control after a
    // refresh. Do not let that stale mode suppress the next hover popup.
    if (popupMode === "pinned") popupMode = null;
    openMarkerPopup(nearest.key, nearest.marker, "hover");
  };
  const leaveNearestPopup = (event: any): void => {
    const target = event.target?.closest?.(".validator-marker-hit");
    const related = event.relatedTarget?.closest?.(".validator-marker-hit");
    if (target && !related) closeHoverPopup();
  };
  const activateNearest = (event: any): void => {
    if (!isMarkerHitEvent(event)) return;
    const nearest = nearestMarkerAt(event);
    if (!nearest) return;
    openMarkerPopup(nearest.key, nearest.marker, "click");
  };
  const configureMarkerElement = (marker: any, key: string, ariaLabel: string): void => {
    const element = marker.getElement();
    if (!element) return;
    element.setAttribute("tabindex", "0");
    element.setAttribute("role", "button");
    element.setAttribute("aria-label", ariaLabel);
    element.style.pointerEvents = "none";
    if (element.dataset.validatorMapKeyboard === "true") return;
    element.dataset.validatorMapKeyboard = "true";
    element.addEventListener("focus", () => openMarkerPopup(key, marker, "hover"));
    element.addEventListener("blur", () => {
      if (openMarkerKey !== key) return;
      popupMode = "hover";
      closeHoverPopup();
    });
    element.addEventListener("keydown", (event: any) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      openMarkerPopup(key, marker, "pinned");
    });
  };
  // The transparent hit circles overlap by design. Capture only their browser
  // events before Leaflet dispatches to an arbitrary topmost SVG path, then
  // choose the closest visible marker ourselves. Controls remain controls.
  container.addEventListener("click", activateNearest, true);
  container.addEventListener("mousemove", showNearestPopup, true);
  container.addEventListener("mouseout", leaveNearestPopup, true);
  container.addEventListener("mouseleave", closeHoverPopup, true);
  const popupMaxWidth = (): number => {
    const width = container.clientWidth || container.getBoundingClientRect().width;
    return Math.max(120, Math.min(340, width - 52));
  };
  const popupAutoPanPadding = (): Array<number> => {
    const width = container.clientWidth || container.getBoundingClientRect().width;
    if (width >= 500) return [16, 48];
    const horizontal = Math.max(
      16,
      Math.min(width / 2 - 1, popupMaxWidth() / 2 + 16),
    );
    return [horizontal, 48];
  };
  const adjustPopupToMap = (popup: any): void => {
    const mapRect = container.getBoundingClientRect();
    const popupElement = container.querySelector(".leaflet-popup") || popup._container;
    const popupRect = popupElement?.getBoundingClientRect();
    if (!popupRect) return;
    const padding = 8;
    const horizontal =
      popupRect.right > mapRect.right - padding
        ? popupRect.right - mapRect.right + padding
        : popupRect.left < mapRect.left + padding
          ? popupRect.left - mapRect.left - padding
          : 0;
    const vertical =
      popupRect.bottom > mapRect.bottom - padding
        ? popupRect.bottom - mapRect.bottom + padding
        : popupRect.top < mapRect.top + padding
          ? popupRect.top - mapRect.top - padding
          : 0;
    if (container.clientWidth < 500) {
      const left = Number.parseFloat(popupElement.style.left);
      const bottom = Number.parseFloat(popupElement.style.bottom);
      if (horizontal && Number.isFinite(left))
        popupElement.style.left = `${left - horizontal}px`;
      if (vertical && Number.isFinite(bottom))
        popupElement.style.bottom = `${bottom + vertical}px`;
      return;
    }
    if (horizontal || vertical)
      map.panBy([horizontal, vertical], { animate: false });
  };
  const settlePopupBoundary = (
    marker: any,
    popup: any,
    attempt: number = 0,
  ): void => {
    window.requestAnimationFrame(() => {
      if (!marker.isPopupOpen()) return;
      adjustPopupToMap(popup);
      if (attempt < 6) settlePopupBoundary(marker, popup, attempt + 1);
    });
  };
  const schedulePopupLayout = (marker: any, popup: any): void => {
    window.requestAnimationFrame(() => {
      if (!marker.isPopupOpen()) return;
      marker.options.autoPanPadding = popupAutoPanPadding();
      popup.options.autoPan = popupMode === "pinned" && container.clientWidth >= 500;
      popup.options.maxWidth = popupMaxWidth();
      popup.options.autoPanPadding = popupAutoPanPadding();
      popup.update();
      settlePopupBoundary(marker, popup);
    });
  };
  const popupMarkerKey = (): ?string => {
    for (const [key, marker] of markerRegistry) {
      if (marker.isPopupOpen()) return key;
    }
    return null;
  };
  const finalizePopupClose = (): void => {
    if (popupMarkerKey() || container.querySelector(".leaflet-popup")) return;
    openMarkerKey = null;
    popupMode = null;
    restoreWorld();
  };
  const refreshOpenPopupLayout = (): void => {
    const popupKey = openMarkerKey || popupMarkerKey();
    const marker: any = popupKey ? markerRegistry.get(popupKey) : null;
    const popup = marker?.getPopup();
    if (marker?.isPopupOpen() && popup && popupMode === "pinned")
      schedulePopupLayout(marker, popup);
    refreshMarkerDetail();
  };
  map.on("popupopen", (event: any) => {
    for (const [key, marker] of markerRegistry) {
      if (marker.getPopup() === event.popup) {
        openMarkerKey = key;
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
        finalizePopupClose();
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
    if (worldCoversMap()) return;
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
    window.requestAnimationFrame(() => {
      fitWorld();
      refreshOpenPopupLayout();
    });
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
    if (popupMode === "hover" || popupMode === "click") {
      removeHoverTooltip();
      openMarkerKey = null;
      popupMode = null;
      restoreWorld();
      markerRegistry.get(popupKey || "")?.getElement()?.focus();
      event.preventDefault();
      event.stopPropagation();
      return;
    }
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
      window.requestAnimationFrame(finalizePopupClose);
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
      refreshOpenPopupLayout();
    });
  });
  observer.observe(container);

  let latestValidatorSet: any = null;
  const update = (nodes: Array<SiteNode>, validatorSet?: any): void => {
    if (validatorSet !== undefined) latestValidatorSet = validatorSet;
    latestMapNodes = nodes;
    const retainedPopupKey = openMarkerKey || popupMarkerKey();
    const retainedPopupMode = popupMode;
    const validators: Array<Validator> = [];
    let currentValidatorCount = 0;
    for (const node of nodes) {
      const geo = node.geo;
      if (!geo) continue;
      const position = displayPosition(geo);
      if (!position) continue;
      const latitude = position.lat;
      const longitude = position.lon;
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) continue;
      const display = displayHostState(node);
      // Use the same identity-checked membership as the card, never stale
      // data from a previous map-only validator lookup.
      const currentVotingPower = node.validatorKnown === true ? node.votingPower ?? null : null;
      const currentValidator = currentVotingPower === null ? null : currentVotingPower !== "0";
      if (currentValidator === true) currentValidatorCount += 1;
      const validator: Validator = {
        name: node.name || "",
        ownerAddress: node.address || "",
        ip: node.ip || "",
        licenseCount: 0,
        online: node.isOnline === true,
        markerState: markerStateForDisplay(display.state),
        stateReason: display.reason,
        currentValidator,
        gpuCount: gpuCount(node),
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
    }
    const groups = new Map(
      groupValidators(validators).map((group) => [group.key, group]),
    );
    for (const [key, marker] of markerRegistry) {
      if (groups.has(key)) continue;
      if (openMarkerKey === key) {
        if (popupMode === "hover" || popupMode === "click") {
          removeHoverTooltip();
          openMarkerKey = null;
          popupMode = null;
        } else map.closePopup();
      }
      if (marker.__hitTarget) markers.removeLayer(marker.__hitTarget);
      markers.removeLayer(marker);
      markerRegistry.delete(key);
    }
    for (const [key, group] of groups) {
      const validators = group.validators;
      const count = validators.length;
      const gpus = validators.reduce((total, validator) => total + validator.gpuCount, 0);
      const stateCounts = markerStateCounts(validators);
      const groupState = markerGroupState(stateCounts);
      const markerState = groupState.state;
      const stateLabel = groupState.label;
      const stateSummary = markerStateSummary(stateCounts);
      const stateReasons = [
        ...new Set(validators.map((validator) => validator.stateReason)),
      ];
      const rows = validators
        .map(
          (v) =>
            `<li><span>${escapeHtml(v.name || v.ownerAddress.slice(0, 10) || "Node unavailable")}</span><span class="validator-map-member-state validator-map-status--${v.markerState}">${markerStateLabel(v.markerState)} · ${v.currentValidator === true ? "Current validator" : v.currentValidator === false ? "Not in current set" : "Membership unavailable"}</span></li>`,
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
              `${v.geo.rawLatitude.toFixed(4)}, ${v.geo.rawLongitude.toFixed(4)} (${v.geo.displaySource}${v.geo.resolvedIp ? `; ${v.geo.resolvedIp}` : ""})`,
          ),
        ),
      ];
      const statusClass = groupState.mixed
        ? "validator-map-status--mixed"
        : `validator-map-status--${markerState}`;
      const nodeLabel = `${count} node${count === 1 ? "" : "s"}`;
      const gpuLabel = `${gpus} GPU${gpus === 1 ? "" : "s"}`;
      const popupNodeLabel = `${nodeLabel} at this location`;
      const locationEvidence = `<details class="validator-map-location-evidence"><summary>Location evidence</summary><dl><dt>Source</dt><dd>${escapeHtml(sources)}</dd><dt>Position</dt><dd>${escapeHtml(rawPositions.join("; "))}</dd><dt>Accuracy</dt><dd>${escapeHtml(accuracy || "unknown")}${observed ? `; observed ${escapeHtml(observed)}` : ""}</dd><dt>State evidence</dt><dd>${escapeHtml(stateReasons.join(" · "))}</dd></dl>${correction}</details>`;
      const popupHtml = `<strong>${escapeHtml(group.label)}</strong><p class="status ${statusClass}">${escapeHtml(
        stateLabel,
      )}</p><p class="validator-map-summary"><span>${escapeHtml(popupNodeLabel)}</span><span>${escapeHtml(gpuLabel)}</span><span>${escapeHtml(stateSummary)}</span></p><ul>${rows}</ul>${locationEvidence}`;
      const ariaLabel = `${group.label}; ${nodeLabel}; ${gpuLabel}; ${stateSummary.replaceAll(" · ", ", ")}`;
      let marker: any = markerRegistry.get(key);
      if (!marker) {
        marker = L.marker([group.lat, group.lon], {
          pane: "validatorMarkers",
          interactive: false,
          icon: markerIcon(gpus, stateCounts, count),
          autoPan: container.clientWidth >= 500,
          autoPanPadding: popupAutoPanPadding(),
        }).bindPopup(popupHtml, {
            closeButton: true,
            maxWidth: popupMaxWidth(),
            autoPanPadding: popupAutoPanPadding(),
          });
        marker.__popupHtml = popupHtml;
        marker.addTo(markers);
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
        marker.setIcon(markerIcon(gpus, stateCounts, count));
        marker.__hitTarget?.setLatLng([group.lat, group.lon]);
        if (marker.__popupHtml !== popupHtml) {
          marker.setPopupContent(popupHtml);
          marker.__popupHtml = popupHtml;
        }
      }
      configureMarkerElement(marker, key, ariaLabel);
    }
    container.dataset.hostCount = String(validators.length);
    container.dataset.currentValidatorCount = latestValidatorSet?.verified === true ? String(currentValidatorCount) : "unavailable";
    container.dataset.validatorHeight = latestValidatorSet?.verified === true ? String(latestValidatorSet.blockHeight) : "";
    container.dataset.markerCount = String(groups.size);
    if (retainedPopupKey && markerRegistry.has(retainedPopupKey)) {
      openMarkerPopup(
        retainedPopupKey,
        markerRegistry.get(retainedPopupKey),
        retainedPopupMode || "pinned",
      );
    }
  };
  window.addEventListener(
    "pagehide",
    () => {
      document.removeEventListener("keydown", onKeydown, true);
      container.removeEventListener("click", activateNearest, true);
      container.removeEventListener("mousemove", showNearestPopup, true);
      container.removeEventListener("mouseout", leaveNearestPopup, true);
      container.removeEventListener("mouseleave", closeHoverPopup, true);
      removeHoverTooltip();
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
  // A slow endpoint must not let an older refresh overwrite newer evidence.
  if (refreshInFlight) return refreshInFlight;
  refreshInFlight = refreshNetwork().finally(() => { refreshInFlight = null; });
  return refreshInFlight;
}

function connectNetworkObservation(): void {
  if (!observerSnapshotMode && cfg.publicBootstrap !== true) return;
  if (networkSocket || typeof WebSocket !== "function") return;
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  const endpoint = `${protocol}//${window.location.host}${statusBase}/network/ws?chainId=${encodeURIComponent(cfg.chainId)}`;
  try {
    networkSocket = new WebSocket(endpoint);
  } catch {
    return;
  }
  networkSocket.onmessage = (event) => {
    try {
      const message = JSON.parse(String(event.data || ""));
      const snapshot = message?.type === "network_snapshot" ? message.snapshot : null;
      if (snapshot?.schema_version !== 1 || snapshot?.chain_id !== cfg.chainId || !Array.isArray(snapshot?.nodes)) return;
      networkSnapshot = snapshot;
      refresh();
    } catch {}
  };
  networkSocket.onclose = () => {
    networkSocket = null;
    networkSnapshot = null;
    if (networkSocketRetry === null)
      networkSocketRetry = setTimeout(() => {
        networkSocketRetry = null;
        connectNetworkObservation();
      }, 3000);
  };
  networkSocket.onerror = () => {};
}
let refreshInFlight: ?Promise<void> = null;
function recordRpc(node: SiteNode, status: any, observedAt: number = Date.now()): void {
  const result = status?.result;
  if (result?.node_info?.id !== node.address || !result?.sync_info)
    throw new Error("RPC node identity mismatch");
  node.endpointState = "reachable";
  node.endpointDiagnostic = "";
  node.validatorAddress = String(result.validator_info?.address || "");
  node.rpcHeight = Number(result.sync_info.latest_block_height);
  node.rpcChainId = String(result.node_info.network || "");
  node.rpcIdentityVerified = node.rpcChainId === cfg.chainId;
  node.rpcObservedAt = observedAt;
  node.rpcBlockTimeMs = Date.parse(String(result.sync_info.latest_block_time || ""));
  node.blockAgeSeconds = (Date.now() - Number(node.rpcBlockTimeMs)) / 1000;
  node.catchingUp = result.sync_info.catching_up;
  node.progressing = Number.isFinite(node.blockAgeSeconds) && Number(node.blockAgeSeconds) <= 90;
  node.chainDiagnostic = node.rpcIdentityVerified ? "" : `Configured chain mismatch: expected ${cfg.chainId}, observed ${node.rpcChainId || "unknown"}`;
  applyRetainedMembership(node);
}

function freshReference(): any {
  if (observerSnapshotMode) {
    const reference = publicChainState?.reference;
    const node = observedNodes.find((candidate) => candidate.address === reference?.node_id);
    const height = Number(reference?.height);
    const blockAge = Date.now() - Number(node?.rpcBlockTimeMs);
    return node?.endpointState === "reachable" && node?.rpcIdentityVerified === true &&
      node?.rpcChainId === cfg.chainId && node?.catchingUp === false &&
      Number.isFinite(blockAge) && blockAge >= 0 && blockAge <= 90000 &&
      Number.isSafeInteger(height) && height > 0
      ? {nodeId: node.address, chainId: cfg.chainId, height}
      : null;
  }
  return GDC_NETWORK_OBSERVATION.selectFreshReference(observedNodes
    .filter((node) => node.endpointState === "reachable")
    .map((node) => ({
      nodeId: node.address, identityVerified: node.rpcIdentityVerified,
      chainId: node.rpcChainId, height: node.rpcHeight,
      catchingUp: node.catchingUp, blockTimeMs: node.rpcBlockTimeMs,
      statusBase: node.statusBase, validatorRpcBase: node.validatorRpcBase,
    })), cfg.chainId, Date.now());
}

function applyRetainedMembership(node: SiteNode): void {
  const fresh = Date.now() - validatorSetObservedAt <= 45000 &&
    node.endpointState === "reachable" && node.rpcIdentityVerified === true;
  GDC_NETWORK_OBSERVATION.applyCurrentVotingPower(node, fresh ? retainedValidatorSet : null);
}

function refreshDetails(): void {
  if (detailsInFlight) return;
  const jobs = observedNodes.filter((node) => node.statusBase).map(async (node) => {
    const base = String(node.statusBase);
    await Promise.all([
      readSoftwareVersions(base).then((versions) => { node.softwareVersions = versions; }).catch(() => {}),
      json(`${base}/devshard/healthz`).then((runtimes) => {
        if (!Array.isArray(runtimes)) throw new Error("Malformed DevShard health response");
        node.devShardHealth = {state: "observed", runtimes};
      }).catch((error) => {
        node.devShardHealth = {state: String(error).includes("404") ? "not_exposed" : "unavailable", runtimes: []};
      }),
      json(`${base}/chain-rpc/net_info`).then((net) => {
        const card = cards.get(nodeKey(node));
        if (card) set(card, "peers", GDC_NETWORK_OBSERVATION.peerCount(net));
      }).catch(() => {}),
    ]);
    const card = cards.get(nodeKey(node));
    if (!card || !observedNodes.includes(node)) return;
    updateSoftware(cardSoftwareInventory, node, card);
    updateMlNodes(cardSoftwareInventory, cardHardwareInventory, node, card);
    updateDevShards(node, card);
  });
  if (cfg.publicBootstrap !== true) jobs.push(refreshHardwareInventory());
  if (cfg.publicBootstrap !== true)
    jobs.push(refreshDevShardVersions().catch(markDevShardVersionsUnavailable));
  detailsInFlight = Promise.all(jobs).then(() => {}).finally(() => { detailsInFlight = null; });
}

async function refreshNetwork(): Promise<void> {
  let healthy = 0;
  const finalNodeStates: Array<any> = [];
  let best = 0;
  let referenceKnown = false;
  let referenceHeight = 0;
  refreshDevShardInventory().catch(() => {});
  let reference: any = null;
  if (observerSnapshotMode) applyPublicChainState(publicChainState);
  for (const node of observedNodes) {
    // Keep fresh observations visible while polling, but never indefinitely.
    if (!node.rpcObservedAt || Date.now() - Number(node.rpcObservedAt) > 90000)
      node.endpointState = "unknown";
    applyRetainedMembership(node);
    const card = cards.get(nodeKey(node));
    if (card) renderHostState(card, node);
  }
  let reconciliation: {status: "observed" | "pending", height: number};
  try {
    reconciliation = await reconcileNetwork();
  } catch (error) {
    renderNetworkObservationStatus(String(error?.message || error).includes("malformed") ? "invalid" : "unavailable");
    return;
  }
  if (reconciliation.status === "pending") {
    renderNetworkObservationStatus("pending");
    return;
  }
  best = reconciliation.height;
  if (cfg.publicBootstrap !== true) refreshTelegramConsumer();
  if (!observerSnapshotMode) {
    refreshGpuInventory().catch(() => {});
    refreshSoftwareInventory().catch(() => {});
  }
  let membership: ?Promise<void> = null;
  let membershipDiagnostic = "";
  const startMembership = (): void => {
    if (observerSnapshotMode) return;
    if (membership) return;
    reference = freshReference();
    if (!reference) return;
    membership = refreshCurrentValidatorSet(reference).then((set) => {
      retainedValidatorSet = set;
      validatorSetObservedAt = Date.now();
      for (const node of observedNodes) {
        applyRetainedMembership(node);
        const card = cards.get(nodeKey(node));
        if (card) renderHostState(card, node);
      }
      validatorMapController?.update(observedNodes, set);
    }).catch((error) => {
      membershipDiagnostic = `Validator membership could not be refreshed: ${String(error?.message || error)}`;
    });
  };
  startMembership();
  if (!observerSnapshotMode) await Promise.all(
    observedNodes
      .filter((n) => n.mode !== "skip")
      .map(async (n) => {
        const card = cards.get(nodeKey(n));
        if (!card) return;
        if (!n.statusBase) {
          if (cfg.publicBootstrap !== true)
            n.endpointDiagnostic = "Public status route is not configured";
          renderHostState(card, n);
          updateSoftware(cardSoftwareInventory, n, card);
          updateMlNodes(cardSoftwareInventory, cardHardwareInventory, n, card);
          updateDevShards(n, card);
          return;
        }
        const statusBase = n.statusBase;
        try {
          const s = await json(`${statusBase}/chain-rpc/status`);
          recordRpc(n, s);
          const h = Number(s.result.sync_info.latest_block_height);
          if (Number.isSafeInteger(h)) best = Math.max(best, h);
          renderHostState(card, n);
          set(card, "height", Number.isSafeInteger(h) && h > 0 ? h.toLocaleString() : "–");
          startMembership();
        } catch (e) {
          n.endpointState = "unavailable";
          n.validatorKnown = false;
          n.votingPower = undefined;
          n.endpointDiagnostic = hostState.endpointDiagnostic(e);
          n.isOnline = false;
          n.serverStatus = "endpoint unavailable";
          set(card, "height", "–");
          set(card, "peers", "–");
          renderHostState(card, n);
          updateSoftware(cardSoftwareInventory, n, card);
          updateMlNodes(cardSoftwareInventory, cardHardwareInventory, n, card);
          updateDevShards(n, card);
        }
      }),
  );
  startMembership();
  // Queue core RPC and membership requests before optional probes. Browsers
  // cap same-origin connections; slow metadata must not occupy every slot.
  if (!observerSnapshotMode) refreshDetails();
  await membership;
  reference = freshReference();
  if (reference) {
    referenceHeight = Number(reference.height);
    referenceKnown = true;
    best = Math.max(best, referenceHeight);
  }
  for (const node of observedNodes) {
    const configuredChainMatch = node.networkObserved !== true || node.rpcChainId === cfg.chainId;
    node.referenceKnown = referenceKnown && configuredChainMatch;
    node.blocksBehind = referenceKnown && configuredChainMatch && Number.isFinite(node.rpcHeight)
      ? Math.abs(referenceHeight - Number(node.rpcHeight))
      : undefined;
    node.referenceAgrees = referenceKnown && configuredChainMatch && node.blocksBehind !== undefined && node.blocksBehind <= 5;
    if (!configuredChainMatch) node.chainDiagnostic = `Configured chain mismatch: expected ${cfg.chainId}, observed ${node.rpcChainId || "unknown"}`;
  }
  const currentValidatorSet = Date.now() - validatorSetObservedAt <= 45000 ? retainedValidatorSet : null;
  for (const n of observedNodes) {
    if (n.networkObserved) {
      const configuredChainMatch = n.rpcChainId === cfg.chainId;
      if (observerSnapshotMode && retainedValidatorSet?.verified !== true) {
        if (!/^\d+$/.test(String(n.votingPower || ""))) {
          n.validatorKnown = false;
          n.votingPower = undefined;
        }
      } else {
        const validatorSet = n.endpointState === "reachable" && configuredChainMatch
          ? currentValidatorSet
          : null;
        GDC_NETWORK_OBSERVATION.applyCurrentVotingPower(n, validatorSet);
      }
      n.observationComplete = true;
      if (configuredChainMatch && !n.validatorKnown) {
        n.chainDiagnostic = membershipDiagnostic || "Current validator identity is unavailable";
      }
    }
    const card = cards.get(nodeKey(n));
    const display = displayHostState(n);
    n.isOnline = display.validatorEffective;
    finalNodeStates.push(display);
    if (card) renderHostState(card, n);
  }
  healthy = GDC_NETWORK_OBSERVATION.effectiveValidatorCount(finalNodeStates);
  validatorMapController?.update(observedNodes, currentValidatorSet);
  $("best-height").textContent = best ? best.toLocaleString() : "–";
  setUtcTime("updated", new Date(), "Updated");
  try {
    if (currentValidatorSet?.verified !== true) throw new Error("complete pinned validator set is unavailable");
    const vals = currentValidatorSet.validators;
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
  if (cfg.publicBootstrap === true) {
    $("quality-updated").textContent = "Not reported for the selected network";
    [...$("quality-metrics").children].forEach((card) => {
      card.querySelector("strong").textContent = "–";
    });
    $("quality-active").textContent = "–";
    $("quality-accepted").textContent = "–";
    $("quality-rejected").textContent = "–";
    $("quality-health").dataset.state = "unknown";
    $("quality-health-state").textContent = "NOT REPORTED";
    $("quality-recovery").hidden = true;
    $("gateway-access").hidden = true;
    return;
  }
  let gatewayState: any = null;
  let gatewayProbe: any = null;
  let gatewayAdmission: any = null;
  try {
    [gatewayState, gatewayProbe, gatewayAdmission] = await Promise.all([
      json(statusUrl("/gateway/v1/status")),
      json(statusUrl("/gateway-health")),
      json(statusUrl("/gateway/v1/admission-status")),
    ]);
  } catch {
    gatewayAdmission = {
      available: false,
      reason: "admission_status_unavailable",
    };
  }
  try {
    const availability = gatewayStatus.classify(
      gatewayState,
      healthy,
      gatewayProbe,
      undefined,
      undefined,
      gatewayAdmission,
    );
    if (availability.available !== true || availability.state !== "TRAFFIC_READY")
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
  if (cfg.telegramBot) return renderTelegramProjection();
  try {
    const availability = gatewayStatus.classify(
      gatewayState,
      healthy,
      gatewayProbe,
      undefined,
      undefined,
      gatewayAdmission,
    );
    if (availability.available !== true || availability.state !== "TRAFFIC_READY")
      throw new Error(availability.message);
    const metricText = await text(statusUrl("/gateway/metrics"));
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
        ? "TRAFFIC_READY – verified inference; processing requests"
        : "TRAFFIC_READY – verified inference; no requests in flight";
    $("quality-recovery").hidden = true;
    setUtcTime("quality-updated", new Date(), "Updated");
  } catch (error) {
    const availability = gatewayStatus.classify(
      gatewayState,
      healthy,
      gatewayProbe,
      undefined,
      undefined,
      gatewayAdmission,
    );
    [...$("quality-metrics").children].forEach((card) => {
      card.querySelector("strong").textContent = "–";
    });
    for (const id of ["quality-active", "quality-accepted", "quality-rejected"])
      $(id).textContent = "–";
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
  if (cfg.telegramBot) return; // A/B labels share the bot's timed projection.
  await Promise.all(
    ["a", "b"].map(async (route) => {
      const state = $("gateway-" + route + "-state");
      const detail = $("gateway-" + route + "-detail");
      try {
        const [routeStatus, routeAdmission] = await Promise.all([
          json(statusUrl(`/gateways/${route}/v1/status`)),
          json(statusUrl(`/gateways/${route}/v1/admission-status`)),
        ]);
        const modelCapacity = routeStatus?.capacity?.models?.[cfg.model] || {};
        const limiter = routeStatus?.limiter || {};
        const inFlight = Number(limiter.in_flight_requests);
        const effective = Number(limiter.effective_max_concurrent_requests);
        if (routeAdmission?.available !== true) {
          const reason = String(routeAdmission?.reason || "admission unavailable").replaceAll("_", " ");
          state.textContent = reason === "poc fence" ? "PROTOCOL PAUSE" : "UNAVAILABLE";
          detail.textContent = `admission: ${reason}; ${Number.isFinite(inFlight) ? inFlight : "–"} requests in flight`;
        } else if (modelCapacity.routable !== true || effective <= 0) {
          state.textContent = "NO MODEL CAPACITY";
          detail.textContent = `admission responded, but effective model capacity is ${Number.isFinite(effective) ? effective : "unknown"}`;
        } else {
          // This is an admission snapshot, not a claim of a completed model
          // response. The main traffic state remains gated by its receipt.
          state.textContent = "ADMISSION AVAILABLE";
          detail.textContent = `${Number.isFinite(inFlight) ? inFlight : "–"} requests in flight; effective concurrency ${effective}`;
        }
      } catch {
        state.textContent = "STATUS ERROR";
        detail.textContent = "read-only A/B status is unavailable";
      }
    }),
  );
}
Promise.resolve((window: any).GDC_SITE_CONFIG_READY)
  .then(() => {
    configureNetwork();
    const selectionError = String((window: any).GDC_SITE_CONFIG_ERROR || "");
    if (selectionError) {
      $("updated").textContent = `Bootstrap unavailable: ${selectionError}`;
      return;
    }
    connectNetworkObservation();
    refresh();
    setInterval(refresh, 15000);
    refreshTelegramConsumer();
    setInterval(refreshTelegramConsumer, 5000);
    setInterval(() => { if (cfg.telegramBot) renderTelegramProjection(); }, 1000);
    setInterval(renderDevShardInventory, 1000);
  })
  .catch((error) => {
    $("updated").textContent = `Bootstrap unavailable: ${String(error?.message || error)}`;
  });
