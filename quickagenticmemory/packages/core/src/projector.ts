import { posix } from "node:path";

import {
  conceptAliases,
  conceptStatus,
  conceptTags,
  conceptUid,
  nonEmptyString,
  okfSources,
} from "./frontmatter.js";
import { compareText, normalizeTerm, sha256, stableId } from "./hash.js";
import { resolveLink } from "./links.js";
import { GRAPH_CONTRACT_LIMITS, GraphSnapshotSchema } from "./qam-graph-contract.js";
import { repositoryWebUrl, sanitizeRepository } from "./repository.js";
import type {
  BundleValidationResult,
  ConceptNode,
  GraphEdge,
  GraphEdgeType,
  GraphNode,
  KnowledgeBundle,
  ProjectionManifest,
  ProjectionOptions,
  ProjectionOutput,
  ProjectedGraph,
  SourceNode,
  TagNode,
  TermNode,
} from "./types.js";
import { GRAPH_SCHEMA_VERSION, OKF_VERSION } from "./types.js";
import { isIsoDatetimeWithOffset } from "./time.js";
import { validateBundle } from "./validator.js";

const PROJECTOR_VERSION = "0.1.0";

type GraphEdgeDraft = Omit<GraphEdge, "projectionId" | "commitSha">;

interface SourceAccumulator {
  id: string;
  resource: string;
  titles: Set<string>;
  sourceIds: Set<string>;
  authors: Set<string>;
  usageCounts: Set<number>;
  lastModified: Set<string>;
}

export class ProjectionValidationError extends Error {
  readonly validation: BundleValidationResult;

  constructor(validation: BundleValidationResult, strict: boolean) {
    const reason = strict
      ? `${validation.summary.errors} error(s) and ${validation.summary.warnings} warning(s)`
      : `${validation.summary.errors} error(s)`;
    super(`Bundle cannot be projected because validation reported ${reason}.`);
    this.name = "ProjectionValidationError";
    this.validation = validation;
  }
}

export class ProjectionContractError extends Error {
  readonly issues: ReadonlyArray<{ readonly path: PropertyKey[]; readonly message: string }>;

  constructor(issues: ReadonlyArray<{ readonly path: PropertyKey[]; readonly message: string }>) {
    const first = issues[0];
    const location = first === undefined || first.path.length === 0 ? "graph" : first.path.join(".");
    const reason = first?.message ?? "unknown contract violation";
    super(`Projected graph violates qam-graph/1.0 at ${location}: ${reason}`);
    this.name = "ProjectionContractError";
    this.issues = issues;
  }
}

export function assertProjectedGraphContract(graph: ProjectedGraph): void {
  const result = GraphSnapshotSchema.safeParse(graph);
  if (!result.success) throw new ProjectionContractError(result.error.issues);
}

function validateProjectionOptions(options: ProjectionOptions): void {
  if (options.gitSha.trim().length === 0) throw new Error("Projection gitSha must not be empty.");
  if (!isIsoDatetimeWithOffset(options.generatedAt)) {
    throw new Error("Projection generatedAt must be an ISO 8601 datetime with an explicit UTC offset.");
  }
  if (options.pathInRepository?.split("/").includes("..") === true) {
    throw new Error("Projection pathInRepository must not escape the repository root.");
  }
  if (options.sourceBaseUrl !== undefined) {
    let url: URL;
    try {
      url = new URL(options.sourceBaseUrl);
    } catch {
      throw new Error("Projection sourceBaseUrl must be an absolute URL.");
    }
    if (url.username.length > 0 || url.password.length > 0) {
      throw new Error("Projection sourceBaseUrl must not contain credentials.");
    }
  }
}

function derivedTitle(conceptId: string): string {
  const filename = posix.basename(conceptId);
  return filename.replace(/[-_]+/g, " ").replace(/\b\w/g, (letter) => letter.toLocaleUpperCase("en-US"));
}

function encodePath(path: string): string {
  return path
    .split("/")
    .filter((segment) => segment.length > 0)
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}

function sourceUrlFor(path: string, options: ProjectionOptions): string | undefined {
  const pathInRepository = options.pathInRepository?.replace(/^\/+|\/+$/g, "") ?? "";
  const completePath = pathInRepository.length === 0 ? path : posix.join(pathInRepository, path);
  if (options.sourceBaseUrl !== undefined) {
    return `${options.sourceBaseUrl.replace(/\/$/, "")}/${encodePath(completePath)}`;
  }
  const repositoryUrl = repositoryWebUrl(options.repository ?? "");
  if (repositoryUrl === undefined) return undefined;
  return `${repositoryUrl}/blob/${encodeURIComponent(options.gitSha)}/${encodePath(completePath)}`;
}

function compareNodes(left: GraphNode, right: GraphNode): number {
  const order: Record<GraphNode["kind"], number> = { Concept: 0, Tag: 1, Source: 2, Term: 3 };
  const byKind = order[left.kind] - order[right.kind];
  return byKind === 0 ? compareText(left.id, right.id) : byKind;
}

function compareEdges(left: GraphEdgeDraft, right: GraphEdgeDraft): number {
  const byType = compareText(left.type, right.type);
  if (byType !== 0) return byType;
  const byFrom = compareText(left.from, right.from);
  if (byFrom !== 0) return byFrom;
  return compareText(left.to, right.to);
}

function conceptIdentity(
  document: KnowledgeBundle["documents"][number],
  duplicateUids: Set<string>,
): string {
  const uid = conceptUid(document.frontmatter);
  if (uid === undefined) return `path\0${document.conceptId ?? document.path}`;
  return duplicateUids.has(uid) ? `duplicate-uid\0${uid}\0${document.path}` : `uid\0${uid}`;
}

function first(values: Set<string>, fallback: string): string {
  return [...values].sort(compareText)[0] ?? fallback;
}

function latest(values: Set<string>): string | undefined {
  return [...values].sort(compareText).at(-1);
}

function optionalEdgeLabel(label: string | undefined): string | undefined {
  const trimmed = label?.trim();
  return trimmed === undefined || trimmed.length === 0 || trimmed.length > GRAPH_CONTRACT_LIMITS.edgeLabel
    ? undefined
    : trimmed;
}

function sourceTitleFallback(resource: string): string {
  return resource.length <= GRAPH_CONTRACT_LIMITS.title ? resource : "Source";
}

function addEdge(
  edges: Map<string, GraphEdgeDraft>,
  type: GraphEdgeType,
  from: string,
  to: string,
  sourcePath: string,
  label?: string,
): void {
  const identity = `${type}\0${from}\0${to}`;
  const id = stableId("edge", identity);
  const edgeLabel = optionalEdgeLabel(label);
  const candidate: GraphEdgeDraft = {
    id,
    from,
    to,
    type,
    ...(edgeLabel === undefined ? {} : { label: edgeLabel }),
    sourcePath,
  };
  const existing = edges.get(id);
  if (existing === undefined || compareText(candidate.label ?? "", existing.label ?? "") < 0) {
    edges.set(id, candidate);
  }
}

export function projectValidatedBundle(
  validation: BundleValidationResult,
  options: ProjectionOptions,
): ProjectionOutput {
  validateProjectionOptions(options);
  if (!validation.valid || (options.strict === true && validation.summary.warnings > 0)) {
    throw new ProjectionValidationError(validation, options.strict === true);
  }

  const { bundle } = validation;
  const commitSha = options.gitSha.trim();
  const sanitizedRepository = sanitizeRepository(options.repository?.trim() || "local");
  const repository = repositoryWebUrl(sanitizedRepository) ?? sanitizedRepository;
  const pathInRepository = options.pathInRepository?.replace(/^\/+|\/+$/g, "") ?? "";
  const files = bundle.documents
    .map((document) => ({ path: document.path, sha256: document.contentHash }))
    .sort((left, right) => compareText(left.path, right.path));
  const contentDigest = sha256(files.map((file) => `${file.path}\0${file.sha256}`).join("\n"));
  const projectionId = stableId(
    "projection",
    `${repository}\0${commitSha}\0${pathInRepository}\0${contentDigest}`,
  );
  const source = { repository, projectionId, commitSha, generatedAt: options.generatedAt };
  const okfVersion = bundle.okfVersion ?? OKF_VERSION;
  const conceptDocuments = bundle.documents.filter((document) => document.kind === "concept");
  const conceptIdByPath = new Map<string, string>();
  const nodes = new Map<string, GraphNode>();
  const edges = new Map<string, GraphEdgeDraft>();
  const tagDisplays = new Map<string, Set<string>>();
  const termDisplays = new Map<string, Set<string>>();
  const sourceAccumulators = new Map<string, SourceAccumulator>();
  const uidCounts = new Map<string, number>();

  for (const document of conceptDocuments) {
    const uid = conceptUid(document.frontmatter);
    if (uid !== undefined) uidCounts.set(uid, (uidCounts.get(uid) ?? 0) + 1);
  }
  const duplicateUids = new Set(
    [...uidCounts.entries()].filter(([, count]) => count > 1).map(([uid]) => uid),
  );

  for (const document of conceptDocuments) {
    conceptIdByPath.set(document.path, stableId("concept", conceptIdentity(document, duplicateUids)));
  }

  for (const document of conceptDocuments) {
    const conceptNodeId = conceptIdByPath.get(document.path);
    if (conceptNodeId === undefined) continue;
    const title = nonEmptyString(document.frontmatter.title) ?? derivedTitle(document.conceptId ?? document.path);
    const type = nonEmptyString(document.frontmatter.type) ?? "Concept";
    const summary = nonEmptyString(document.frontmatter.description);
    const resource = nonEmptyString(document.frontmatter.resource);
    const tags = conceptTags(document.frontmatter);
    const aliases = conceptAliases(document.frontmatter);
    const sourceUrl = sourceUrlFor(document.path, options);
    const conceptNode: ConceptNode = {
      id: conceptNodeId,
      kind: "Concept",
      title,
      path: document.path,
      repositoryPath:
        pathInRepository.length === 0 ? document.path : posix.join(pathInRepository, document.path),
      conceptId: document.conceptId ?? document.path,
      type,
      tags,
      aliases,
      projectionId,
      commitSha,
      status: conceptStatus(document.frontmatter),
      contentHash: document.contentHash,
      ...(summary === undefined ? {} : { summary }),
      ...(resource === undefined ? {} : { resource }),
      ...(sourceUrl === undefined ? {} : { sourceUrl }),
    };
    nodes.set(conceptNode.id, conceptNode);

    for (const tag of tags) {
      const normalized = normalizeTerm(tag);
      const tagNodeId = stableId("tag", normalized);
      const displays = tagDisplays.get(normalized) ?? new Set<string>();
      displays.add(tag);
      tagDisplays.set(normalized, displays);
      addEdge(edges, "HAS_TAG", conceptNodeId, tagNodeId, document.path, tag);
    }

    for (const alias of aliases) {
      const normalized = normalizeTerm(alias);
      const termNodeId = stableId("term", normalized);
      const displays = termDisplays.get(normalized) ?? new Set<string>();
      displays.add(alias);
      termDisplays.set(normalized, displays);
      addEdge(edges, "ALIASED_AS", conceptNodeId, termNodeId, document.path, alias);
    }

    for (const source of okfSources(document.frontmatter)) {
      const canonicalResource = source.resource.normalize("NFKC").trim();
      const sourceNodeId = stableId("source", canonicalResource);
      const accumulator = sourceAccumulators.get(canonicalResource) ?? {
        id: sourceNodeId,
        resource: canonicalResource,
        titles: new Set<string>(),
        sourceIds: new Set<string>(),
        authors: new Set<string>(),
        usageCounts: new Set<number>(),
        lastModified: new Set<string>(),
      };
      if (source.title !== undefined) accumulator.titles.add(source.title);
      if (source.id !== undefined) accumulator.sourceIds.add(source.id);
      if (source.author !== undefined) accumulator.authors.add(source.author);
      if (source.usageCount !== undefined) accumulator.usageCounts.add(source.usageCount);
      if (source.lastModified !== undefined) accumulator.lastModified.add(source.lastModified);
      sourceAccumulators.set(canonicalResource, accumulator);
      addEdge(
        edges,
        "DERIVED_FROM",
        conceptNodeId,
        sourceNodeId,
        document.path,
        source.title ?? source.id ?? source.resource,
      );
    }

    for (const link of document.links) {
      const resolution = resolveLink(bundle, document, link);
      if (resolution.kind !== "concept" || resolution.path === undefined) continue;
      const targetId = conceptIdByPath.get(resolution.path);
      if (targetId !== undefined) {
        addEdge(edges, "LINKS_TO", conceptNodeId, targetId, document.path, link.label);
      }
    }
  }

  for (const [normalizedValue, displays] of tagDisplays) {
    const node: TagNode = {
      id: stableId("tag", normalizedValue),
      kind: "Tag",
      title: first(displays, normalizedValue),
      type: "Tag",
      tags: [],
      aliases: [...displays].sort(compareText),
      projectionId,
      commitSha,
      normalizedValue,
    };
    nodes.set(node.id, node);
  }

  for (const [normalizedValue, displays] of termDisplays) {
    const node: TermNode = {
      id: stableId("term", normalizedValue),
      kind: "Term",
      title: first(displays, normalizedValue),
      type: "Term",
      tags: [],
      aliases: [...displays].sort(compareText),
      projectionId,
      commitSha,
      normalizedValue,
    };
    nodes.set(node.id, node);
  }

  for (const accumulator of sourceAccumulators.values()) {
    const lastModified = latest(accumulator.lastModified);
    const node: SourceNode = {
      id: accumulator.id,
      kind: "Source",
      title: first(accumulator.titles, sourceTitleFallback(accumulator.resource)),
      type: "Source",
      tags: [],
      aliases: [...accumulator.titles].sort(compareText),
      projectionId,
      commitSha,
      resource: accumulator.resource,
      sourceIds: [...accumulator.sourceIds].sort(compareText),
      authors: [...accumulator.authors].sort(compareText),
      usageCounts: [...accumulator.usageCounts].sort((left, right) => left - right),
      ...(lastModified === undefined ? {} : { lastModified }),
    };
    nodes.set(node.id, node);
  }

  const sortedNodes = [...nodes.values()].sort(compareNodes);
  const sortedEdges: GraphEdge[] = [...edges.values()]
    .sort(compareEdges)
    .map((edge) => ({ ...edge, projectionId, commitSha }));
  const manifest: ProjectionManifest = {
    schemaVersion: GRAPH_SCHEMA_VERSION,
    okfVersion,
    projector: { name: "@quick-agentic-memory/core", version: PROJECTOR_VERSION },
    source,
    bundle: { pathInRepository, contentDigest, files },
    counts: {
      documents: bundle.documents.length,
      concepts: conceptDocuments.length,
      nodes: sortedNodes.length,
      edges: sortedEdges.length,
    },
  };

  const graph: ProjectedGraph = {
    schemaVersion: GRAPH_SCHEMA_VERSION,
    okfVersion,
    source,
    nodes: sortedNodes,
    edges: sortedEdges,
  };
  assertProjectedGraphContract(graph);

  return {
    graph,
    manifest,
    validation,
  };
}

export async function projectBundle(
  rootPath: string,
  options: ProjectionOptions,
): Promise<ProjectionOutput> {
  return projectValidatedBundle(await validateBundle(rootPath), options);
}
