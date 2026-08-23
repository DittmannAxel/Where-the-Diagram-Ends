import { describe, expect, it } from "vitest";

import { serializeProjection } from "../src/exporter.js";
import {
  assertProjectedGraphContract,
  projectBundle,
  projectValidatedBundle,
  ProjectionContractError,
} from "../src/projector.js";
import {
  ConceptIdSchema,
  ConceptNodeSchema,
  GRAPH_EDGE_KIND_MATRIX,
  GitShaSchema,
  GRAPH_CONTRACT_LIMITS,
  GraphEdgeSchema,
  GraphSnapshotSchema,
  SourceNodeSchema,
  TagNodeSchema,
} from "../src/qam-graph-contract.js";
import type { GraphSnapshotContract } from "../src/qam-graph-contract.js";
import type { Frontmatter, ProjectionOptions } from "../src/types.js";
import { validateBundle } from "../src/validator.js";
import { GraphSnapshotSchema as McpGraphSnapshotSchema } from "../../mcp/src/schemas.js";
import { createBundle } from "./helpers.js";

const projectionOptions: ProjectionOptions = {
  gitSha: "0123456789abcdef0123456789abcdef01234567",
  generatedAt: "2026-08-22T12:00:00+02:00",
  repository: "https://github.com/example/qam",
  pathInRepository: "quickagenticmemory/knowledge",
};

function validSnapshot(): GraphSnapshotContract {
  const projectionId = `urn:qam:projection:${"a".repeat(64)}`;
  const commitSha = "b".repeat(40);
  return GraphSnapshotSchema.parse({
    schemaVersion: "qam-graph/1.0",
    okfVersion: "0.2",
    source: {
      repository: "https://github.com/example/qam",
      projectionId,
      commitSha,
      generatedAt: "2026-08-22T12:00:00Z",
    },
    nodes: [
      {
        id: "qam:concept",
        kind: "Concept",
        title: "Concept",
        type: "Architecture",
        tags: ["azure"],
        aliases: ["Idea"],
        projectionId,
        commitSha,
        path: "concept.md",
        repositoryPath: "knowledge/concept.md",
        conceptId: "concept",
        summary: "Summary",
        resource: "https://example.test/concept",
        status: "stable",
        contentHash: "c".repeat(64),
        sourceUrl: "https://github.com/example/qam/blob/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/concept.md",
      },
      {
        id: "qam:tag",
        kind: "Tag",
        title: "azure",
        type: "Tag",
        tags: [],
        aliases: ["Azure"],
        projectionId,
        commitSha,
        normalizedValue: "azure",
      },
      {
        id: "qam:source",
        kind: "Source",
        title: "Source",
        type: "Source",
        tags: [],
        aliases: [],
        projectionId,
        commitSha,
        resource: "https://example.test/source",
        sourceIds: ["source-1"],
        authors: ["author-1"],
        usageCounts: [0],
        lastModified: "2026-08-22T12:00:00+02:00",
      },
      {
        id: "qam:term",
        kind: "Term",
        title: "Idea",
        type: "Term",
        tags: [],
        aliases: ["Idea"],
        projectionId,
        commitSha,
        normalizedValue: "idea",
      },
    ],
    edges: [
      {
        id: "edge-1",
        from: "qam:concept",
        to: "qam:tag",
        type: "HAS_TAG",
        projectionId,
        commitSha,
        label: "azure",
        sourcePath: "concept.md",
      },
    ],
  });
}

function conceptNode(): Record<string, unknown> {
  return structuredClone(validSnapshot().nodes.find((node) => node.kind === "Concept")) as Record<
    string,
    unknown
  >;
}

function sourceNode(): Record<string, unknown> {
  return structuredClone(validSnapshot().nodes.find((node) => node.kind === "Source")) as Record<
    string,
    unknown
  >;
}

function tagNode(): Record<string, unknown> {
  return structuredClone(validSnapshot().nodes.find((node) => node.kind === "Tag")) as Record<
    string,
    unknown
  >;
}

function edge(): Record<string, unknown> {
  return structuredClone(validSnapshot().edges[0]) as Record<string, unknown>;
}

interface BoundaryCase {
  readonly name: string;
  readonly schema: { safeParse(value: unknown): { success: boolean } };
  readonly candidate: () => Record<string, unknown>;
  readonly field: string;
  readonly atLimit: unknown;
  readonly overLimit: unknown;
}

const boundaries: BoundaryCase[] = [
  {
    name: "node id (512)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "id",
    atLimit: "n".repeat(GRAPH_CONTRACT_LIMITS.nodeId),
    overLimit: "n".repeat(GRAPH_CONTRACT_LIMITS.nodeId + 1),
  },
  {
    name: "title (1024)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "title",
    atLimit: "t".repeat(GRAPH_CONTRACT_LIMITS.title),
    overLimit: "t".repeat(GRAPH_CONTRACT_LIMITS.title + 1),
  },
  {
    name: "type (100)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "type",
    atLimit: "t".repeat(GRAPH_CONTRACT_LIMITS.type),
    overLimit: "t".repeat(GRAPH_CONTRACT_LIMITS.type + 1),
  },
  {
    name: "tags array (100)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "tags",
    atLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.tags }, (_, index) => `tag-${index}`),
    overLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.tags + 1 }, (_, index) => `tag-${index}`),
  },
  {
    name: "tag value (300)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "tags",
    atLimit: ["t".repeat(GRAPH_CONTRACT_LIMITS.tag)],
    overLimit: ["t".repeat(GRAPH_CONTRACT_LIMITS.tag + 1)],
  },
  {
    name: "aliases array (100)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "aliases",
    atLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.aliases }, (_, index) => `alias-${index}`),
    overLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.aliases + 1 }, (_, index) => `alias-${index}`),
  },
  {
    name: "alias value (1024)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "aliases",
    atLimit: ["a".repeat(GRAPH_CONTRACT_LIMITS.alias)],
    overLimit: ["a".repeat(GRAPH_CONTRACT_LIMITS.alias + 1)],
  },
  {
    name: "path (1024)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "path",
    atLimit: `${"p".repeat(GRAPH_CONTRACT_LIMITS.path - 3)}.md`,
    overLimit: `${"p".repeat(GRAPH_CONTRACT_LIMITS.path - 2)}.md`,
  },
  {
    name: "repository path (1024)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "repositoryPath",
    atLimit: `${"p".repeat(GRAPH_CONTRACT_LIMITS.path - 3)}.md`,
    overLimit: `${"p".repeat(GRAPH_CONTRACT_LIMITS.path - 2)}.md`,
  },
  {
    name: "concept id (1024)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "conceptId",
    atLimit: "c".repeat(GRAPH_CONTRACT_LIMITS.conceptId),
    overLimit: "c".repeat(GRAPH_CONTRACT_LIMITS.conceptId + 1),
  },
  {
    name: "summary (4000)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "summary",
    atLimit: "s".repeat(GRAPH_CONTRACT_LIMITS.summary),
    overLimit: "s".repeat(GRAPH_CONTRACT_LIMITS.summary + 1),
  },
  {
    name: "concept resource (4096)",
    schema: ConceptNodeSchema,
    candidate: conceptNode,
    field: "resource",
    atLimit: "r".repeat(GRAPH_CONTRACT_LIMITS.resource),
    overLimit: "r".repeat(GRAPH_CONTRACT_LIMITS.resource + 1),
  },
  {
    name: "normalized value (1024)",
    schema: TagNodeSchema,
    candidate: tagNode,
    field: "normalizedValue",
    atLimit: "n".repeat(GRAPH_CONTRACT_LIMITS.normalizedValue),
    overLimit: "n".repeat(GRAPH_CONTRACT_LIMITS.normalizedValue + 1),
  },
  {
    name: "source resource (4096)",
    schema: SourceNodeSchema,
    candidate: sourceNode,
    field: "resource",
    atLimit: "r".repeat(GRAPH_CONTRACT_LIMITS.resource),
    overLimit: "r".repeat(GRAPH_CONTRACT_LIMITS.resource + 1),
  },
  {
    name: "source IDs array (100)",
    schema: SourceNodeSchema,
    candidate: sourceNode,
    field: "sourceIds",
    atLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.sourceIds }, (_, index) => `id-${index}`),
    overLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.sourceIds + 1 }, (_, index) => `id-${index}`),
  },
  {
    name: "source ID value (1024)",
    schema: SourceNodeSchema,
    candidate: sourceNode,
    field: "sourceIds",
    atLimit: ["i".repeat(GRAPH_CONTRACT_LIMITS.sourceId)],
    overLimit: ["i".repeat(GRAPH_CONTRACT_LIMITS.sourceId + 1)],
  },
  {
    name: "authors array (100)",
    schema: SourceNodeSchema,
    candidate: sourceNode,
    field: "authors",
    atLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.authors }, (_, index) => `author-${index}`),
    overLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.authors + 1 }, (_, index) => `author-${index}`),
  },
  {
    name: "author value (1024)",
    schema: SourceNodeSchema,
    candidate: sourceNode,
    field: "authors",
    atLimit: ["a".repeat(GRAPH_CONTRACT_LIMITS.author)],
    overLimit: ["a".repeat(GRAPH_CONTRACT_LIMITS.author + 1)],
  },
  {
    name: "usage counts array (100)",
    schema: SourceNodeSchema,
    candidate: sourceNode,
    field: "usageCounts",
    atLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.usageCounts }, (_, index) => index),
    overLimit: Array.from({ length: GRAPH_CONTRACT_LIMITS.usageCounts + 1 }, (_, index) => index),
  },
  {
    name: "edge id (512)",
    schema: GraphEdgeSchema,
    candidate: edge,
    field: "id",
    atLimit: "e".repeat(GRAPH_CONTRACT_LIMITS.edgeId),
    overLimit: "e".repeat(GRAPH_CONTRACT_LIMITS.edgeId + 1),
  },
  {
    name: "edge label (300)",
    schema: GraphEdgeSchema,
    candidate: edge,
    field: "label",
    atLimit: "l".repeat(GRAPH_CONTRACT_LIMITS.edgeLabel),
    overLimit: "l".repeat(GRAPH_CONTRACT_LIMITS.edgeLabel + 1),
  },
  {
    name: "edge source path (1024)",
    schema: GraphEdgeSchema,
    candidate: edge,
    field: "sourcePath",
    atLimit: `${"p".repeat(GRAPH_CONTRACT_LIMITS.path - 3)}.md`,
    overLimit: `${"p".repeat(GRAPH_CONTRACT_LIMITS.path - 2)}.md`,
  },
];

function markdown(frontmatter: Frontmatter): string {
  return `---\n${JSON.stringify(frontmatter)}\n---\nBody\n`;
}

async function project(frontmatter: Frontmatter, options = projectionOptions) {
  const bundle = await createBundle({ "concept.md": markdown(frontmatter) });
  return projectBundle(bundle, options);
}

function sources(count: number, overrides: (index: number) => Record<string, unknown> = () => ({})) {
  return Array.from({ length: count }, (_, index) => ({
    id: `source-${index}`,
    resource: "shared-resource",
    author: `author-${index}`,
    usage_count: index,
    ...overrides(index),
  }));
}

describe("canonical qam-graph/1.0 boundaries", () => {
  it.each(boundaries)("accepts $name exactly and rejects the next value", (boundary) => {
    const accepted = boundary.candidate();
    accepted[boundary.field] = boundary.atLimit;
    expect(boundary.schema.safeParse(accepted).success).toBe(true);

    const rejected = boundary.candidate();
    rejected[boundary.field] = boundary.overLimit;
    expect(boundary.schema.safeParse(rejected).success).toBe(false);
  });

  it("enforces snapshot metadata boundaries", () => {
    const accepted = validSnapshot();
    accepted.okfVersion = "v".repeat(GRAPH_CONTRACT_LIMITS.okfVersion);
    accepted.source.repository = "r".repeat(GRAPH_CONTRACT_LIMITS.repository);
    expect(GraphSnapshotSchema.safeParse(accepted).success).toBe(true);

    const longVersion = validSnapshot();
    longVersion.okfVersion = "v".repeat(GRAPH_CONTRACT_LIMITS.okfVersion + 1);
    expect(GraphSnapshotSchema.safeParse(longVersion).success).toBe(false);

    const longRepository = validSnapshot();
    longRepository.source.repository = "r".repeat(GRAPH_CONTRACT_LIMITS.repository + 1);
    expect(GraphSnapshotSchema.safeParse(longRepository).success).toBe(false);
  });

  it("requires at least one node while allowing an edge-free snapshot", async () => {
    const edgeFree = validSnapshot();
    edgeFree.edges = [];
    expect(GraphSnapshotSchema.safeParse(edgeFree).success).toBe(true);

    const empty = validSnapshot();
    empty.nodes = [];
    empty.edges = [];
    expect(GraphSnapshotSchema.safeParse(empty).success).toBe(false);
    await expect(projectBundle(await createBundle({}), projectionOptions)).rejects.toThrow(ProjectionContractError);
  });

  it("enforces URL, SHA, timestamp, hash, and non-negative-integer formats", () => {
    expect(GitShaSchema.safeParse("a".repeat(40)).success).toBe(true);
    expect(GitShaSchema.safeParse("a".repeat(64)).success).toBe(true);
    expect(GitShaSchema.safeParse("a".repeat(39)).success).toBe(false);
    expect(GitShaSchema.safeParse("A".repeat(40)).success).toBe(false);
    expect(ConceptIdSchema.safeParse("a".repeat(512)).success).toBe(true);
    expect(ConceptIdSchema.safeParse("a".repeat(513)).success).toBe(false);

    const invalidUrl = conceptNode();
    invalidUrl.sourceUrl = "not a URL";
    expect(ConceptNodeSchema.safeParse(invalidUrl).success).toBe(false);

    const invalidHash = conceptNode();
    invalidHash.contentHash = "a".repeat(63);
    expect(ConceptNodeSchema.safeParse(invalidHash).success).toBe(false);

    for (const usageCounts of [[-1], [1.5], [Number.NaN]]) {
      const invalidUsage = sourceNode();
      invalidUsage.usageCounts = usageCounts;
      expect(SourceNodeSchema.safeParse(invalidUsage).success).toBe(false);
    }
    const zeroUsage = sourceNode();
    zeroUsage.usageCounts = [0];
    expect(SourceNodeSchema.safeParse(zeroUsage).success).toBe(true);
    const maximumUsage = sourceNode();
    maximumUsage.usageCounts = [Number.MAX_SAFE_INTEGER];
    expect(SourceNodeSchema.safeParse(maximumUsage).success).toBe(true);
    const unsafeUsage = sourceNode();
    unsafeUsage.usageCounts = [Number.MAX_SAFE_INTEGER + 1];
    expect(SourceNodeSchema.safeParse(unsafeUsage).success).toBe(false);

    const invalidDate = sourceNode();
    invalidDate.lastModified = "2026-08-22";
    expect(SourceNodeSchema.safeParse(invalidDate).success).toBe(false);
    const invalidGeneratedAt = validSnapshot();
    invalidGeneratedAt.source.generatedAt = "2026-08-22T12:00:00";
    expect(GraphSnapshotSchema.safeParse(invalidGeneratedAt).success).toBe(false);
  });

  it("enforces the canonical edge type-to-node kind matrix", () => {
    const snapshot = validSnapshot();
    const projection = {
      projectionId: snapshot.source.projectionId,
      commitSha: snapshot.source.commitSha,
    };
    snapshot.edges = [
      { id: "links", from: "qam:concept", to: "qam:concept", type: "LINKS_TO", ...projection },
      { id: "tag", from: "qam:concept", to: "qam:tag", type: "HAS_TAG", ...projection },
      { id: "source", from: "qam:concept", to: "qam:source", type: "DERIVED_FROM", ...projection },
      { id: "term", from: "qam:concept", to: "qam:term", type: "ALIASED_AS", ...projection },
    ];
    expect(GraphSnapshotSchema.safeParse(snapshot).success).toBe(true);
    expect(GRAPH_EDGE_KIND_MATRIX).toEqual({
      LINKS_TO: { from: "Concept", to: "Concept" },
      HAS_TAG: { from: "Concept", to: "Tag" },
      DERIVED_FROM: { from: "Concept", to: "Source" },
      ALIASED_AS: { from: "Concept", to: "Term" },
    });

    const wrongTargets = {
      LINKS_TO: "qam:tag",
      HAS_TAG: "qam:source",
      DERIVED_FROM: "qam:term",
      ALIASED_AS: "qam:tag",
    } as const;
    for (const edge of snapshot.edges) {
      const wrongSource = structuredClone(snapshot);
      const sourceCandidate = wrongSource.edges.find((candidate) => candidate.id === edge.id);
      if (sourceCandidate === undefined) throw new Error("Edge fixture is missing");
      sourceCandidate.from = "qam:tag";
      expect(GraphSnapshotSchema.safeParse(wrongSource).success).toBe(false);

      const wrongTarget = structuredClone(snapshot);
      const targetCandidate = wrongTarget.edges.find((candidate) => candidate.id === edge.id);
      if (targetCandidate === undefined) throw new Error("Edge fixture is missing");
      targetCandidate.to = wrongTargets[edge.type];
      expect(GraphSnapshotSchema.safeParse(wrongTarget).success).toBe(false);
    }
  });
});

describe("Core producer to MCP contract", () => {
  it("projects every producer-reachable maximum without truncation", async () => {
    const tags = [
      "t".repeat(GRAPH_CONTRACT_LIMITS.tag),
      ...Array.from({ length: GRAPH_CONTRACT_LIMITS.tags - 1 }, (_, index) => `tag-${index}`),
    ];
    const aliases = [
      "a".repeat(GRAPH_CONTRACT_LIMITS.alias),
      ...Array.from({ length: GRAPH_CONTRACT_LIMITS.aliases - 1 }, (_, index) => `alias-${index}`),
    ];
    const sourceEntries = sources(GRAPH_CONTRACT_LIMITS.sourceIds, (index) => ({
      id: index === 0 ? "i".repeat(GRAPH_CONTRACT_LIMITS.sourceId) : `source-${index}`,
      resource: "r".repeat(GRAPH_CONTRACT_LIMITS.resource),
      author: index === 0 ? "u".repeat(GRAPH_CONTRACT_LIMITS.author) : `author-${index}`,
      last_modified: "2026-08-22T12:00:00Z",
    }));
    const output = await project({
      type: "T".repeat(GRAPH_CONTRACT_LIMITS.type),
      title: "T".repeat(GRAPH_CONTRACT_LIMITS.title),
      description: "D".repeat(GRAPH_CONTRACT_LIMITS.summary),
      resource: "R".repeat(GRAPH_CONTRACT_LIMITS.resource),
      tags,
      aliases,
      sources: sourceEntries,
    });

    expect(() => assertProjectedGraphContract(output.graph)).not.toThrow();
    expect(() => McpGraphSnapshotSchema.parse(output.graph)).not.toThrow();
    const concept = output.graph.nodes.find((node) => node.kind === "Concept");
    const source = output.graph.nodes.find((node) => node.kind === "Source");
    expect(concept?.tags).toHaveLength(GRAPH_CONTRACT_LIMITS.tags);
    expect(new Set(concept?.tags)).toEqual(new Set(tags));
    expect(concept?.aliases).toHaveLength(GRAPH_CONTRACT_LIMITS.aliases);
    expect(new Set(concept?.aliases)).toEqual(new Set(aliases));
    expect(source?.title).toBe("Source");
    expect(source?.resource).toHaveLength(GRAPH_CONTRACT_LIMITS.resource);
    expect(source?.sourceIds).toHaveLength(GRAPH_CONTRACT_LIMITS.sourceIds);
    expect(source?.authors).toHaveLength(GRAPH_CONTRACT_LIMITS.authors);
    expect(source?.usageCounts).toHaveLength(GRAPH_CONTRACT_LIMITS.usageCounts);
    const maximumTagEdge = output.graph.edges.find(
      (candidate) =>
        candidate.type === "HAS_TAG" &&
        output.graph.nodes.find((node) => node.id === candidate.to)?.title === tags[0],
    );
    expect(maximumTagEdge?.label).toBe(tags[0]);
    const longAliasEdge = output.graph.edges.find(
      (candidate) =>
        candidate.type === "ALIASED_AS" &&
        output.graph.nodes.find((node) => node.id === candidate.to)?.title === aliases[0],
    );
    expect(longAliasEdge).toBeDefined();
    expect(longAliasEdge?.label).toBeUndefined();
  });

  it.each([
    ["title", { type: "Concept", title: "t".repeat(GRAPH_CONTRACT_LIMITS.title + 1) }],
    ["type", { type: "t".repeat(GRAPH_CONTRACT_LIMITS.type + 1) }],
    ["summary", { type: "Concept", description: "s".repeat(GRAPH_CONTRACT_LIMITS.summary + 1) }],
    ["concept resource", { type: "Concept", resource: "r".repeat(GRAPH_CONTRACT_LIMITS.resource + 1) }],
    ["tag item", { type: "Concept", tags: ["t".repeat(GRAPH_CONTRACT_LIMITS.tag + 1)] }],
    ["tag array", { type: "Concept", tags: Array.from({ length: 101 }, (_, index) => `tag-${index}`) }],
    ["alias item", { type: "Concept", aliases: ["a".repeat(GRAPH_CONTRACT_LIMITS.alias + 1)] }],
    ["alias array", { type: "Concept", aliases: Array.from({ length: 101 }, (_, index) => `alias-${index}`) }],
    [
      "source resource",
      { type: "Concept", sources: [{ resource: "r".repeat(GRAPH_CONTRACT_LIMITS.resource + 1) }] },
    ],
    ["source IDs array", { type: "Concept", sources: sources(101) }],
    [
      "source ID item",
      {
        type: "Concept",
        sources: [{ resource: "source", id: "i".repeat(GRAPH_CONTRACT_LIMITS.sourceId + 1) }],
      },
    ],
    [
      "author item",
      {
        type: "Concept",
        sources: [{ resource: "source", author: "a".repeat(GRAPH_CONTRACT_LIMITS.author + 1) }],
      },
    ],
    [
      "authors array",
      {
        type: "Concept",
        sources: sources(101, (index) => ({ id: "same", author: `author-${index}` })),
      },
    ],
    [
      "usage counts array",
      {
        type: "Concept",
        sources: sources(101, (index) => ({ id: "same", author: "same", usage_count: index })),
      },
    ],
  ] as const)("fails closed on an oversized %s", async (_name, frontmatter) => {
    await expect(project(frontmatter)).rejects.toThrow(ProjectionContractError);
  });

  it.each([
    ["INVALID_USAGE_COUNT", { usage_count: 1.5 }],
    ["INVALID_USAGE_COUNT", { usage_count: -1 }],
    ["INVALID_USAGE_COUNT", { usage_count: Number.MAX_SAFE_INTEGER + 1 }],
    ["INVALID_TIMESTAMP", { last_modified: "yesterday" }],
  ] as const)("consciously omits permissive invalid optional source metadata: %s", async (diagnostic, optional) => {
    const bundle = await createBundle({
      "concept.md": markdown({
        type: "Concept",
        sources: [{ resource: "source", ...optional }],
      }),
    });
    const validation = await validateBundle(bundle);
    expect(validation.diagnostics).toContainEqual(expect.objectContaining({ code: diagnostic }));
    const output = projectValidatedBundle(validation, projectionOptions);
    const source = output.graph.nodes.find((node) => node.kind === "Source");
    expect(source?.usageCounts).toEqual([]);
    expect(source).not.toHaveProperty("lastModified");
    expect(() => assertProjectedGraphContract(output.graph)).not.toThrow();
  });

  it("rejects invalid provenance and validates again immediately before NDJSON serialization", async () => {
    await expect(project({ type: "Concept" }, { ...projectionOptions, gitSha: "main" })).rejects.toThrow(
      ProjectionContractError,
    );
    await expect(
      project({ type: "Concept" }, { ...projectionOptions, repository: "r".repeat(501) }),
    ).rejects.toThrow(ProjectionContractError);

    const output = await project({ type: "Concept", title: "Valid" });
    const concept = output.graph.nodes.find((node) => node.kind === "Concept");
    if (concept === undefined) throw new Error("Concept fixture is missing");
    concept.title = "x".repeat(GRAPH_CONTRACT_LIMITS.title + 1);
    expect(() => serializeProjection(output)).toThrow(ProjectionContractError);
  });
});
