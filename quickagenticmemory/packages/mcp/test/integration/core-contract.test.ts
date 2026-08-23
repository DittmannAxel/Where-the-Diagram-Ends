import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { LocalJsonGraphAdapter } from "../../src/adapters/local-json-graph.js";

const CORE_GATEWAY_FIXTURE = fileURLToPath(
  new URL("../../../core/test/fixtures/gateway-graph.json", import.meta.url),
);
const CANONICAL_CONTRACT = fileURLToPath(
  new URL("../../../../contracts/qam-graph-1.0.ts", import.meta.url),
);
const CORE_CONTRACT_COPY = fileURLToPath(
  new URL("../../../core/src/qam-graph-contract.ts", import.meta.url),
);
const MCP_CONTRACT_COPY = fileURLToPath(new URL("../../src/qam-graph-contract.ts", import.meta.url));

describe("canonical Core graph contract", () => {
  it("keeps the executable Core and MCP schemas byte-identical to the canonical contract", async () => {
    const [canonical, core, mcp] = await Promise.all([
      readFile(CANONICAL_CONTRACT, "utf8"),
      readFile(CORE_CONTRACT_COPY, "utf8"),
      readFile(MCP_CONTRACT_COPY, "utf8"),
    ]);
    expect(core).toBe(canonical);
    expect(mcp).toBe(canonical);
  });

  it("loads the full union graph while exposing concept-only discovery and traversal", async () => {
    const graph = new LocalJsonGraphAdapter(CORE_GATEWAY_FIXTURE);
    const snapshot = await graph.getSnapshot();
    expect(snapshot.schemaVersion).toBe("qam-graph/1.0");
    expect(new Set(snapshot.nodes.map((node) => node.kind))).toEqual(
      new Set(["Concept", "Tag", "Source", "Term"]),
    );
    expect(snapshot.edges.map((edge) => edge.type).toSorted()).toEqual([
      "ALIASED_AS",
      "DERIVED_FROM",
      "HAS_TAG",
      "LINKS_TO",
    ]);

    const concepts = await graph.browseIndex({ directory: ".", limit: 100, offset: 0 });
    expect(concepts.items.map((node) => node.title)).toEqual(["Alpha", "Beta"]);
    const alpha = concepts.items.find((node) => node.title === "Alpha");
    const beta = concepts.items.find((node) => node.title === "Beta");
    expect(alpha).toBeDefined();
    expect(beta).toBeDefined();
    if (alpha === undefined || beta === undefined) throw new Error("Core fixture concepts are missing");

    const resolved = await graph.resolveConcepts({ terms: ["First Idea"], limit: 10, offset: 0 });
    expect(resolved.items.map((item) => item.concept.id)).toEqual([alpha.id]);

    const neighbors = await graph.getNeighbors({
      conceptId: alpha.id,
      maxHops: 2,
      direction: "outgoing",
      limit: 100,
    });
    expect(neighbors.nodes.map((item) => item.concept.id)).toEqual([beta.id]);
    expect(neighbors.edges.map((edge) => edge.type)).toEqual(["LINKS_TO"]);

    const backlinks = await graph.getBacklinks({ conceptId: beta.id, limit: 100, offset: 0 });
    expect(backlinks.items.map((item) => item.source.id)).toEqual([alpha.id]);

    const path = await graph.findPath({
      fromId: alpha.id,
      toId: beta.id,
      maxHops: 2,
      direction: "outgoing",
    });
    expect(path.found).toBe(true);
    expect(path.steps.map((step) => step.concept.id)).toEqual([alpha.id, beta.id]);

    const provenance = await graph.traceProvenance(alpha.id);
    expect(provenance.originating_edges.map((edge) => edge.type)).toEqual(["DERIVED_FROM"]);
    expect(provenance.source_nodes.map((node) => node.title)).toEqual(["Azure Architecture Center"]);
  });
});
