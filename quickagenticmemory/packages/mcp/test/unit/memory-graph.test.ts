import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { beforeAll, describe, expect, it } from "vitest";

import { LocalJsonGraphAdapter } from "../../src/adapters/local-json-graph.js";
import { LocalMarkdownContentAdapter } from "../../src/adapters/local-markdown.js";
import { KnowledgeService } from "../../src/knowledge-service.js";
import { FIXTURE_COMMIT, FIXTURE_GRAPH, FIXTURE_WIKI } from "../helpers.js";

describe("local graph and Markdown adapters", () => {
  let graph: LocalJsonGraphAdapter;

  beforeAll(() => {
    graph = new LocalJsonGraphAdapter(FIXTURE_GRAPH);
  });

  it("browses and paginates a repository directory", async () => {
    const result = await graph.browseIndex({ directory: "knowledge/concepts", limit: 2, offset: 0 });
    expect(result.total).toBe(5);
    expect(result.count).toBe(2);
    expect(result.has_more).toBe(true);
    expect(result.next_offset).toBe(2);
  });

  it("resolves aliases and tags deterministically", async () => {
    const result = await graph.resolveConcepts({ terms: ["Enterprise GitHub"], limit: 10, offset: 0 });
    expect(result.items[0]?.concept.id).toBe("qam:github-source");
    expect(result.items[0]?.matched_fields).toContain("aliases");
    expect(result.items[0]?.score).toBe(90);
  });

  it("traverses neighbors, backlinks, and shortest paths", async () => {
    const neighbors = await graph.getNeighbors({
      conceptId: "qam:foundry-agent",
      maxHops: 2,
      direction: "outgoing",
      limit: 10,
    });
    expect(neighbors.nodes.map((entry) => entry.concept.id)).toEqual([
      "qam:mcp-gateway",
      "qam:fabric-projector",
      "qam:github-source",
    ]);

    const backlinks = await graph.getBacklinks({ conceptId: "qam:mcp-gateway", limit: 20, offset: 0 });
    expect(backlinks.items.map((entry) => entry.source.id)).toEqual([
      "qam:foundry-agent",
      "qam:no-raw-gql",
      "qam:index",
    ]);

    const path = await graph.findPath({
      fromId: "qam:foundry-agent",
      toId: "qam:github-source",
      maxHops: 4,
      direction: "outgoing",
    });
    expect(path.found).toBe(true);
    expect(path.hop_count).toBe(2);
    expect(path.steps.map((step) => step.concept.id)).toEqual([
      "qam:foundry-agent",
      "qam:mcp-gateway",
      "qam:github-source",
    ]);
  });

  it("traces immutable source provenance", async () => {
    const result = await graph.traceProvenance("qam:mcp-gateway");
    expect(result.snapshot.commitSha).toBe(FIXTURE_COMMIT);
    expect(result.originating_edges.map((edge) => edge.id)).toEqual(["e:gateway-provenance"]);
    expect(result.source_nodes.map((node) => node.id)).toEqual(["qam:source:enterprise-security"]);
  });

  it("reads Markdown only at the configured commit", async () => {
    const adapter = new LocalMarkdownContentAdapter(FIXTURE_WIKI, FIXTURE_COMMIT);
    const result = await adapter.readMarkdown("knowledge/concepts/wiki-mcp-gateway.md", FIXTURE_COMMIT);
    expect(result.content).toContain("seven bounded read-only tools");
    await expect(adapter.readMarkdown("knowledge/concepts/wiki-mcp-gateway.md", "2".repeat(40))).rejects.toThrow(
      /only represents commit/u,
    );
    await expect(adapter.readMarkdown("../outside.md", FIXTURE_COMMIT)).rejects.toThrow();
  });

  it("rejects a Markdown symlink that resolves outside the configured root", async () => {
    const temporaryDirectory = await mkdtemp(join(tmpdir(), "qam-mcp-symlink-"));
    try {
      const root = join(temporaryDirectory, "root");
      const outside = join(temporaryDirectory, "outside");
      await mkdir(root);
      await mkdir(outside);
      const secret = join(outside, "secret.md");
      await writeFile(secret, "# outside\n", "utf8");
      try {
        await symlink(secret, join(root, "link.md"));
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code === "EPERM" || code === "EACCES" || code === "ENOSYS") return;
        throw error;
      }

      const adapter = new LocalMarkdownContentAdapter(root, FIXTURE_COMMIT);
      await expect(adapter.readMarkdown("link.md", FIXTURE_COMMIT)).rejects.toThrow(/escapes/u);
    } finally {
      await rm(temporaryDirectory, { recursive: true, force: true });
    }
  });

  it("rejects local working-tree content that does not match the graph content hash", async () => {
    const service = new KnowledgeService({
      graph,
      content: {
        kind: "tampered-test-content",
        pathScope: "bundle",
        readMarkdown: async (path, commitSha) => ({
          path,
          commit_sha: commitSha,
          content: "# uncommitted replacement\n",
          source_url: null,
        }),
      },
    });

    await expect(service.readConcepts(["qam:mcp-gateway"], undefined, 20_000)).rejects.toThrow(/content hash/u);
  });

  it("routes bundle paths locally and repository paths to GitHub-style content adapters", async () => {
    const markdown = await readFile(join(FIXTURE_WIKI, "knowledge/concepts/wiki-mcp-gateway.md"), "utf8");
    for (const [pathScope, expectedPath] of [
      ["bundle", "knowledge/concepts/wiki-mcp-gateway.md"],
      ["repository", "quickagenticmemory/knowledge/concepts/wiki-mcp-gateway.md"],
    ] as const) {
      const receivedPaths: string[] = [];
      const service = new KnowledgeService({
        graph,
        content: {
          kind: `${pathScope}-path-test`,
          pathScope,
          readMarkdown: async (path, commitSha) => {
            receivedPaths.push(path);
            return { path, commit_sha: commitSha, content: markdown, source_url: null };
          },
        },
      });
      await service.readConcepts(["qam:mcp-gateway"], undefined, 20_000);
      expect(receivedPaths).toEqual([expectedPath]);
    }
  });

  it("loads the fixture as valid JSON independently of adapter caching", async () => {
    await expect(readFile(FIXTURE_GRAPH, "utf8")).resolves.toContain('"schemaVersion": "qam-graph/1.0"');
  });
});
