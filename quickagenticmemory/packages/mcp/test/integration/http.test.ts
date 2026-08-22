import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { readFile } from "node:fs/promises";
import { afterEach, describe, expect, it } from "vitest";
import * as z from "zod/v4";

import { MemoryGraphAdapter } from "../../src/adapters/memory-graph.js";
import { startHttpServer, type RunningHttpServer } from "../../src/http.js";
import { GraphSnapshotSchema, type GraphSnapshot } from "../../src/schemas.js";
import type { BrowseIndexQuery, GraphSnapshotView } from "../../src/types.js";
import { FIXTURE_GRAPH, fixtureAdapters } from "../helpers.js";

const TOKEN = "test-bearer-token-with-more-than-24-characters";
const ResolveResultSchema = z.object({
  matches: z.array(z.object({ concept: z.object({ id: z.string() }) })),
});
const BrowseGenerationSchema = z.object({
  commit_sha: z.string(),
  concepts: z.array(z.object({ commitSha: z.string(), projectionId: z.string() })),
});

class GenerationBoundaryGraphAdapter extends MemoryGraphAdapter {
  readonly #stable: MemoryGraphAdapter;
  readonly #next: MemoryGraphAdapter;

  public constructor(stable: GraphSnapshot, next: GraphSnapshot) {
    super(stable);
    this.#stable = new MemoryGraphAdapter(stable);
    this.#next = new MemoryGraphAdapter(next);
  }

  public override async acquireSnapshot(): Promise<GraphSnapshotView> {
    return { snapshot: await this.#stable.getSnapshot(), graph: this.#stable };
  }

  public override async browseIndex(query: BrowseIndexQuery) {
    return this.#next.browseIndex(query);
  }
}

describe("Streamable HTTP transport", () => {
  let running: RunningHttpServer | undefined;
  let client: Client | undefined;

  afterEach(async () => {
    await client?.close();
    await running?.close();
    client = undefined;
    running = undefined;
  });

  it("requires authentication and rejects untrusted browser origins", async () => {
    running = await startHttpServer(fixtureAdapters(), {
      host: "127.0.0.1",
      port: 0,
      allowedHosts: ["127.0.0.1", "localhost"],
      allowedOrigins: ["127.0.0.1", "localhost"],
      auth: { mode: "bearer", token: TOKEN },
    });

    const unauthenticated = await fetch(running.url, { method: "GET" });
    expect(unauthenticated.status).toBe(401);
    const badOrigin = await fetch(running.url, {
      method: "GET",
      headers: { Authorization: `Bearer ${TOKEN}`, Origin: "https://evil.example" },
    });
    expect(badOrigin.status).toBe(403);
  });

  it("lists only the seven read tools and returns structured results", async () => {
    running = await startHttpServer(fixtureAdapters(), {
      host: "127.0.0.1",
      port: 0,
      allowedHosts: ["127.0.0.1", "localhost"],
      allowedOrigins: ["127.0.0.1", "localhost"],
      auth: { mode: "bearer", token: TOKEN },
    });
    client = new Client({ name: "http-integration-test", version: "1.0.0" });
    const transport = new StreamableHTTPClientTransport(running.url, {
      authProvider: { token: async () => TOKEN },
    });
    await client.connect(transport);

    const tools = await client.listTools();
    expect(tools.tools.map((tool) => tool.name)).toEqual([
      "browse_index",
      "resolve_concepts",
      "get_neighbors",
      "get_backlinks",
      "find_path",
      "read_concepts",
      "trace_provenance",
    ]);
    expect(tools.tools.every((tool) => tool.annotations?.readOnlyHint === true)).toBe(true);
    expect(tools.tools.some((tool) => tool.name === "propose_wiki_update")).toBe(false);

    const result = await client.callTool({
      name: "resolve_concepts",
      arguments: { terms: ["Knowledge Gateway"], response_format: "json" },
    });
    expect(result.isError).not.toBe(true);
    expect(ResolveResultSchema.parse(result.structuredContent).matches[0]?.concept.id).toBe("qam:mcp-gateway");
  });

  it("keeps composite tool metadata and results on one immutable graph generation", async () => {
    const stable = GraphSnapshotSchema.parse(JSON.parse(await readFile(FIXTURE_GRAPH, "utf8")) as unknown);
    const nextProjectionId = `urn:qam:projection:${"d".repeat(64)}`;
    const nextCommitSha = "e".repeat(40);
    const next = GraphSnapshotSchema.parse({
      ...stable,
      source: { ...stable.source, projectionId: nextProjectionId, commitSha: nextCommitSha },
      nodes: stable.nodes.map((node) => ({ ...node, projectionId: nextProjectionId, commitSha: nextCommitSha })),
      edges: stable.edges.map((edge) => ({ ...edge, projectionId: nextProjectionId, commitSha: nextCommitSha })),
    });
    const content = fixtureAdapters().content;
    running = await startHttpServer(
      { graph: new GenerationBoundaryGraphAdapter(stable, next), content },
      {
        host: "127.0.0.1",
        port: 0,
        allowedHosts: ["127.0.0.1", "localhost"],
        allowedOrigins: ["127.0.0.1", "localhost"],
        auth: { mode: "bearer", token: TOKEN },
      },
    );
    client = new Client({ name: "http-generation-test", version: "1.0.0" });
    await client.connect(
      new StreamableHTTPClientTransport(running.url, { authProvider: { token: async () => TOKEN } }),
    );

    const result = await client.callTool({
      name: "browse_index",
      arguments: { directory: ".", response_format: "json" },
    });
    expect(result.isError).not.toBe(true);
    const output = BrowseGenerationSchema.parse(result.structuredContent);
    expect(output.commit_sha).toBe(stable.source.commitSha);
    expect(new Set(output.concepts.map((concept) => concept.commitSha))).toEqual(
      new Set([stable.source.commitSha]),
    );
    expect(new Set(output.concepts.map((concept) => concept.projectionId))).toEqual(
      new Set([stable.source.projectionId]),
    );
  });
});
