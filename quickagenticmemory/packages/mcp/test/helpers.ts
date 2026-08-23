import { fileURLToPath } from "node:url";

import { LocalJsonGraphAdapter } from "../src/adapters/local-json-graph.js";
import { LocalMarkdownContentAdapter } from "../src/adapters/local-markdown.js";
import type { GatewayAdapters } from "../src/types.js";

export const FIXTURE_COMMIT = "1111111111111111111111111111111111111111";
export const FIXTURE_GRAPH = fileURLToPath(new URL("./fixtures/graph.json", import.meta.url));
export const FIXTURE_WIKI = fileURLToPath(new URL("./fixtures/wiki", import.meta.url));

export function fixtureAdapters(): GatewayAdapters {
  return {
    graph: new LocalJsonGraphAdapter(FIXTURE_GRAPH),
    content: new LocalMarkdownContentAdapter(FIXTURE_WIKI, FIXTURE_COMMIT),
  };
}
