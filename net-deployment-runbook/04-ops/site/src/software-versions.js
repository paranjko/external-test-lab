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
  selectLatestInventory: (samples: Array<any>) => Map<string, any>,
  selectDevShardIdentity: (samples: Array<any>, host: string, timestamp: number) => Map<string, any>,
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
      if (
        ["0.2.14", "0.2.15"].includes(displayVersion(chain)) &&
        displayVersion(reported) === "0.2.0"
      ) {
        return "3.0.14-post2";
      }
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

    function selectLatestInventory(samples: Array<any>): Map<string, any> {
      const selected: Map<string, any> = new Map();
      for (const sample of samples) {
        const component = inventoryComponent(sample);
        const version = String(sample?.metric?.version || "");
        // `unreported` is a collector sentinel, not a software release. A
        // real container observation remains useful when a runtime probe has
        // no version to report.
        if (!component || !version || version === "unreported") continue;
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

    function format(state: ?SoftwareVersionsState): string {
      const chain = displayVersion(state?.node_version?.version || "unknown");
      const dapi = displayVersion(state?.api_version?.version || "unknown");
      return `chain ${chain} · DAPI ${dapi}`;
    }

    function selectDevShardIdentity(samples: Array<any>, host: string, timestamp: number): Map<string, any> {
      const selected: Map<string, any> = new Map();
      const ambiguous: Set<string> = new Set();
      for (const sample of samples) {
        const metric = sample?.metric;
        if (metric?.host !== host || !["v3", "v4", "v5"].includes(metric?.slot)) continue;
        const slot = metric.slot;
        if (selected.has(slot)) ambiguous.add(slot);
        const source = Number(sample?.value?.[1]);
        if (metric.source !== "process" || typeof sample?.value?.[1] !== "string" || !Number.isFinite(source) || source <= 0 || source > timestamp || timestamp - source > 90 ||
            !/^[0-9a-f]{64}$/.test(metric.binary_sha256 || "") ||
            !(metric.version === "unreported" || /^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$/.test(metric.version || ""))) {
          ambiguous.add(slot);
          continue;
        }
        selected.set(slot, { slot, version: metric.version, binarySha256: metric.binary_sha256,
          archiveSha256: /^[0-9a-f]{64}$/.test(metric.archive_sha256 || "") ? metric.archive_sha256 : null,
          observedAt: source });
      }
      for (const slot of ambiguous) selected.delete(slot);
      return selected;
    }

    return {
      format,
      displayVersion,
      normalizeMlNodeVersion,
      formatMlNodes,
      describeMlNodes,
      selectLatestInventory,
      selectDevShardIdentity,
    };
  },
);
