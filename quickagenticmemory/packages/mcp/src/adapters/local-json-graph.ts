import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { GatewayError } from "../errors.js";
import type { GraphSnapshot } from "../schemas.js";
import type {
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
  Backlink,
} from "../types.js";
import type { ConceptNode } from "../schemas.js";
import { MemoryGraphAdapter } from "./memory-graph.js";

export class LocalJsonGraphAdapter implements GraphReadAdapter {
  public readonly kind = "local-json";
  readonly #filePath: string;
  #delegate: MemoryGraphAdapter | undefined;

  public constructor(filePath: string) {
    this.#filePath = resolve(filePath);
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
    try {
      const raw = await readFile(this.#filePath, "utf8");
      this.#delegate = new MemoryGraphAdapter(JSON.parse(raw) as unknown);
      return this.#delegate;
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new GatewayError(`Local graph snapshot could not be loaded: ${detail}`, "adapter_error");
    }
  }
}
