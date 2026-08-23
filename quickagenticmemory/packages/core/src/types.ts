import { GRAPH_SCHEMA_VERSION } from "./qam-graph-contract.js";

export const OKF_VERSION = "0.2" as const;
export { GRAPH_SCHEMA_VERSION };

export type Frontmatter = Record<string, unknown>;
export type DocumentKind = "concept" | "index" | "log";
export type DiagnosticSeverity = "error" | "warning" | "info";

export interface Diagnostic {
  severity: DiagnosticSeverity;
  code: string;
  message: string;
  path: string;
  line?: number;
  column?: number;
}

export interface MarkdownLink {
  label: string;
  target: string;
  line?: number;
  column?: number;
}

export interface ParsedDocument {
  kind: DocumentKind;
  path: string;
  conceptId?: string;
  frontmatter: Frontmatter;
  hasFrontmatter: boolean;
  bodyLineOffset: number;
  body: string;
  raw: string;
  contentHash: string;
  links: MarkdownLink[];
}

export interface KnowledgeBundle {
  root: string;
  documents: ParsedDocument[];
  diagnostics: Diagnostic[];
  okfVersion?: string;
}

export interface ValidationSummary {
  errors: number;
  warnings: number;
  info: number;
}

export interface BundleValidationResult {
  bundle: KnowledgeBundle;
  diagnostics: Diagnostic[];
  summary: ValidationSummary;
  valid: boolean;
}

export type GraphNodeKind = "Concept" | "Tag" | "Source" | "Term";
export type GraphEdgeType = "LINKS_TO" | "HAS_TAG" | "DERIVED_FROM" | "ALIASED_AS";

export interface GraphNodeBase {
  id: string;
  kind: GraphNodeKind;
  title: string;
  type: string;
  tags: string[];
  aliases: string[];
  projectionId: string;
  commitSha: string;
}

export interface ConceptNode extends GraphNodeBase {
  kind: "Concept";
  path: string;
  repositoryPath: string;
  conceptId: string;
  summary?: string;
  resource?: string;
  status: "draft" | "stable" | "deprecated";
  contentHash: string;
  sourceUrl?: string;
}

export interface TagNode extends GraphNodeBase {
  kind: "Tag";
  type: "Tag";
  normalizedValue: string;
}

export interface SourceNode extends GraphNodeBase {
  kind: "Source";
  type: "Source";
  resource: string;
  sourceIds: string[];
  authors: string[];
  usageCounts: number[];
  lastModified?: string;
}

export interface TermNode extends GraphNodeBase {
  kind: "Term";
  type: "Term";
  normalizedValue: string;
}

export type GraphNode = ConceptNode | TagNode | SourceNode | TermNode;

export interface GraphEdge {
  id: string;
  from: string;
  to: string;
  type: GraphEdgeType;
  projectionId: string;
  commitSha: string;
  label?: string;
  sourcePath?: string;
}

export interface ProjectionSource {
  repository: string;
  projectionId: string;
  commitSha: string;
  generatedAt: string;
}

export interface ProjectionManifest {
  schemaVersion: typeof GRAPH_SCHEMA_VERSION;
  okfVersion: string;
  projector: {
    name: "@quick-agentic-memory/core";
    version: string;
  };
  source: ProjectionSource;
  bundle: {
    pathInRepository: string;
    contentDigest: string;
    files: Array<{ path: string; sha256: string }>;
  };
  counts: {
    documents: number;
    concepts: number;
    nodes: number;
    edges: number;
  };
}

export interface ProjectedGraph {
  schemaVersion: typeof GRAPH_SCHEMA_VERSION;
  okfVersion: string;
  source: ProjectionSource;
  nodes: GraphNode[];
  edges: GraphEdge[];
}

export interface ProjectionOptions {
  gitSha: string;
  generatedAt: string;
  repository?: string;
  pathInRepository?: string;
  sourceBaseUrl?: string;
  strict?: boolean;
}

export interface ProjectionOutput {
  graph: ProjectedGraph;
  manifest: ProjectionManifest;
  validation: BundleValidationResult;
}

/** Flat, stable OneLake ingestion row. Array-valued graph properties are JSON strings. */
export interface FlatNodeRow {
  id: string;
  kind: GraphNodeKind;
  title: string;
  type: string;
  path: string | null;
  repositoryPath: string | null;
  conceptId: string | null;
  tagsJson: string;
  aliasesJson: string;
  projectionId: string;
  commitSha: string;
  repository: string;
  projectionGeneratedAt: string;
  okfVersion: string;
  summary: string | null;
  resource: string | null;
  status: string | null;
  contentHash: string | null;
  sourceUrl: string | null;
  normalizedValue: string | null;
  sourceIdsJson: string;
  authorsJson: string;
  usageCountsJson: string;
  lastModified: string | null;
}

/** Snapshot-level values copied onto every QamNode row for Fabric-only provenance reads. */
export interface FlatNodeProjectionMetadata {
  repository: string;
  projectionGeneratedAt: string;
  okfVersion: string;
}

/** Flat, stable OneLake ingestion row for a QamEdge table. */
export interface FlatEdgeRow {
  id: string;
  from: string;
  to: string;
  type: GraphEdgeType;
  projectionId: string;
  commitSha: string;
  label: string | null;
  sourcePath: string | null;
}

export interface GitMetadata {
  gitSha: string;
  generatedAt: string;
  repository: string;
  pathInRepository: string;
}
