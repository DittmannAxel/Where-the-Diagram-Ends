import type { ConceptNode, GraphEdge, GraphSnapshot, ResponseFormat, SourceNode } from "./schemas.js";

export interface Page<T> {
  readonly total: number;
  readonly count: number;
  readonly offset: number;
  readonly items: readonly T[];
  readonly has_more: boolean;
  readonly next_offset: number | null;
}

export interface BrowseIndexQuery {
  readonly directory: string;
  readonly types?: readonly string[];
  readonly tags?: readonly string[];
  readonly limit: number;
  readonly offset: number;
}

export interface ResolvedConcept {
  readonly concept: ConceptNode;
  readonly score: number;
  readonly matched_terms: readonly string[];
  readonly matched_fields: readonly string[];
}

export interface ResolveConceptsQuery {
  readonly terms: readonly string[];
  readonly types?: readonly string[];
  readonly tags?: readonly string[];
  readonly limit: number;
  readonly offset: number;
}

export type Direction = "incoming" | "outgoing" | "both";

export interface NeighborNode {
  readonly concept: ConceptNode;
  readonly distance: number;
}

export interface NeighborResult {
  readonly root: ConceptNode;
  readonly nodes: readonly NeighborNode[];
  readonly edges: readonly GraphEdge[];
  readonly truncated: boolean;
}

export interface NeighborsQuery {
  readonly conceptId: string;
  readonly maxHops: number;
  readonly direction: Direction;
  readonly edgeTypes?: readonly string[];
  readonly limit: number;
}

export interface Backlink {
  readonly source: ConceptNode;
  readonly edge: GraphEdge;
}

export interface BacklinksQuery {
  readonly conceptId: string;
  readonly edgeTypes?: readonly string[];
  readonly limit: number;
  readonly offset: number;
}

export interface PathStep {
  readonly concept: ConceptNode;
  readonly via_edge: GraphEdge | null;
}

export interface PathResult {
  readonly found: boolean;
  readonly hop_count: number | null;
  readonly steps: readonly PathStep[];
}

export interface FindPathQuery {
  readonly fromId: string;
  readonly toId: string;
  readonly maxHops: number;
  readonly direction: "outgoing" | "both";
  readonly edgeTypes?: readonly string[];
}

export interface ProvenanceResult {
  readonly concept: ConceptNode;
  readonly snapshot: GraphSnapshot["source"];
  readonly originating_edges: readonly GraphEdge[];
  readonly source_nodes: readonly SourceNode[];
}

export interface DocumentReadResult {
  readonly path: string;
  readonly commit_sha: string;
  readonly content: string;
  readonly source_url: string | null;
}

export interface ReadConceptResult {
  readonly concept: ConceptNode;
  readonly document: DocumentReadResult;
  readonly truncated: boolean;
  readonly original_characters: number;
}

export interface WikiUpdateProposal {
  readonly proposal_id: string;
  readonly status: "draft" | "submitted";
  readonly target_path: string;
  readonly base_commit_sha: string;
  readonly proposal_url: string | null;
}

export interface GraphReadAdapter {
  readonly kind: string;
  acquireSnapshot(): Promise<GraphSnapshotView>;
  getSnapshot(): Promise<GraphSnapshot>;
  browseIndex(query: BrowseIndexQuery): Promise<Page<ConceptNode>>;
  resolveConcepts(query: ResolveConceptsQuery): Promise<Page<ResolvedConcept>>;
  getNeighbors(query: NeighborsQuery): Promise<NeighborResult>;
  getBacklinks(query: BacklinksQuery): Promise<Page<Backlink>>;
  findPath(query: FindPathQuery): Promise<PathResult>;
  traceProvenance(conceptId: string): Promise<ProvenanceResult>;
}

export interface GraphSnapshotView {
  readonly snapshot: GraphSnapshot;
  readonly graph: GraphReadAdapter;
}

export interface ContentReadAdapter {
  readonly kind: string;
  readonly pathScope: "bundle" | "repository";
  readMarkdown(path: string, commitSha: string): Promise<DocumentReadResult>;
}

export interface ProposalAdapter {
  readonly kind: string;
  propose(input: {
    readonly conceptId?: string;
    readonly targetPath: string;
    readonly title: string;
    readonly rationale: string;
    readonly markdown: string;
    readonly baseCommitSha: string;
  }): Promise<WikiUpdateProposal>;
}

export interface GatewayAdapters {
  readonly graph: GraphReadAdapter;
  readonly content: ContentReadAdapter;
  readonly proposals?: ProposalAdapter;
}

export interface ToolResponseOptions {
  readonly responseFormat: ResponseFormat;
}
