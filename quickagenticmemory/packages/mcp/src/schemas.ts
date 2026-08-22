import * as z from "zod/v4";

import {
  ConceptIdSchema,
  ConceptNodeSchema,
  EdgeTypeSchema,
  GitShaSchema,
  GRAPH_CONTRACT_LIMITS,
  GRAPH_CONTRACT_PATTERNS,
  GraphEdgeSchema,
  GraphNodeSchema,
  GraphSnapshotSchema,
  RepoPathSchema,
  SourceNodeSchema,
} from "./qam-graph-contract.js";

export {
  ConceptIdSchema,
  ConceptNodeSchema,
  EdgeTypeSchema,
  GitShaSchema,
  GRAPH_CONTRACT_LIMITS,
  GRAPH_SCHEMA_VERSION,
  GraphEdgeSchema,
  GraphNodeSchema,
  GraphSnapshotSchema,
  ProjectionIdSchema,
  RepoPathSchema,
  SourceNodeSchema,
  TagNodeSchema,
  TermNodeSchema,
} from "./qam-graph-contract.js";

export const MAX_PAGE_SIZE = 100;
export const DEFAULT_PAGE_SIZE = 20;
export const MAX_RESPONSE_CHARACTERS = 100_000;
export const MAX_GRAPH_NODES = GRAPH_CONTRACT_LIMITS.graphNodes;
export const MAX_GRAPH_EDGES = GRAPH_CONTRACT_LIMITS.graphEdges;

export const DirectoryPathSchema = z
  .string()
  .min(1)
  .max(GRAPH_CONTRACT_LIMITS.path)
  .default(".")
  .refine(
    (value) => value === "." || GRAPH_CONTRACT_PATTERNS.repositoryPath.test(value),
    "directory must be '.' or a safe repository-relative path",
  );

export const ResponseFormatSchema = z.enum(["markdown", "json"]).default("markdown");

export const PaginationInputShape = {
  limit: z.number().int().min(1).max(MAX_PAGE_SIZE).default(DEFAULT_PAGE_SIZE),
  offset: z.number().int().min(0).max(1_000_000).default(0),
};

export const PaginationOutputShape = {
  total: z.number().int().nonnegative(),
  count: z.number().int().nonnegative(),
  offset: z.number().int().nonnegative(),
  has_more: z.boolean(),
  next_offset: z.number().int().nonnegative().nullable(),
};

export const BrowseIndexInputSchema = z
  .object({
    directory: DirectoryPathSchema.describe("Repository-relative directory to browse; use '.' for the knowledge root"),
    types: z.array(z.string().min(1).max(100)).max(20).optional().describe("Optional exact concept-type filter"),
    tags: z.array(z.string().min(1).max(100)).max(20).optional().describe("Optional tags; every supplied tag must match"),
    ...PaginationInputShape,
    response_format: ResponseFormatSchema,
  })
  .strict();

export const ResolveConceptsInputSchema = z
  .object({
    terms: z
      .array(z.string().trim().min(2).max(200))
      .min(1)
      .max(20)
      .describe("Terms, titles, aliases, or tags to resolve; results are ranked across all terms"),
    types: z.array(z.string().min(1).max(100)).max(20).optional(),
    tags: z.array(z.string().min(1).max(100)).max(20).optional(),
    ...PaginationInputShape,
    response_format: ResponseFormatSchema,
  })
  .strict();

export const NeighborsInputSchema = z
  .object({
    concept_id: ConceptIdSchema,
    max_hops: z.number().int().min(1).max(2).default(1),
    direction: z.enum(["incoming", "outgoing", "both"]).default("both"),
    edge_types: z.array(EdgeTypeSchema).max(20).optional(),
    limit: z.number().int().min(1).max(100).default(50),
    response_format: ResponseFormatSchema,
  })
  .strict();

export const BacklinksInputSchema = z
  .object({
    concept_id: ConceptIdSchema,
    edge_types: z.array(EdgeTypeSchema).max(20).optional(),
    ...PaginationInputShape,
    response_format: ResponseFormatSchema,
  })
  .strict();

export const FindPathInputSchema = z
  .object({
    from_id: ConceptIdSchema,
    to_id: ConceptIdSchema,
    max_hops: z.number().int().min(1).max(6).default(4),
    direction: z.enum(["outgoing", "both"]).default("outgoing"),
    edge_types: z.array(EdgeTypeSchema).max(20).optional(),
    response_format: ResponseFormatSchema,
  })
  .strict();

export const ReadConceptsInputSchema = z
  .object({
    concept_ids: z.array(ConceptIdSchema).min(1).max(10),
    commit_sha: GitShaSchema.optional().describe("Immutable full Git SHA; defaults to the graph snapshot SHA"),
    max_characters_per_document: z.number().int().min(1_000).max(50_000).default(20_000),
    response_format: ResponseFormatSchema,
  })
  .strict();

export const TraceProvenanceInputSchema = z
  .object({
    concept_id: ConceptIdSchema,
    response_format: ResponseFormatSchema,
  })
  .strict();

export const ProposeWikiUpdateInputSchema = z
  .object({
    concept_id: ConceptIdSchema.optional(),
    target_path: RepoPathSchema,
    title: z.string().trim().min(3).max(200),
    rationale: z.string().trim().min(10).max(2_000),
    markdown: z.string().min(1).max(50_000),
    base_commit_sha: GitShaSchema,
  })
  .strict();

export type GraphSnapshot = z.infer<typeof GraphSnapshotSchema>;
export type GraphNode = z.infer<typeof GraphNodeSchema>;
export type ConceptNode = z.infer<typeof ConceptNodeSchema>;
export type SourceNode = z.infer<typeof SourceNodeSchema>;
export type GraphEdge = z.infer<typeof GraphEdgeSchema>;
export type ResponseFormat = z.infer<typeof ResponseFormatSchema>;
