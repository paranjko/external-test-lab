import { DefaultEmbedder } from "./default_embedder";
import { defaultPlugins } from "./default_plugins";
export class GonkaEmbedder extends DefaultEmbedder {
  override readonly analyticsId = undefined;
  override readonly extensionServer = undefined;
  override readonly defaultPlugins = [...defaultPlugins, "net.gonka.Consensus"];
}
