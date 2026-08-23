import { GatewayError } from "../errors.js";
import {
  GraphSnapshotSchema,
  type ConceptNode,
  type GraphEdge,
  type GraphNode,
  type GraphSnapshot,
  type SourceNode,
} from "../schemas.js";
import type {
  Backlink,
  BacklinksQuery,
  BrowseIndexQuery,
  FindPathQuery,
  GraphReadAdapter,
  GraphSnapshotView,
  NeighborNode,
  NeighborResult,
  NeighborsQuery,
  Page,
  PathResult,
  ProvenanceResult,
  ResolveConceptsQuery,
  ResolvedConcept,
} from "../types.js";

function normalize(value: string): string {
  return value.normalize("NFKC").toLocaleLowerCase("en-US").trim();
}

function includesAll(haystack: readonly string[], needles: readonly string[] | undefined): boolean {
  if (needles === undefined || needles.length === 0) return true;
  const values = new Set(haystack.map(normalize));
  return needles.every((needle) => values.has(normalize(needle)));
}

function page<T>(items: readonly T[], limit: number, offset: number): Page<T> {
  const selected = items.slice(offset, offset + limit);
  const nextOffset = offset + selected.length;
  return {
    total: items.length,
    count: selected.length,
    offset,
    items: selected,
    has_more: nextOffset < items.length,
    next_offset: nextOffset < items.length ? nextOffset : null,
  };
}

function edgeAllowed(edge: GraphEdge, edgeTypes: readonly string[] | undefined): boolean {
  return edgeTypes === undefined || edgeTypes.length === 0 || edgeTypes.some((value) => normalize(value) === normalize(edge.type));
}

interface Traversal {
  readonly nextId: string;
  readonly edge: GraphEdge;
}

export class MemoryGraphAdapter implements GraphReadAdapter {
  public readonly kind = "memory";
  readonly #snapshot: GraphSnapshot;
  readonly #nodes: ReadonlyMap<string, GraphNode>;
  readonly #outgoing: ReadonlyMap<string, readonly GraphEdge[]>;
  readonly #incoming: ReadonlyMap<string, readonly GraphEdge[]>;

  public constructor(snapshot: unknown) {
    this.#snapshot = GraphSnapshotSchema.parse(snapshot);
    this.#nodes = new Map(this.#snapshot.nodes.map((node) => [node.id, node]));

    const outgoing = new Map<string, GraphEdge[]>();
    const incoming = new Map<string, GraphEdge[]>();
    for (const edge of this.#snapshot.edges) {
      outgoing.set(edge.from, [...(outgoing.get(edge.from) ?? []), edge]);
      incoming.set(edge.to, [...(incoming.get(edge.to) ?? []), edge]);
    }
    this.#outgoing = outgoing;
    this.#incoming = incoming;
  }

  public async getSnapshot(): Promise<GraphSnapshot> {
    return this.#snapshot;
  }

  public async acquireSnapshot(): Promise<GraphSnapshotView> {
    return { snapshot: this.#snapshot, graph: this };
  }

  public async browseIndex(query: BrowseIndexQuery): Promise<Page<ConceptNode>> {
    const directory = query.directory === "." ? "" : `${query.directory}/`;
    const types = query.types?.map(normalize);
    const matches = this.#snapshot.nodes
      .filter((node): node is ConceptNode => node.kind === "Concept")
      .filter((node) => node.path.startsWith(directory))
      .filter((node) => types === undefined || types.includes(normalize(node.type)))
      .filter((node) => includesAll(node.tags, query.tags))
      .toSorted((left, right) => left.path.localeCompare(right.path) || left.title.localeCompare(right.title));
    return page(matches, query.limit, query.offset);
  }

  public async resolveConcepts(query: ResolveConceptsQuery): Promise<Page<ResolvedConcept>> {
    const terms = query.terms.map((original) => ({ original, normalized: normalize(original) }));
    const types = query.types?.map(normalize);
    const results: ResolvedConcept[] = [];

    for (const concept of this.#snapshot.nodes) {
      if (concept.kind !== "Concept") continue;
      if (types !== undefined && !types.includes(normalize(concept.type))) continue;
      if (!includesAll(concept.tags, query.tags)) continue;

      const title = normalize(concept.title);
      const aliases = concept.aliases.map(normalize);
      const tags = concept.tags.map(normalize);
      const type = normalize(concept.type);
      const summary = normalize(concept.summary ?? "");
      const path = normalize(concept.path);
      const matchedTerms: string[] = [];
      const matchedFields = new Set<string>();
      let score = 0;

      for (const term of terms) {
        let termScore = 0;
        if (title === term.normalized) {
          termScore = 100;
          matchedFields.add("title");
        } else if (aliases.includes(term.normalized)) {
          termScore = 90;
          matchedFields.add("aliases");
        } else if (tags.includes(term.normalized)) {
          termScore = 80;
          matchedFields.add("tags");
        } else if (type === term.normalized) {
          termScore = 70;
          matchedFields.add("type");
        } else if (title.startsWith(term.normalized) || aliases.some((alias) => alias.startsWith(term.normalized))) {
          termScore = 60;
          matchedFields.add(title.startsWith(term.normalized) ? "title" : "aliases");
        } else if (title.includes(term.normalized) || aliases.some((alias) => alias.includes(term.normalized))) {
          termScore = 40;
          matchedFields.add(title.includes(term.normalized) ? "title" : "aliases");
        } else if (path.includes(term.normalized)) {
          termScore = 20;
          matchedFields.add("path");
        } else if (summary.includes(term.normalized)) {
          termScore = 10;
          matchedFields.add("summary");
        }

        if (termScore > 0) {
          matchedTerms.push(term.original);
          score += termScore;
        }
      }

      if (score > 0) {
        results.push({ concept, score, matched_terms: matchedTerms, matched_fields: [...matchedFields].toSorted() });
      }
    }

    results.sort(
      (left, right) =>
        right.matched_terms.length - left.matched_terms.length ||
        right.score - left.score ||
        left.concept.title.localeCompare(right.concept.title),
    );
    return page(results, query.limit, query.offset);
  }

  public async getNeighbors(query: NeighborsQuery): Promise<NeighborResult> {
    const root = this.#requireConcept(query.conceptId);
    const visited = new Map<string, number>([[root.id, 0]]);
    const queue: string[] = [root.id];
    const nodes: NeighborNode[] = [];
    const selectedEdges = new Map<string, GraphEdge>();
    let truncated = false;

    while (queue.length > 0) {
      const currentId = queue.shift();
      if (currentId === undefined) break;
      const distance = visited.get(currentId);
      if (distance === undefined || distance >= query.maxHops) continue;

      for (const traversal of this.#traversals(currentId, query.direction, query.edgeTypes)) {
        selectedEdges.set(traversal.edge.id, traversal.edge);
        if (visited.has(traversal.nextId)) continue;
        if (nodes.length >= query.limit) {
          truncated = true;
          continue;
        }
        const nextDistance = distance + 1;
        visited.set(traversal.nextId, nextDistance);
        const concept = this.#requireConcept(traversal.nextId);
        nodes.push({ concept, distance: nextDistance });
        queue.push(traversal.nextId);
      }
    }

    const includedIds = new Set([root.id, ...nodes.map((entry) => entry.concept.id)]);
    const edges = [...selectedEdges.values()].filter((edge) => includedIds.has(edge.from) && includedIds.has(edge.to));
    return { root, nodes, edges, truncated };
  }

  public async getBacklinks(query: BacklinksQuery): Promise<Page<Backlink>> {
    this.#requireConcept(query.conceptId);
    const backlinks = (this.#incoming.get(query.conceptId) ?? [])
      .filter((edge) => edgeAllowed(edge, query.edgeTypes))
      .filter((edge) => this.#nodes.get(edge.from)?.kind === "Concept")
      .map((edge) => ({ source: this.#requireConcept(edge.from), edge }))
      .toSorted((left, right) => left.source.title.localeCompare(right.source.title));
    return page(backlinks, query.limit, query.offset);
  }

  public async findPath(query: FindPathQuery): Promise<PathResult> {
    const start = this.#requireConcept(query.fromId);
    this.#requireConcept(query.toId);
    if (query.fromId === query.toId) {
      return { found: true, hop_count: 0, steps: [{ concept: start, via_edge: null }] };
    }

    const queue: Array<{ id: string; distance: number }> = [{ id: query.fromId, distance: 0 }];
    const visited = new Set<string>([query.fromId]);
    const previous = new Map<string, { id: string; edge: GraphEdge }>();

    while (queue.length > 0) {
      const current = queue.shift();
      if (current === undefined) break;
      if (current.distance >= query.maxHops) continue;

      for (const traversal of this.#traversals(current.id, query.direction, query.edgeTypes)) {
        if (visited.has(traversal.nextId)) continue;
        visited.add(traversal.nextId);
        previous.set(traversal.nextId, { id: current.id, edge: traversal.edge });
        if (traversal.nextId === query.toId) {
          return this.#reconstructPath(query.fromId, query.toId, previous);
        }
        queue.push({ id: traversal.nextId, distance: current.distance + 1 });
      }
    }

    return { found: false, hop_count: null, steps: [] };
  }

  public async traceProvenance(conceptId: string): Promise<ProvenanceResult> {
    const concept = this.#requireConcept(conceptId);
    const sourceEdges = (this.#outgoing.get(conceptId) ?? []).filter(
      (edge) => edge.type === "DERIVED_FROM" && this.#nodes.get(edge.to)?.kind === "Source",
    );
    return {
      concept,
      snapshot: this.#snapshot.source,
      originating_edges: sourceEdges,
      source_nodes: sourceEdges.map((edge) => this.#nodes.get(edge.to)).filter((node): node is SourceNode => node?.kind === "Source"),
    };
  }

  #requireConcept(id: string): ConceptNode {
    const node = this.#nodes.get(id);
    if (node === undefined || node.kind !== "Concept") {
      throw new GatewayError(`Concept '${id}' was not found. Use resolve_concepts before traversing.`, "not_found");
    }
    return node;
  }

  #traversals(id: string, direction: "incoming" | "outgoing" | "both", edgeTypes: readonly string[] | undefined): Traversal[] {
    const traversals: Traversal[] = [];
    if (direction === "outgoing" || direction === "both") {
      for (const edge of this.#outgoing.get(id) ?? []) {
        if (edgeAllowed(edge, edgeTypes) && this.#nodes.get(edge.to)?.kind === "Concept") {
          traversals.push({ nextId: edge.to, edge });
        }
      }
    }
    if (direction === "incoming" || direction === "both") {
      for (const edge of this.#incoming.get(id) ?? []) {
        if (edgeAllowed(edge, edgeTypes) && this.#nodes.get(edge.from)?.kind === "Concept") {
          traversals.push({ nextId: edge.from, edge });
        }
      }
    }
    return traversals;
  }

  #reconstructPath(fromId: string, toId: string, previous: ReadonlyMap<string, { id: string; edge: GraphEdge }>): PathResult {
    const reversed: Array<{ id: string; edge: GraphEdge | null }> = [];
    let currentId = toId;
    while (currentId !== fromId) {
      const entry = previous.get(currentId);
      if (entry === undefined) {
        throw new GatewayError("The graph path could not be reconstructed.", "adapter_error");
      }
      reversed.push({ id: currentId, edge: entry.edge });
      currentId = entry.id;
    }
    reversed.push({ id: fromId, edge: null });
    reversed.reverse();
    return {
      found: true,
      hop_count: reversed.length - 1,
      steps: reversed.map((entry) => ({ concept: this.#requireConcept(entry.id), via_edge: entry.edge })),
    };
  }
}
