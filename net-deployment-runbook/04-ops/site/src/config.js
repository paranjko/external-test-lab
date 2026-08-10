// @flow strict

type SiteConfig = {
  chainId: string,
  model: string,
  apiBase: string,
  contact: string,
  grafanaNetwork: string,
  grafanaInference: string,
  nodes: Array<mixed>,
};
declare var window: any;

(window: any).GDC_CONFIG = ({
  chainId: "render-required",
  model: "Qwen/Qwen3-0.6B",
  apiBase: "/",
  contact: "render-required",
  grafanaNetwork: "/",
  grafanaInference: "/",
  nodes: [],
}: SiteConfig);
