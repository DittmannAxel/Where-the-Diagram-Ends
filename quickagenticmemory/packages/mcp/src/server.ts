import { McpServer, type CallToolResult } from "@modelcontextprotocol/server";
import * as z from "zod/v4";

import { publicErrorMessage, redactedErrorForLog } from "./errors.js";
import { KnowledgeService } from "./knowledge-service.js";
import {
  BacklinksInputSchema,
  BrowseIndexInputSchema,
  ConceptNodeSchema,
  FindPathInputSchema,
  GraphEdgeSchema,
  NeighborsInputSchema,
  PaginationOutputShape,
  ProposeWikiUpdateInputSchema,
  ReadConceptsInputSchema,
  ResolveConceptsInputSchema,
  ProjectionIdSchema,
  GitShaSchema,
  SourceNodeSchema,
  type ResponseFormat,
  TraceProvenanceInputSchema,
} from "./schemas.js";
import type { GatewayAdapters, Page } from "./types.js";

const READ_ONLY_ANNOTATIONS = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
} as const;

const PageMetadataSchema = z.object(PaginationOutputShape).strict();
const BrowseOutputSchema = PageMetadataSchema.extend({
  repository: z.string(),
  commit_sha: z.string(),
  concepts: z.array(ConceptNodeSchema),
}).strict();
const ResolvedConceptSchema = z
  .object({
    concept: ConceptNodeSchema,
    score: z.number().nonnegative(),
    matched_terms: z.array(z.string()),
    matched_fields: z.array(z.string()),
  })
  .strict();
const ResolveOutputSchema = PageMetadataSchema.extend({
  repository: z.string(),
  commit_sha: z.string(),
  matches: z.array(ResolvedConceptSchema),
}).strict();
const NeighborsOutputSchema = z
  .object({
    root: ConceptNodeSchema,
    nodes: z.array(z.object({ concept: ConceptNodeSchema, distance: z.number().int().positive() }).strict()),
    edges: z.array(GraphEdgeSchema),
    truncated: z.boolean(),
  })
  .strict();
const BacklinkSchema = z.object({ source: ConceptNodeSchema, edge: GraphEdgeSchema }).strict();
const BacklinksOutputSchema = PageMetadataSchema.extend({
  target: ConceptNodeSchema,
  backlinks: z.array(BacklinkSchema),
}).strict();
const PathOutputSchema = z
  .object({
    found: z.boolean(),
    hop_count: z.number().int().nonnegative().nullable(),
    steps: z.array(z.object({ concept: ConceptNodeSchema, via_edge: GraphEdgeSchema.nullable() }).strict()),
  })
  .strict();
const ReadConceptsOutputSchema = z
  .object({
    repository: z.string(),
    commit_sha: z.string(),
    documents: z.array(
      z
        .object({
          concept: ConceptNodeSchema,
          document: z
            .object({
              path: z.string(),
              commit_sha: z.string(),
              content: z.string(),
              source_url: z.string().nullable(),
            })
            .strict(),
          truncated: z.boolean(),
          original_characters: z.number().int().nonnegative(),
        })
        .strict(),
    ),
  })
  .strict();
const ProvenanceOutputSchema = z
  .object({
    concept: ConceptNodeSchema,
    snapshot: z
      .object({
        repository: z.string(),
        projectionId: ProjectionIdSchema,
        commitSha: GitShaSchema,
        generatedAt: z.string(),
      })
      .strict(),
    originating_edges: z.array(GraphEdgeSchema),
    source_nodes: z.array(SourceNodeSchema),
  })
  .strict();
const ProposalOutputSchema = z
  .object({
    proposal_id: z.string(),
    status: z.enum(["draft", "submitted"]),
    target_path: z.string(),
    base_commit_sha: z.string(),
    proposal_url: z.string().nullable(),
  })
  .strict();

function textResult(output: unknown, responseFormat: ResponseFormat, markdown: () => string): CallToolResult {
  return {
    content: [{ type: "text", text: responseFormat === "json" ? JSON.stringify(output, null, 2) : markdown() }],
    structuredContent: output,
  };
}

function errorResult(error: unknown): CallToolResult {
  console.error("Quick Agentic Memory tool error:", redactedErrorForLog(error));
  return { isError: true, content: [{ type: "text", text: publicErrorMessage(error) }] };
}

function pageFields<T>(result: Page<T>): Omit<Page<T>, "items"> {
  return {
    total: result.total,
    count: result.count,
    offset: result.offset,
    has_more: result.has_more,
    next_offset: result.next_offset,
  };
}

function conceptLine(concept: { readonly title: string; readonly id: string; readonly path: string }): string {
  return `- **${concept.title}** (\`${concept.id}\`) — \`${concept.path}\``;
}

export function createGatewayServer(adapters: GatewayAdapters): McpServer {
  const service = new KnowledgeService(adapters);
  const server = new McpServer(
    { name: "quick-agentic-memory-mcp-server", version: "0.1.0" },
    {
      instructions:
        "Use resolve_concepts before graph traversal. Read source Markdown with read_concepts only after identifying concepts. All reads are pinned to the immutable graph commit SHA; no raw graph query is exposed.",
    },
  );

  server.registerTool(
    "browse_index",
    {
      title: "Browse knowledge index",
      description:
        "List Markdown-backed concepts under a safe repository-relative directory, optionally filtered by exact type and tags. Returns stable paths and concept IDs with offset pagination; it never reads document bodies or modifies knowledge.",
      inputSchema: BrowseIndexInputSchema,
      outputSchema: BrowseOutputSchema,
      annotations: READ_ONLY_ANNOTATIONS,
    },
    async ({ directory, types, tags, limit, offset, response_format }) => {
      try {
        const { snapshot, graph } = await adapters.graph.acquireSnapshot();
        const result = await graph.browseIndex({ directory, ...(types === undefined ? {} : { types }), ...(tags === undefined ? {} : { tags }), limit, offset });
        const output = {
          repository: snapshot.source.repository,
          commit_sha: snapshot.source.commitSha,
          ...pageFields(result),
          concepts: result.items,
        };
        return textResult(output, response_format, () =>
          [`# Knowledge index: ${directory}`, "", ...result.items.map(conceptLine), "", `${result.count} of ${result.total} concepts.`].join("\n"),
        );
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "resolve_concepts",
    {
      title: "Resolve concepts",
      description:
        "Resolve natural-language terms against concept titles, aliases, tags, types, paths, and summaries. Results are deterministically ranked and paginated. Use returned concept IDs with traversal or read tools.",
      inputSchema: ResolveConceptsInputSchema,
      outputSchema: ResolveOutputSchema,
      annotations: READ_ONLY_ANNOTATIONS,
    },
    async ({ terms, types, tags, limit, offset, response_format }) => {
      try {
        const { snapshot, graph } = await adapters.graph.acquireSnapshot();
        const result = await graph.resolveConcepts({ terms, ...(types === undefined ? {} : { types }), ...(tags === undefined ? {} : { tags }), limit, offset });
        const output = {
          repository: snapshot.source.repository,
          commit_sha: snapshot.source.commitSha,
          ...pageFields(result),
          matches: result.items,
        };
        return textResult(output, response_format, () =>
          [
            `# Concept matches for ${terms.map((term) => `“${term}”`).join(", ")}`,
            "",
            ...result.items.map((match) => `${conceptLine(match.concept)} — score ${match.score}; matched ${match.matched_fields.join(", ")}`),
          ].join("\n"),
        );
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "get_neighbors",
    {
      title: "Get concept neighbors",
      description:
        "Traverse one or two graph hops from a resolved concept ID in incoming, outgoing, or both directions. Optional edge-type filters and a hard result limit keep context bounded.",
      inputSchema: NeighborsInputSchema,
      outputSchema: NeighborsOutputSchema,
      annotations: READ_ONLY_ANNOTATIONS,
    },
    async ({ concept_id, max_hops, direction, edge_types, limit, response_format }) => {
      try {
        const output = await adapters.graph.getNeighbors({
          conceptId: concept_id,
          maxHops: max_hops,
          direction,
          ...(edge_types === undefined ? {} : { edgeTypes: edge_types }),
          limit,
        });
        return textResult(output, response_format, () =>
          [
            `# Neighbors of ${output.root.title}`,
            "",
            ...output.nodes.map((entry) => `${conceptLine(entry.concept)} — ${entry.distance} hop(s)`),
            "",
            `Edges: ${output.edges.length}; truncated: ${String(output.truncated)}.`,
          ].join("\n"),
        );
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "get_backlinks",
    {
      title: "Get concept backlinks",
      description:
        "List concepts with incoming graph edges to a resolved concept ID. Results include the originating concept and exact edge provenance, with optional edge-type filtering and pagination.",
      inputSchema: BacklinksInputSchema,
      outputSchema: BacklinksOutputSchema,
      annotations: READ_ONLY_ANNOTATIONS,
    },
    async ({ concept_id, edge_types, limit, offset, response_format }) => {
      try {
        const { snapshot, graph } = await adapters.graph.acquireSnapshot();
        const result = await graph.getBacklinks({ conceptId: concept_id, ...(edge_types === undefined ? {} : { edgeTypes: edge_types }), limit, offset });
        const target = snapshot.nodes.find((node) => node.kind === "Concept" && node.id === concept_id);
        if (target === undefined) return errorResult(new Error("Target concept unexpectedly missing"));
        const output = { target, ...pageFields(result), backlinks: result.items };
        return textResult(output, response_format, () =>
          [
            `# Backlinks to ${target.title}`,
            "",
            ...result.items.map((entry) => `${conceptLine(entry.source)} — \`${entry.edge.type}\``),
            "",
            `${result.count} of ${result.total} backlinks.`,
          ].join("\n"),
        );
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "find_path",
    {
      title: "Find graph path",
      description:
        "Find the shortest path of at most six hops between two resolved concept IDs. Traversal is outgoing by default and may be broadened to both directions; no arbitrary graph query is accepted.",
      inputSchema: FindPathInputSchema,
      outputSchema: PathOutputSchema,
      annotations: READ_ONLY_ANNOTATIONS,
    },
    async ({ from_id, to_id, max_hops, direction, edge_types, response_format }) => {
      try {
        const output = await adapters.graph.findPath({
          fromId: from_id,
          toId: to_id,
          maxHops: max_hops,
          direction,
          ...(edge_types === undefined ? {} : { edgeTypes: edge_types }),
        });
        return textResult(output, response_format, () =>
          output.found
            ? ["# Shortest graph path", "", ...output.steps.map((step) => conceptLine(step.concept)), "", `Hops: ${output.hop_count}.`].join("\n")
            : "No path was found within the requested hop limit.",
        );
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "read_concepts",
    {
      title: "Read concept Markdown",
      description:
        "Read up to ten original Markdown documents for resolved concept IDs at the immutable graph commit SHA. Paths and SHAs are validated; branch names, traversal paths, and non-Markdown content are rejected. Responses have per-document and aggregate character limits.",
      inputSchema: ReadConceptsInputSchema,
      outputSchema: ReadConceptsOutputSchema,
      annotations: READ_ONLY_ANNOTATIONS,
    },
    async ({ concept_ids, commit_sha, max_characters_per_document, response_format }) => {
      try {
        const output = await service.readConcepts(concept_ids, commit_sha, max_characters_per_document);
        return textResult(output, response_format, () =>
          output.documents
            .map(
              (entry) =>
                `# ${entry.concept.title}\n\nSource: \`${entry.document.path}\` at \`${entry.document.commit_sha}\`\n\n${entry.document.content}${entry.truncated ? "\n\n_[truncated]_" : ""}`,
            )
            .join("\n\n---\n\n"),
        );
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  server.registerTool(
    "trace_provenance",
    {
      title: "Trace concept provenance",
      description:
        "Return the graph snapshot source, immutable commit, concept path, and graph edges that establish a concept's provenance. Use this to audit where an answer came from before reading the source Markdown.",
      inputSchema: TraceProvenanceInputSchema,
      outputSchema: ProvenanceOutputSchema,
      annotations: READ_ONLY_ANNOTATIONS,
    },
    async ({ concept_id, response_format }) => {
      try {
        const output = await adapters.graph.traceProvenance(concept_id);
        return textResult(output, response_format, () =>
          [
            `# Provenance: ${output.concept.title}`,
            "",
            `- Repository: ${output.snapshot.repository}`,
            `- Commit: \`${output.snapshot.commitSha}\``,
            `- Path: \`${output.concept.path}\``,
            `- Originating edges: ${output.originating_edges.length}`,
            `- Source nodes: ${output.source_nodes.length}`,
          ].join("\n"),
        );
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  if (adapters.proposals !== undefined) {
    server.registerTool(
      "propose_wiki_update",
      {
        title: "Propose wiki update",
        description:
          "Submit a reviewable Markdown update proposal against the current immutable graph commit. This optional write-capable tool is absent unless the server operator explicitly enables and configures a proposal endpoint.",
        inputSchema: ProposeWikiUpdateInputSchema,
        outputSchema: ProposalOutputSchema,
        annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
      },
      async ({ concept_id, target_path, title, rationale, markdown, base_commit_sha }) => {
        try {
          const output = await service.proposeWikiUpdate({
            ...(concept_id === undefined ? {} : { conceptId: concept_id }),
            targetPath: target_path,
            title,
            rationale,
            markdown,
            baseCommitSha: base_commit_sha,
          });
          return textResult(output, "markdown", () =>
            `Proposal \`${output.proposal_id}\` is ${output.status} for \`${output.target_path}\`.`,
          );
        } catch (error) {
          return errorResult(error);
        }
      },
    );
  }

  return server;
}
