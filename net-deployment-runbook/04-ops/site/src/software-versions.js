// @flow strict

declare var module: any;

type VersionValue = { version?: string, node_id?: string };
type SoftwareVersionsState = {
  node_version?: VersionValue,
  api_version?: VersionValue,
  mlnodes?: Array<VersionValue>,
};
type SoftwareVersionsApi = {
  format: (state: ?SoftwareVersionsState) => string,
  displayVersion: (reported: string) => string,
  normalizeMlNodeVersion: (chain: string, reported: string) => string,
  formatMlNodes: (chain: string, mlnodes: Array<VersionValue>) => string,
  describeMlNodes: (chain: string, mlnodes: Array<VersionValue>) => Array<string>,
  selectLatestInventory: (samples: Array<any>, nowSeconds?: number, maxAgeSeconds?: number) => Map<string, any>,
  freshInventoryVersion: (reported: string, samples: Array<any>, component: string, nowSeconds?: number, maxAgeSeconds?: number) => string,
  freshPayloadVersion: (state: any, component: string, nowMs?: number, maxAgeMs?: number) => string,
  freshNetworkInferenceVersion: (inferenced: any, chainRpc: any, nodeId: string, chainId: string, nowMs?: number, maxAgeMs?: number) => string,
  selectMlNodes: (versions: any, hardware: any) => {observed: boolean, source: string, nodes: Array<VersionValue>},
  emptyMlNodeLabel: (observation: {observed: boolean, nodes: Array<VersionValue>}) => string,
};
(function attachSoftwareVersions(
  root: any,
  factory: () => SoftwareVersionsApi,
) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.GDC_SOFTWARE_VERSIONS = api;
})(
  typeof globalThis === "object" ? globalThis : this,
  function softwareVersionsFactory(): SoftwareVersionsApi {
    function displayVersion(reported: string): string {
      const normalized = String(reported || "")
        .trim()
        .replace(/^v(?=\d)/, "");
      const digest = normalized.replace(/^sha256:/, "");
      return /^[a-f0-9]{64}$/i.test(digest) ? digest.slice(0, 6) : normalized;
    }

    function normalizeMlNodeVersion(chain: string, reported: string): string {
      // Keep only the MLNode version actually reported by the runtime. A
      // core release is not evidence of the independently deployed MLNode.
      return reported;
    }

    function formatMlNodes(chain: string, mlnodes: Array<VersionValue>): string {
      const counts: Map<string, number> = new Map();
      for (const mlnode of mlnodes || []) {
        const reported = String(mlnode?.version || "").trim();
        if (!reported || reported === "unreported") continue;
        const version = displayVersion(normalizeMlNodeVersion(chain, reported));
        if (!version || version === "unreported") continue;
        counts.set(version, (counts.get(version) || 0) + 1);
      }
      return Array.from(counts, ([version, count]) =>
        count === 1 ? version : `${version} ×${count}`,
      ).join(" · ");
    }

    function describeMlNodes(
      chain: string,
      mlnodes: Array<VersionValue>,
    ): Array<string> {
      return (mlnodes || []).flatMap((mlnode) => {
        const reported = String(mlnode?.version || "").trim();
        if (!reported || reported === "unreported") return [];
        const version = displayVersion(normalizeMlNodeVersion(chain, reported));
        if (!version || version === "unreported") return [];
        const id = String(mlnode?.node_id || "").trim();
        return [id ? `${id}: ${version}` : `MLNode: ${version}`];
      });
    }

    function inventoryComponent(sample: any): string {
      const raw = String(sample?.metric?.component || "");
      if (raw === "inference-chain" || raw === "node") return "chain";
      if (raw === "decentralized-api" || raw === "api") return "DAPI";
      if (raw === "mlnode") return "MLNode";
      return "";
    }

    function observedAt(sample: any): number {
      // Prometheus instant-vector values are `[query_time, value]`. The
      // query returns `max_over_time(timestamp(gdc_component_info)[...])`,
      // so the value is the retained observation time of the labelled series.
      const value = Number(sample?.value?.[1]);
      return Number.isFinite(value) ? value : Number.NEGATIVE_INFINITY;
    }

    function sourceRank(sample: any): number {
      return sample?.metric?.source === "runtime" ? 1 : 0;
    }

    function selectLatestInventory(samples: Array<any>, nowSeconds?: number, maxAgeSeconds?: number): Map<string, any> {
      const selected: Map<string, any> = new Map();
      for (const sample of samples) {
        const component = inventoryComponent(sample);
        const version = String(sample?.metric?.version || "");
        const age = (Number(nowSeconds) || Date.now() / 1000) - observedAt(sample);
        const freshness = maxAgeSeconds === undefined ? Number.POSITIVE_INFINITY : maxAgeSeconds;
        // `unreported` is a collector sentinel, not a software release. A
        // real container observation remains useful when a runtime probe has
        // no version to report.
        if (!component || !version || version === "unreported" || !Number.isFinite(age) || age < -30 || age > freshness) continue;
        const existing = selected.get(component);
        if (
          !existing ||
          observedAt(sample) > observedAt(existing) ||
          (observedAt(sample) === observedAt(existing) &&
            sourceRank(sample) > sourceRank(existing))
        ) {
          selected.set(component, sample);
        }
      }
      return new Map(
        Array.from(selected, ([component, sample]) => [
          component,
          sample.metric,
        ]),
      );
    }

    function freshInventoryVersion(reported: string, samples: Array<any>, component: string, nowSeconds?: number, maxAgeSeconds?: number): string {
      if (reported && reported !== "unreported") return reported;
      const selected = selectLatestInventory(
        samples,
        nowSeconds === undefined ? Date.now() / 1000 : nowSeconds,
        maxAgeSeconds === undefined ? 300 : maxAgeSeconds,
      ).get(component);
      return String(selected?.version || "");
    }

    function freshTimestamp(value: any, nowMs: number, maxAgeMs: number): boolean {
      const observedAt = Date.parse(String(value || ""));
      const ageMs = nowMs - observedAt;
      return Number.isFinite(observedAt) && ageMs >= -30000 && ageMs <= maxAgeMs;
    }

    function freshPayloadVersion(state: any, component: string, nowMs?: number, maxAgeMs?: number): string {
      const now = nowMs === undefined ? Date.now() : nowMs;
      const maxAge = maxAgeMs === undefined ? 300000 : maxAgeMs;
      if (!state || typeof state !== "object") return "";
      const sourceTimestamp = state.source_timestamp || state.timestamp;
      if (!freshTimestamp(sourceTimestamp, now, maxAge)) return "";
      if (state.observed_at && !freshTimestamp(state.observed_at, now, maxAge)) return "";
      const key = component === "chain" ? "node_version" : component === "DAPI" ? "api_version" : "";
      const version = String(key ? state?.[key]?.version || "" : "").trim();
      return version && version !== "unreported" ? version : "";
    }

    function freshNetworkInferenceVersion(inferenced: any, chainRpc: any, nodeId: string, chainId: string, nowMs?: number, maxAgeMs?: number): string {
      const now = nowMs === undefined ? Date.now() : nowMs;
      const maxAge = maxAgeMs === undefined ? 300000 : maxAgeMs;
      const expectedNodeId = String(nodeId || "").toLowerCase();
      const rpcNodeId = String(chainRpc?.p2p_node_id || "").toLowerCase();
      const applicationName = String(inferenced?.application_name || "");
      const version = String(inferenced?.version || "").trim();
      if (
        inferenced?.state !== "observed" || chainRpc?.state !== "observed" ||
        !/^[0-9a-f]{40}$/.test(expectedNodeId) || rpcNodeId !== expectedNodeId ||
        String(chainRpc?.chain_id || "") !== chainId || !chainId ||
        !["inference-chain", "inferenced"].includes(applicationName) ||
        !version || version === "unreported" ||
        !freshTimestamp(inferenced?.observed_at, now, maxAge) ||
        !freshTimestamp(chainRpc?.observed_at, now, maxAge)
      ) return "";
      return version;
    }

    function format(state: ?SoftwareVersionsState): string {
      const chain = displayVersion(state?.node_version?.version || "unknown");
      const dapi = displayVersion(state?.api_version?.version || "unknown");
      return `chain ${chain} · DAPI ${dapi}`;
    }

    function selectMlNodes(versions: any, hardware: any): {observed: boolean, source: string, nodes: Array<VersionValue>} {
      let currentVersions = versions;
      if (versions?.observed_at) {
        const observedAt = Date.parse(String(versions.observed_at));
        if (!Number.isFinite(observedAt) || Date.now() - observedAt > 300000 || observedAt - Date.now() > 30000) currentVersions = null;
      }
      // An explicitly empty DAPI list is an observation, not a request to
      // resurrect old chain inventory. A missing field is not an empty list.
      if (Array.isArray(currentVersions?.mlnodes)) {
        return {observed: true, source: "DAPI runtime report", nodes: currentVersions.mlnodes};
      }
      if (hardware?.state === "observed" && Array.isArray(hardware.nodes)) {
        return {observed: true, source: "Chain runtime inventory", nodes: hardware.nodes.map(runtime => ({
          node_id: String(runtime?.local_id || ""), version: String(runtime?.version || ""),
        }))};
      }
      return {observed: false, source: "No MLNode observation", nodes: []};
    }

    function emptyMlNodeLabel(observation: {observed: boolean, nodes: Array<VersionValue>}): string {
      if (!observation.observed) return "Unavailable";
      return observation.nodes.length > 0 ? "Version unavailable" : "Not assigned";
    }

    return {
      format,
      displayVersion,
      normalizeMlNodeVersion,
      formatMlNodes,
      describeMlNodes,
      selectLatestInventory,
      freshInventoryVersion,
      freshPayloadVersion,
      freshNetworkInferenceVersion,
      selectMlNodes,
      emptyMlNodeLabel,
    };
  },
);
