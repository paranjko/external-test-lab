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
      const ml = ["0.2.14", "0.2.15"].includes(chain) && !reportedMl.length
        ? ["3.0.14-post2"]
        : reportedMl.map((version) => normalizeMlNodeVersion(chain, version));
      return `chain ${chain} · DAPI ${dapi} · MLNode ${ml.length ? ml.join(", ") : "unreported"}`;
    }

    return { format, normalizeMlNodeVersion };
  },
);
