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

type SoftwareVersionApi = {
  format: (state: any) => string,
};

type ValidatorMapController = {
  update: (nodes: Array<SiteNode>) => void,
};

type Participant = {
  address: string,
  inference_url: string,
  status?: string,
};

type ParticipantDiscovery = {
  statusBase?: string,
  ip?: string,
  geo?: ?GeoLocation,
};

type GpuInventory = Map<string, Array<string>>;

type Validator = {
  ownerAddress: string,
  ip: string,
  licenseCount: number,
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
const softwareVersion: SoftwareVersionApi = (window: any).GDC_SOFTWARE_VERSIONS;
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
  try {
    const health = await json("/status/telegram-consumer");
    if (health.status !== "ok" || health.inference_ready !== true) return;
    link.textContent = "Open Telegram conversation client ↗";
    link.href = cfg.telegramBot;
    link.hidden = false;
  } catch {}
}
$("grafana-network").href = cfg.grafanaNetwork || cfg.grafana;
$("grafana-inference").href = cfg.grafanaInference;
const cards: Map<string, HTMLElement> = new Map();
let observedNodes: Array<SiteNode> = cfg.nodes.map((node) => ({ ...node }));
let cardGpuInventory: GpuInventory = new Map();

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
      <span>chain sync</span>
      <b data-k="sync"></b>
    </div>
    <div class="metric">
      <span>peers</span>
      <b data-k="peers"></b>
    </div>
    <div class="metric software">
      <span>software</span>
      <b data-k="versions"></b>
    </div>
    <div class="metric gpu" data-k-row="gpu" hidden>
      <span>GPU</span>
      <b data-k="gpu"></b>
    </div>
  `;
  el.querySelector("h3").textContent = node.name;
  set(el, "status", node.mode === "skip" ? "SKIP" : "checking…");
  set(el, "scope", node.mode === "skip" ? node.reason : node.address);
  set(el, "height", node.mode === "skip" ? "–" : "…");
  set(el, "sync", node.mode === "skip" ? "not joined" : "…");
  set(el, "peers", node.mode === "skip" ? "–" : "…");
  set(el, "versions", node.mode === "skip" ? "not running" : "checking");
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
  const names = inventory.get(gpuHost) || [];
  const connection = gpuHost === node.name ? "local" : "net";
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
  const value = inventoryLabel
    ? `${inventoryLabel} – ${connection}`
    : node.gpuProfile && node.gpuProfile !== "auto"
      ? `${node.gpuProfile} – ${connection}`
      : "";
  row.hidden = !value;
  if (!value) return;
  set(card, "gpu", value);
  card.querySelector('[data-k="gpu"]').title = `GPU host: ${gpuHost}`;
}

async function refreshGpuInventory(): Promise<void> {
  const state = await json("/status/gpus");
  const next: GpuInventory = new Map();
  for (const sample of state?.data?.result || []) {
    const host = String(sample?.metric?.host || "");
    const name = String(sample?.metric?.gpu_name || "");
    if (!host || !name) continue;
    const names = next.get(host) || [];
    names.push(name);
    next.set(host, names);
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
function syncStatus(value: mixed): string {
  const normalized =
    value === null || value === undefined
      ? ""
      : String(value).trim().toLowerCase();
  if (normalized === "true" || value === true) return "sync in progress";
  if (normalized === "false" || value === false) return "in sync";
  return "checking";
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

async function participantNode(participant: Participant): Promise<SiteNode> {
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
  return {
    name: catalog?.name || host || `${participant.address.slice(0, 10)}…`,
    address: participant.address,
    publicHost: catalog?.publicHost || host,
    statusBase: catalog?.statusBase || discovered.statusBase || "",
    ip: catalog?.ip || discovered.ip || "",
    geo: catalog?.geo || discovered.geo || null,
    mode: catalog?.mode,
    reason: catalog?.reason,
    participantStatus: String(participant.status || "UNKNOWN"),
    gpuProfile: catalog?.gpuProfile,
    gpuHost: catalog?.gpuHost,
  };
}

async function reconcileParticipants(): Promise<number> {
  const state = await json("/status/participants");
  const participants = Array.isArray(state.participant)
    ? state.participant
    : [];
  const next = (await Promise.all(participants.map(participantNode))).sort(
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
    card.querySelector("h3").textContent = node.name;
    set(card, "scope", node.address);
  }
  observedNodes = next;
  return Number(state.block_height) || 0;
}

let validatorMapController: ?ValidatorMapController;

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
  const bounds = [
    [-58, -175],
    [84, 175],
  ];
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
    zoomSnap: 0.1,
    maxBounds: bounds,
    maxBoundsViscosity: 1,
    worldCopyJump: true,
    zoomControl: true,
    attributionControl: false,
  });
  const tiles = L.tileLayer(isLight() ? lightTiles : darkTiles, {
    subdomains: "abcd",
    maxZoom: 20,
  }).addTo(map);
  const markers = L.layerGroup().addTo(map);
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
      const radius = Math.min(5 + Math.sqrt(count) * 3, 18);
      const rows = validators
        .map(
          (v) =>
            `<li><span>${escapeHtml(v.ip || "IP unavailable")}</span><span>${escapeHtml(v.ownerAddress.slice(0, 10))}</span><span>${escapeHtml(v.licenseCount)}</span></li>`,
        )
        .join("");
      const popup = `<section class="validator-popup"><strong>${escapeHtml(first.geo.city)}, ${escapeHtml(first.geo.country)}</strong><p>${count} validator${count === 1 ? "" : "s"} at this location</p><ul>${rows}</ul></section>`;
      L.circleMarker([first.geo.lat, first.geo.lon], {
        radius,
        color: primary,
        weight: 1,
        opacity: 0.95,
        fillColor: primary,
        fillOpacity: 0.7,
        className: "validator-marker",
      })
        .addTo(markers)
        .bindPopup(popup, { closeButton: true, maxWidth: 340 });
    }
    container.dataset.validatorCount = String(validatorCount);
    container.dataset.markerCount = String(groups.size);
  };
  const fit = (): void => {
    map.invalidateSize({ animate: false, pan: false });
    map.fitBounds(bounds, { animate: false });
  };
  map.on("zoomend", () => {
    map.panInsideBounds(bounds, { animate: false });
    map.invalidateSize({ animate: false, pan: false });
    tiles.redraw();
  });
  const observer = new ResizeObserver(fit);
  observer.observe(container);
  const setFullscreen = (open: boolean): void => {
    shell.classList.toggle("is-fullscreen", open);
    button.setAttribute("aria-pressed", String(open));
    button.textContent = open ? "Close" : "Fullscreen";
    fit();
    setTimeout(fit, 240);
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
      map.remove();
    },
    { once: true },
  );
  update(observedNodes);
  fit();
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
  refreshTelegramConsumer();
  refreshGpuInventory().catch(() => {});
  try {
    best = await reconcileParticipants();
  } catch {}
  const singleParticipant = observedNodes.length === 1;
  await Promise.all(
    observedNodes
      .filter((n) => n.mode !== "skip")
      .map(async (n) => {
        const card = cards.get(nodeKey(n));
        if (!card) return;
        if (!n.statusBase) {
          const participantStatus = n.participantStatus || "UNKNOWN";
          set(card, "status", `${participantStatus.toLowerCase()} (chain)`);
          card.querySelector('[data-k="status"]').className =
            participantStatus === "ACTIVE" ? "status ok" : "status bad";
          set(card, "height", best ? best.toLocaleString() : "–");
          set(card, "sync", "endpoint not proxied");
          set(card, "peers", "–");
          set(card, "versions", "unreported");
          return;
        }
        const statusBase = n.statusBase;
        try {
          const [s, net] = await Promise.all([
            json(`${statusBase}/chain-rpc/status`),
            json(`${statusBase}/chain-rpc/net_info`),
          ]);
          const h = Number(s.result.sync_info.latest_block_height);
          const peers = Number(net.result.n_peers);
          best = Math.max(best, h);
          set(card, "height", h.toLocaleString());
          set(card, "sync", syncStatus(s.result.sync_info.catching_up));
          set(card, "peers", peers);
          if (peers === 0 && singleParticipant) {
            set(card, "status", "online (single node)");
            card.querySelector('[data-k="status"]').className = "status ok";
          } else if (peers === 0) {
            set(card, "status", "online (no peers)");
            card.querySelector('[data-k="status"]').className = "status bad";
          } else {
            set(card, "status", "online");
            card.querySelector('[data-k="status"]').className = "status ok";
          }
          healthy++;
          try {
            set(
              card,
              "versions",
              softwareVersion.format(await json(`${statusBase}/v1/versions`)),
            );
          } catch {
            set(card, "versions", "unreported");
          }
        } catch (e) {
          set(card, "status", `offline (${e.message})`);
          card.querySelector('[data-k="status"]').className = "status bad";
          set(card, "versions", "unavailable");
        }
      }),
  );
  validatorMapController?.update(
    observedNodes.filter((node) => node.participantStatus === "ACTIVE"),
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
        ? "READY – processing requests"
        : "READY – no requests in flight";
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
