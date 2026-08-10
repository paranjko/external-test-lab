// Generated from src/software-versions.js - edit the Flow source and run make site-js

(function attachSoftwareVersions(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.GDC_SOFTWARE_VERSIONS = api;
})(
  typeof globalThis === "object" ? globalThis : this,
  function softwareVersionsFactory() {
    function format(state) {
      const chain = state?.node_version?.version || "unknown";
      const dapi = state?.api_version?.version || "unknown";
      const reportedMl = [
        ...new Set(
          (state?.mlnodes || []).map((node) => node.version).filter(Boolean),
        ),
      ];
      // Temporary workaround until the MLNode image reports its release version:
      // https://github.com/gonka-ai/gonka/pull/1536
      const ml = ["0.2.14", "0.2.15"].includes(chain)
        ? ["3.0.14-post2"]
        : reportedMl;
      return `chain ${chain} · DAPI ${dapi} · MLNode ${ml.length ? ml.join(", ") : "unreported"}`;
    }

    return { format };
  },
);
