// qam-graph/1.0 canonical executable contract.
//
// Do not edit the package-local generated copies. Run:
//   node scripts/sync-graph-contract.mjs
// Both Core and MCP execute this exact schema; their test lifecycle checks that
// the generated copies remain byte-identical to this source.

import * as z from "zod/v4";

export const GRAPH_SCHEMA_VERSION = "qam-graph/1.0" as const;

export const GRAPH_CONTRACT_LIMITS = {
  graphNodes: 100_000,
  graphEdges: 500_000,
  okfVersion: 50,
  repository: 500,
  nodeId: 512,
  title: 1_024,
  type: 100,
  path: 1_024,
  conceptId: 1_024,
  tags: 100,
  tag: 300,
  aliases: 100,
  alias: 1_024,
  summary: 4_000,
  resource: 4_096,
  normalizedValue: 1_024,
  sourceIds: 100,
  sourceId: 1_024,
  authors: 100,
  author: 1_024,
  usageCounts: 100,
  edgeId: 512,
  edgeLabel: 300,
} as const;

export const GRAPH_CONTRACT_PATTERNS = {
  conceptId: /^[A-Za-z0-9][A-Za-z0-9._:/#-]{0,511}$/u,
  fullGitSha: /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/u,
  projectionId: /^urn:qam:projection:[0-9a-f]{64}$/u,
  repositoryPath:
    /^(?!\/)(?!\.{1,2}(?:\/|$))(?!.*\/\.{1,2}(?:\/|$))[A-Za-z0-9._ -]+(?:\/[A-Za-z0-9._ -]+)*$/u,
} as const;

export const GitShaSchema = z
  .string()
  .regex(
    GRAPH_CONTRACT_PATTERNS.fullGitSha,
    "commit_sha must be a lowercase full 40- or 64-character hexadecimal Git object ID",
  );

export const ProjectionIdSchema = z
  .string()
  .regex(
    GRAPH_CONTRACT_PATTERNS.projectionId,
    "projectionId must be a deterministic urn:qam:projection SHA-256 identifier",
  );

export const RepoPathSchema = z
  .string()
  .min(1)
  .max(GRAPH_CONTRACT_LIMITS.path)
  .regex(
    GRAPH_CONTRACT_PATTERNS.repositoryPath,
    "path must be repository-relative and contain no empty, current-directory, parent-directory, or unsupported segments",
  );

export const ConceptIdSchema = z
  .string()
  .regex(GRAPH_CONTRACT_PATTERNS.conceptId, "concept_id contains unsupported characters");

export const EdgeTypeSchema = z.enum(["LINKS_TO", "HAS_TAG", "DERIVED_FROM", "ALIASED_AS"]);

export type GraphNodeKind = "Concept" | "Tag" | "Source" | "Term";

export const GRAPH_EDGE_KIND_MATRIX = {
  LINKS_TO: { from: "Concept", to: "Concept" },
  HAS_TAG: { from: "Concept", to: "Tag" },
  DERIVED_FROM: { from: "Concept", to: "Source" },
  ALIASED_AS: { from: "Concept", to: "Term" },
} as const satisfies Record<z.infer<typeof EdgeTypeSchema>, { readonly from: GraphNodeKind; readonly to: GraphNodeKind }>;

const GraphNodeBaseShape = {
  id: ConceptIdSchema,
  title: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.title),
  type: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.type),
  tags: z
    .array(z.string().min(1).max(GRAPH_CONTRACT_LIMITS.tag))
    .max(GRAPH_CONTRACT_LIMITS.tags),
  aliases: z
    .array(z.string().min(1).max(GRAPH_CONTRACT_LIMITS.alias))
    .max(GRAPH_CONTRACT_LIMITS.aliases),
  commitSha: GitShaSchema,
  projectionId: ProjectionIdSchema,
};

export const ConceptNodeSchema = z
  .object({
    ...GraphNodeBaseShape,
    kind: z.literal("Concept"),
    path: RepoPathSchema,
    repositoryPath: RepoPathSchema,
    conceptId: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.conceptId),
    summary: z.string().max(GRAPH_CONTRACT_LIMITS.summary).optional(),
    resource: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.resource).optional(),
    status: z.enum(["draft", "stable", "deprecated"]),
    contentHash: z.string().regex(/^[0-9a-f]{64}$/u),
    sourceUrl: z.url().optional(),
  })
  .strict();

export const TagNodeSchema = z
  .object({
    ...GraphNodeBaseShape,
    kind: z.literal("Tag"),
    type: z.literal("Tag"),
    normalizedValue: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.normalizedValue),
  })
  .strict();

export const SourceNodeSchema = z
  .object({
    ...GraphNodeBaseShape,
    kind: z.literal("Source"),
    type: z.literal("Source"),
    resource: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.resource),
    sourceIds: z
      .array(z.string().min(1).max(GRAPH_CONTRACT_LIMITS.sourceId))
      .max(GRAPH_CONTRACT_LIMITS.sourceIds),
    authors: z
      .array(z.string().min(1).max(GRAPH_CONTRACT_LIMITS.author))
      .max(GRAPH_CONTRACT_LIMITS.authors),
    usageCounts: z.array(z.number().int().nonnegative()).max(GRAPH_CONTRACT_LIMITS.usageCounts),
    lastModified: z.iso.datetime({ offset: true }).optional(),
  })
  .strict();

export const TermNodeSchema = z
  .object({
    ...GraphNodeBaseShape,
    kind: z.literal("Term"),
    type: z.literal("Term"),
    normalizedValue: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.normalizedValue),
  })
  .strict();

export const GraphNodeSchema = z.discriminatedUnion("kind", [
  ConceptNodeSchema,
  TagNodeSchema,
  SourceNodeSchema,
  TermNodeSchema,
]);

export const GraphEdgeSchema = z
  .object({
    id: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.edgeId),
    from: ConceptIdSchema,
    to: ConceptIdSchema,
    type: EdgeTypeSchema,
    projectionId: ProjectionIdSchema,
    commitSha: GitShaSchema,
    label: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.edgeLabel).optional(),
    sourcePath: RepoPathSchema.optional(),
  })
  .strict();

export const GraphSnapshotSchema = z
  .object({
    schemaVersion: z.literal(GRAPH_SCHEMA_VERSION),
    okfVersion: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.okfVersion),
    source: z
      .object({
        repository: z.string().min(1).max(GRAPH_CONTRACT_LIMITS.repository),
        projectionId: ProjectionIdSchema,
        commitSha: GitShaSchema,
        generatedAt: z.iso.datetime({ offset: true }),
      })
      .strict(),
    nodes: z.array(GraphNodeSchema).min(1).max(GRAPH_CONTRACT_LIMITS.graphNodes),
    edges: z.array(GraphEdgeSchema).max(GRAPH_CONTRACT_LIMITS.graphEdges),
  })
  .strict()
  .superRefine((snapshot, context) => {
    const nodeIds = new Set<string>();
    const nodeKinds = new Map<string, GraphNodeKind>();
    const paths = new Set<string>();
    for (const [index, node] of snapshot.nodes.entries()) {
      if (nodeIds.has(node.id)) {
        context.addIssue({ code: "custom", message: `duplicate node id '${node.id}'`, path: ["nodes", index, "id"] });
      }
      if (node.kind === "Concept" && paths.has(node.path)) {
        context.addIssue({
          code: "custom",
          message: `duplicate concept path '${node.path}'`,
          path: ["nodes", index, "path"],
        });
      }
      if (node.commitSha !== snapshot.source.commitSha) {
        context.addIssue({
          code: "custom",
          message: "node commitSha must match source.commitSha",
          path: ["nodes", index, "commitSha"],
        });
      }
      if (node.projectionId !== snapshot.source.projectionId) {
        context.addIssue({
          code: "custom",
          message: "node projectionId must match source.projectionId",
          path: ["nodes", index, "projectionId"],
        });
      }
      nodeIds.add(node.id);
      if (!nodeKinds.has(node.id)) nodeKinds.set(node.id, node.kind);
      if (node.kind === "Concept") paths.add(node.path);
    }

    const edgeIds = new Set<string>();
    for (const [index, edge] of snapshot.edges.entries()) {
      if (edgeIds.has(edge.id)) {
        context.addIssue({ code: "custom", message: `duplicate edge id '${edge.id}'`, path: ["edges", index, "id"] });
      }
      if (!nodeIds.has(edge.from)) {
        context.addIssue({ code: "custom", message: `unknown edge source '${edge.from}'`, path: ["edges", index, "from"] });
      }
      if (!nodeIds.has(edge.to)) {
        context.addIssue({ code: "custom", message: `unknown edge target '${edge.to}'`, path: ["edges", index, "to"] });
      }
      const expectedKinds = GRAPH_EDGE_KIND_MATRIX[edge.type];
      const sourceKind = nodeKinds.get(edge.from);
      if (sourceKind !== undefined && sourceKind !== expectedKinds.from) {
        context.addIssue({
          code: "custom",
          message: `${edge.type} edge source must be a ${expectedKinds.from} node, not ${sourceKind}`,
          path: ["edges", index, "from"],
        });
      }
      const targetKind = nodeKinds.get(edge.to);
      if (targetKind !== undefined && targetKind !== expectedKinds.to) {
        context.addIssue({
          code: "custom",
          message: `${edge.type} edge target must be a ${expectedKinds.to} node, not ${targetKind}`,
          path: ["edges", index, "to"],
        });
      }
      if (edge.commitSha !== snapshot.source.commitSha) {
        context.addIssue({
          code: "custom",
          message: "edge commitSha must match source.commitSha",
          path: ["edges", index, "commitSha"],
        });
      }
      if (edge.projectionId !== snapshot.source.projectionId) {
        context.addIssue({
          code: "custom",
          message: "edge projectionId must match source.projectionId",
          path: ["edges", index, "projectionId"],
        });
      }
      edgeIds.add(edge.id);
    }
  });

export type GraphSnapshotContract = z.infer<typeof GraphSnapshotSchema>;
export type GraphNodeContract = z.infer<typeof GraphNodeSchema>;
export type ConceptNodeContract = z.infer<typeof ConceptNodeSchema>;
export type SourceNodeContract = z.infer<typeof SourceNodeSchema>;
export type GraphEdgeContract = z.infer<typeof GraphEdgeSchema>;
