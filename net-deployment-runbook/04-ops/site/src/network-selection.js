// @flow strict

declare var window: any;
declare var document: any;
declare class URLSearchParams {
  constructor(value: string): void;
  get: (name: string) => ?string;
}

function selectedChainId(): string {
  const query = new URLSearchParams(String(window.location?.search || ""));
  const direct = query.get("chainId");
  const hash = String(window.location?.hash || "").match(/^#chainId=([^&]+)$/);
  return String(direct || (hash ? decodeURIComponent(hash[1]) : "")).trim();
}

(function selectNetwork(): void {
  const config = window.GDC_CONFIG || {};
  const chainId = selectedChainId();
  window.GDC_SITE_CONFIG_READY = (async (): Promise<void> => {
    if (!chainId || chainId === config.chainId) return;
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(chainId))
      throw new Error("chainId must be a bootstrap network identifier");
    // The observer derives node observations from public bootstrap. The
    // browser only asks it which network to observe.
    config.chainId = chainId;
    config.model = "Not reported";
    config.publicBootstrap = true;
    config.nodes = [];
    config.nodeCatalog = [];
  })().catch((error) => {
    window.GDC_SITE_CONFIG_ERROR = String(error?.message || error);
  });
})();
