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
      const value = Number(sample?.value?.[0]);
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

    return {
      format,
      displayVersion,
      normalizeMlNodeVersion,
      formatMlNodes,
      describeMlNodes,
      selectLatestInventory,
    };
  },
);
