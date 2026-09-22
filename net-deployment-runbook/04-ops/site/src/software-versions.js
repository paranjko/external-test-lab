// @flow strict

declare var module: any;

type VersionValue = { version?: string };
type SoftwareVersionsState = {
  node_version?: VersionValue,
  api_version?: VersionValue,
  mlnodes?: Array<VersionValue>,
};
type SoftwareVersionsApi = {
  format: (state: ?SoftwareVersionsState) => string,
  normalizeMlNodeVersion: (chain: string, reported: string) => string,
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
    function normalizeMlNodeVersion(chain: string, reported: string): string {
      if (["0.2.14", "0.2.15"].includes(chain) && reported === "0.2.0") {
        return "3.0.14-post2";
      }
      return reported;
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
        if (!component || !sample?.metric?.version) continue;
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
      const chain = state?.node_version?.version || "unknown";
      const dapi = state?.api_version?.version || "unknown";
      const reportedMl = [
        ...new Set(
          (state?.mlnodes || []).map((node) => node.version).filter(Boolean),
        ),
      ];
      // Temporary workaround until the MLNode image reports its release version:
      // https://github.com/gonka-ai/gonka/pull/1536
      const ml =
        ["0.2.14", "0.2.15"].includes(chain) && !reportedMl.length
          ? ["3.0.14-post2"]
          : reportedMl.map((version) => normalizeMlNodeVersion(chain, version));
      return `chain ${chain} · DAPI ${dapi} · MLNode ${ml.length ? ml.join(", ") : "unreported"}`;
    }

    return { format, normalizeMlNodeVersion, selectLatestInventory };
  },
);
