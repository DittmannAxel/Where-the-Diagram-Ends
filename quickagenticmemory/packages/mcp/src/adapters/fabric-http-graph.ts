import type { ConceptNode, GraphSnapshot } from "../schemas.js";
import type {
  Backlink,
  BacklinksQuery,
  BrowseIndexQuery,
  FindPathQuery,
  GraphReadAdapter,
  GraphSnapshotView,
  NeighborResult,
  NeighborsQuery,
  Page,
  PathResult,
  ProvenanceResult,
  ResolveConceptsQuery,
  ResolvedConcept,
} from "../types.js";
import { bearerHeaders, fetchWithTimeout, validateRemoteUrl } from "./http-utils.js";
import { MemoryGraphAdapter } from "./memory-graph.js";

export interface FabricHttpGraphAdapterOptions {
  readonly snapshotUrl: string;
  readonly token?: string;
  readonly timeoutMs?: number;
  readonly allowInsecureLocalhost?: boolean;
}

/**
 * Adapter for a curated Fabric projection endpoint. The endpoint returns the
 * versioned graph snapshot contract; no raw GQL or arbitrary SQL reaches MCP clients.
 */
export class FabricHttpGraphAdapter implements GraphReadAdapter {
  public readonly kind = "fabric-http";
  readonly #url: URL;
  readonly #token: string | undefined;
  readonly #timeoutMs: number;
  #delegate: MemoryGraphAdapter | undefined;

  public constructor(options: FabricHttpGraphAdapterOptions) {
    this.#url = validateRemoteUrl(options.snapshotUrl, options.allowInsecureLocalhost ?? false);
    this.#token = options.token;
    this.#timeoutMs = options.timeoutMs ?? 15_000;
  }

  public async getSnapshot(): Promise<GraphSnapshot> {
    return (await this.#load()).getSnapshot();
  }

  public async acquireSnapshot(): Promise<GraphSnapshotView> {
    return (await this.#load()).acquireSnapshot();
  }

  public async browseIndex(query: BrowseIndexQuery): Promise<Page<ConceptNode>> {
    return (await this.#load()).browseIndex(query);
  }

  public async resolveConcepts(query: ResolveConceptsQuery): Promise<Page<ResolvedConcept>> {
    return (await this.#load()).resolveConcepts(query);
  }

  public async getNeighbors(query: NeighborsQuery): Promise<NeighborResult> {
    return (await this.#load()).getNeighbors(query);
  }

  public async getBacklinks(query: BacklinksQuery): Promise<Page<Backlink>> {
    return (await this.#load()).getBacklinks(query);
  }

  public async findPath(query: FindPathQuery): Promise<PathResult> {
    return (await this.#load()).findPath(query);
  }

  public async traceProvenance(conceptId: string): Promise<ProvenanceResult> {
    return (await this.#load()).traceProvenance(conceptId);
  }

  async #load(): Promise<MemoryGraphAdapter> {
    if (this.#delegate !== undefined) return this.#delegate;
    const response = await fetchWithTimeout(
      this.#url,
      { headers: { Accept: "application/json", ...bearerHeaders(this.#token) } },
      this.#timeoutMs,
      "Fabric graph projection endpoint",
    );
    this.#delegate = new MemoryGraphAdapter((await response.json()) as unknown);
    return this.#delegate;
  }
}
