import { DefaultAzureCredential } from "@azure/identity";
import * as z from "zod/v4";

import { GatewayError } from "../errors.js";
import {
  QAM_FABRIC_SNAPSHOT_TTL_DEFAULT_MS,
  QAM_FABRIC_SNAPSHOT_TTL_MAX_MS,
  QAM_FABRIC_SNAPSHOT_TTL_MIN_MS,
} from "../fabric-settings.js";
import {
  GitShaSchema,
  GRAPH_CONTRACT_LIMITS,
  GraphNodeSchema,
  GraphEdgeSchema,
  GraphSnapshotSchema,
  MAX_GRAPH_EDGES,
  MAX_GRAPH_NODES,
  ProjectionIdSchema,
  type ConceptNode,
  type GraphEdge,
  type GraphNode,
  type GraphSnapshot,
} from "../schemas.js";
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
import { fetchWithTimeout, validateRemoteUrl } from "./http-utils.js";
import { MemoryGraphAdapter } from "./memory-graph.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const SUCCESS_STATUS = /^(?:00|01|02|03)/u;
export const QAM_NODE_LIMIT = 10_000;
export const QAM_EDGE_LIMIT = 50_000;

function nodeQuery(limit: number): string {
  return `MATCH (n:\`QamNode\`)
RETURN n.\`id\` AS \`id\`, n.\`kind\` AS \`kind\`, n.\`title\` AS \`title\`, n.\`type\` AS \`type\`,
       n.\`path\` AS \`path\`, n.\`repositoryPath\` AS \`repositoryPath\`, n.\`conceptId\` AS \`conceptId\`,
       n.\`tagsJson\` AS \`tagsJson\`, n.\`aliasesJson\` AS \`aliasesJson\`, n.\`projectionId\` AS \`projectionId\`,
       n.\`commitSha\` AS \`commitSha\`, n.\`repository\` AS \`repository\`,
       n.\`projectionGeneratedAt\` AS \`projectionGeneratedAt\`, n.\`okfVersion\` AS \`okfVersion\`,
       n.\`summary\` AS \`summary\`, n.\`resource\` AS \`resource\`, n.\`status\` AS \`status\`,
       n.\`contentHash\` AS \`contentHash\`,
       n.\`sourceUrl\` AS \`sourceUrl\`, n.\`normalizedValue\` AS \`normalizedValue\`,
       n.\`sourceIdsJson\` AS \`sourceIdsJson\`, n.\`authorsJson\` AS \`authorsJson\`,
       n.\`usageCountsJson\` AS \`usageCountsJson\`, n.\`lastModified\` AS \`lastModified\`
LIMIT ${limit};`;
}

function edgeQuery(limit: number): string {
  return `MATCH (source:\`QamNode\`)-[e:\`QamEdge\`]->(target:\`QamNode\`)
RETURN e.\`id\` AS \`id\`, source.\`id\` AS \`from\`, target.\`id\` AS \`to\`, e.\`type\` AS \`type\`,
       e.\`projectionId\` AS \`projectionId\`, e.\`commitSha\` AS \`commitSha\`, e.\`label\` AS \`label\`,
       e.\`sourcePath\` AS \`sourcePath\`
LIMIT ${limit};`;
}

export const QAM_NODE_QUERY = nodeQuery(QAM_NODE_LIMIT);
export const QAM_EDGE_QUERY = edgeQuery(QAM_EDGE_LIMIT);

export function assertProjectionWithinLimits(
  nodeCount: number,
  edgeCount: number,
  nodeLimit = QAM_NODE_LIMIT,
  edgeLimit = QAM_EDGE_LIMIT,
): void {
  if (nodeCount >= nodeLimit || edgeCount >= edgeLimit) {
    throw new GatewayError(
      "Fabric projection exceeds the adapter limit; refusing a potentially incomplete graph.",
      "adapter_error",
    );
  }
}

const FabricResponseSchema = z
  .object({
    status: z.object({ code: z.string().min(2), description: z.string().optional() }).loose(),
    result: z
      .union([
        z.object({ kind: z.literal("TABLE"), data: z.array(z.record(z.string(), z.unknown())) }).loose(),
        z.object({ kind: z.literal("NOTHING") }).loose(),
      ])
      .optional(),
  })
  .loose();

interface FabricTokenCredential {
  getToken(scopes: string | readonly string[]): Promise<{ readonly token: string } | null>;
}

export interface FabricGqlGraphAdapterOptions {
  readonly workspaceId: string;
  readonly graphModelId: string;
  readonly expectedRepository?: string;
  readonly expectedProjectionId?: string;
  readonly expectedCommitSha?: string;
  readonly apiBaseUrl?: string;
  readonly tokenScope?: string;
  readonly managedIdentityClientId?: string;
  readonly accessToken?: string;
  readonly credential?: FabricTokenCredential;
  readonly timeoutMs?: number;
  readonly maxNodes?: number;
  readonly maxEdges?: number;
  readonly snapshotTtlMs?: number;
  readonly now?: () => number;
  readonly allowInsecureLocalhost?: boolean;
}

function unwrap(value: unknown): unknown {
  if (typeof value === "object" && value !== null && "gqlType" in value && "value" in value) {
    return (value as { readonly value: unknown }).value;
  }
  return value;
}

function requiredString(row: Readonly<Record<string, unknown>>, field: string): string {
  const value = unwrap(row[field]);
  if (typeof value !== "string" || value.trim() === "") {
    throw new GatewayError(`Fabric Qam projection row is missing required string field '${field}'.`, "adapter_error");
  }
  return value;
}

function optionalString(row: Readonly<Record<string, unknown>>, field: string): string | undefined {
  const value = unwrap(row[field]);
  if (value === null || value === undefined || value === "") return undefined;
  if (typeof value !== "string") {
    throw new GatewayError(`Fabric Qam projection field '${field}' must be a string or null.`, "adapter_error");
  }
  return value;
}

function stringArrayFromJson(
  row: Readonly<Record<string, unknown>>,
  field: string,
  arrayLengthLimit: number,
  itemLengthLimit: number,
): string[] {
  const encoded = optionalString(row, field);
  if (encoded === undefined) return [];
  try {
    return z
      .array(z.string().min(1).max(itemLengthLimit))
      .max(arrayLengthLimit)
      .parse(JSON.parse(encoded) as unknown);
  } catch {
    throw new GatewayError(`Fabric Qam projection field '${field}' is not a valid JSON string array.`, "adapter_error");
  }
}

function numberArrayFromJson(row: Readonly<Record<string, unknown>>, field: string): number[] {
  const encoded = optionalString(row, field);
  if (encoded === undefined) return [];
  try {
    return z
      .array(z.number().int().nonnegative())
      .max(GRAPH_CONTRACT_LIMITS.usageCounts)
      .parse(JSON.parse(encoded) as unknown);
  } catch {
    throw new GatewayError(`Fabric Qam projection field '${field}' is not a valid JSON integer array.`, "adapter_error");
  }
}

function isLocalhost(url: URL): boolean {
  return url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]";
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  minimum: number,
  maximum: number,
  name: string,
): number {
  const limit = value ?? fallback;
  if (!Number.isInteger(limit) || limit < minimum || limit > maximum) {
    throw new GatewayError(`${name} must be an integer between ${minimum} and ${maximum}.`, "configuration_error");
  }
  return limit;
}

/** Direct, read-only Fabric Graph adapter with two compile-time GQL queries. */
export class FabricGqlGraphAdapter implements GraphReadAdapter {
  public readonly kind = "fabric-gql";
  readonly #endpoint: URL;
  readonly #expectedRepository: string | undefined;
  readonly #expectedProjectionId: string | undefined;
  readonly #expectedCommitSha: string | undefined;
  readonly #scope: string;
  readonly #accessToken: string | undefined;
  readonly #credential: FabricTokenCredential;
  readonly #timeoutMs: number;
  readonly #nodeLimit: number;
  readonly #edgeLimit: number;
  readonly #nodeQuery: string;
  readonly #edgeQuery: string;
  readonly #snapshotTtlMs: number;
  readonly #now: () => number;
  #delegate: MemoryGraphAdapter | undefined;
  #delegateExpiresAt = 0;
  #refreshPromise: Promise<MemoryGraphAdapter> | undefined;

  public constructor(options: FabricGqlGraphAdapterOptions) {
    if (!UUID.test(options.workspaceId) || !UUID.test(options.graphModelId)) {
      throw new GatewayError("Fabric workspace and graph model IDs must be UUIDs.", "configuration_error");
    }
    const allowInsecureLocalhost = options.allowInsecureLocalhost ?? false;
    const baseUrl = validateRemoteUrl(options.apiBaseUrl ?? "https://api.fabric.microsoft.com", allowInsecureLocalhost);
    const localTest = allowInsecureLocalhost && isLocalhost(baseUrl);
    if (!localTest && (baseUrl.origin !== "https://api.fabric.microsoft.com" || baseUrl.pathname !== "/")) {
      throw new GatewayError(
        "Fabric Managed Identity tokens may be sent only to https://api.fabric.microsoft.com; custom hosts are allowed only for explicit localhost tests.",
        "configuration_error",
      );
    }
    if (options.accessToken !== undefined && !localTest) {
      throw new GatewayError("QAM_FABRIC_ACCESS_TOKEN is permitted only for explicit localhost tests.", "configuration_error");
    }
    const tokenScope = options.tokenScope ?? "https://api.fabric.microsoft.com/.default";
    if (!localTest && tokenScope !== "https://api.fabric.microsoft.com/.default") {
      throw new GatewayError("Fabric token scope is fixed in production to prevent token exfiltration.", "configuration_error");
    }
    const endpointBase = new URL(baseUrl);
    if (!endpointBase.pathname.endsWith("/")) endpointBase.pathname += "/";
    this.#endpoint = new URL(
      `v1/workspaces/${encodeURIComponent(options.workspaceId)}/GraphModels/${encodeURIComponent(options.graphModelId)}/executeQuery?preview=true`,
      endpointBase,
    );
    this.#expectedRepository = options.expectedRepository;
    this.#expectedProjectionId =
      options.expectedProjectionId === undefined ? undefined : ProjectionIdSchema.parse(options.expectedProjectionId);
    this.#expectedCommitSha =
      options.expectedCommitSha === undefined ? undefined : GitShaSchema.parse(options.expectedCommitSha);
    this.#scope = tokenScope;
    this.#accessToken = options.accessToken;
    this.#credential =
      options.credential ??
      new DefaultAzureCredential(
        options.managedIdentityClientId === undefined
          ? undefined
          : { managedIdentityClientId: options.managedIdentityClientId },
      );
    this.#timeoutMs = options.timeoutMs ?? 30_000;
    this.#nodeLimit = boundedInteger(options.maxNodes, QAM_NODE_LIMIT, 1, MAX_GRAPH_NODES, "QAM_FABRIC_MAX_NODES");
    this.#edgeLimit = boundedInteger(options.maxEdges, QAM_EDGE_LIMIT, 1, MAX_GRAPH_EDGES, "QAM_FABRIC_MAX_EDGES");
    this.#snapshotTtlMs = boundedInteger(
      options.snapshotTtlMs,
      QAM_FABRIC_SNAPSHOT_TTL_DEFAULT_MS,
      QAM_FABRIC_SNAPSHOT_TTL_MIN_MS,
      QAM_FABRIC_SNAPSHOT_TTL_MAX_MS,
      "QAM_FABRIC_SNAPSHOT_TTL_MS",
    );
    this.#now = options.now ?? Date.now;
    this.#nodeQuery = nodeQuery(this.#nodeLimit);
    this.#edgeQuery = edgeQuery(this.#edgeLimit);
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
    if (this.#delegate !== undefined && this.#now() < this.#delegateExpiresAt) return this.#delegate;
    if (this.#refreshPromise !== undefined) return this.#refreshPromise;
    const refresh = this.#refresh();
    this.#refreshPromise = refresh;
    try {
      const delegate = await refresh;
      this.#delegate = delegate;
      this.#delegateExpiresAt = this.#now() + this.#snapshotTtlMs;
      return delegate;
    } finally {
      if (this.#refreshPromise === refresh) this.#refreshPromise = undefined;
    }
  }

  async #refresh(): Promise<MemoryGraphAdapter> {
    const token = await this.#token();
    const [nodeRows, edgeRows] = await Promise.all([
      this.#execute(this.#nodeQuery, token),
      this.#execute(this.#edgeQuery, token),
    ]);
    if (nodeRows.length === 0) {
      throw new GatewayError("Fabric QamNode query returned no data.", "adapter_error");
    }
    assertProjectionWithinLimits(nodeRows.length, edgeRows.length, this.#nodeLimit, this.#edgeLimit);

    const projection = {
      repository: requiredString(nodeRows[0]!, "repository"),
      projectionId: requiredString(nodeRows[0]!, "projectionId"),
      generatedAt: requiredString(nodeRows[0]!, "projectionGeneratedAt"),
      okfVersion: requiredString(nodeRows[0]!, "okfVersion"),
      commitSha: requiredString(nodeRows[0]!, "commitSha"),
    };
    for (const row of nodeRows) {
      if (
        requiredString(row, "repository") !== projection.repository ||
        requiredString(row, "projectionId") !== projection.projectionId ||
        requiredString(row, "projectionGeneratedAt") !== projection.generatedAt ||
        requiredString(row, "okfVersion") !== projection.okfVersion ||
        requiredString(row, "commitSha") !== projection.commitSha
      ) {
        throw new GatewayError("Fabric QamNode rows contain inconsistent projection provenance.", "adapter_error");
      }
    }
    if (this.#expectedRepository !== undefined && this.#expectedRepository !== projection.repository) {
      throw new GatewayError("Fabric projection repository does not match QAM_SOURCE_REPOSITORY.", "invalid_reference");
    }
    if (this.#expectedProjectionId !== undefined && this.#expectedProjectionId !== projection.projectionId) {
      throw new GatewayError("Fabric projection does not match QAM_EXPECTED_PROJECTION_ID.", "invalid_reference");
    }
    if (this.#expectedCommitSha !== undefined && this.#expectedCommitSha !== projection.commitSha) {
      throw new GatewayError("Fabric projection does not match QAM_EXPECTED_COMMIT_SHA.", "invalid_reference");
    }

    for (const row of edgeRows) {
      if (
        requiredString(row, "projectionId") !== projection.projectionId ||
        requiredString(row, "commitSha") !== projection.commitSha
      ) {
        throw new GatewayError(
          "Fabric QamEdge rows do not match the immutable QamNode projection and commit.",
          "adapter_error",
        );
      }
    }

    const nodes = nodeRows.map((row): GraphNode => {
      const kind = z.enum(["Concept", "Tag", "Source", "Term"]).parse(requiredString(row, "kind"));
      const base = {
        id: requiredString(row, "id"),
        kind,
        title: requiredString(row, "title"),
        type: requiredString(row, "type"),
        tags: stringArrayFromJson(
          row,
          "tagsJson",
          GRAPH_CONTRACT_LIMITS.tags,
          GRAPH_CONTRACT_LIMITS.tag,
        ),
        aliases: stringArrayFromJson(
          row,
          "aliasesJson",
          GRAPH_CONTRACT_LIMITS.aliases,
          GRAPH_CONTRACT_LIMITS.alias,
        ),
        commitSha: requiredString(row, "commitSha"),
        projectionId: requiredString(row, "projectionId"),
      };
      if (kind === "Concept") {
        const summary = optionalString(row, "summary");
        const resource = optionalString(row, "resource");
        const sourceUrl = optionalString(row, "sourceUrl");
        return GraphNodeSchema.parse({
          ...base,
          kind,
          path: requiredString(row, "path"),
          repositoryPath: requiredString(row, "repositoryPath"),
          conceptId: requiredString(row, "conceptId"),
          status: requiredString(row, "status"),
          contentHash: requiredString(row, "contentHash"),
          ...(summary === undefined ? {} : { summary }),
          ...(resource === undefined ? {} : { resource }),
          ...(sourceUrl === undefined ? {} : { sourceUrl }),
        });
      }
      if (kind === "Source") {
        const lastModified = optionalString(row, "lastModified");
        return GraphNodeSchema.parse({
          ...base,
          kind,
          resource: requiredString(row, "resource"),
          sourceIds: stringArrayFromJson(
            row,
            "sourceIdsJson",
            GRAPH_CONTRACT_LIMITS.sourceIds,
            GRAPH_CONTRACT_LIMITS.sourceId,
          ),
          authors: stringArrayFromJson(
            row,
            "authorsJson",
            GRAPH_CONTRACT_LIMITS.authors,
            GRAPH_CONTRACT_LIMITS.author,
          ),
          usageCounts: numberArrayFromJson(row, "usageCountsJson"),
          ...(lastModified === undefined ? {} : { lastModified }),
        });
      }
      return GraphNodeSchema.parse({
        ...base,
        kind,
        normalizedValue: requiredString(row, "normalizedValue"),
      });
    });
    const edges = edgeRows.map((row): GraphEdge => {
      const label = optionalString(row, "label");
      const sourcePath = optionalString(row, "sourcePath");
      return GraphEdgeSchema.parse({
        id: requiredString(row, "id"),
        from: requiredString(row, "from"),
        to: requiredString(row, "to"),
        type: requiredString(row, "type"),
        projectionId: requiredString(row, "projectionId"),
        commitSha: requiredString(row, "commitSha"),
        ...(label === undefined ? {} : { label }),
        ...(sourcePath === undefined ? {} : { sourcePath }),
      });
    });
    const snapshot = GraphSnapshotSchema.parse({
      schemaVersion: "qam-graph/1.0",
      okfVersion: projection.okfVersion,
      source: {
        repository: projection.repository,
        projectionId: projection.projectionId,
        commitSha: projection.commitSha,
        generatedAt: projection.generatedAt,
      },
      nodes,
      edges,
    });
    return new MemoryGraphAdapter(snapshot);
  }

  async #token(): Promise<string> {
    if (this.#accessToken !== undefined) return this.#accessToken;
    const accessToken = await this.#credential.getToken(this.#scope);
    if (accessToken === null || accessToken.token === "") {
      throw new GatewayError("DefaultAzureCredential did not return a Fabric access token.", "adapter_error");
    }
    return accessToken.token;
  }

  async #execute(query: string, token: string): Promise<Readonly<Record<string, unknown>>[]> {
    const response = await fetchWithTimeout(
      this.#endpoint,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "Content-Type": "application/json" },
        body: JSON.stringify({ query }),
      },
      this.#timeoutMs,
      "Fabric Graph executeQuery",
    );
    let parsed: z.infer<typeof FabricResponseSchema>;
    try {
      parsed = FabricResponseSchema.parse(await response.json());
    } catch {
      throw new GatewayError("Fabric Graph executeQuery returned an invalid response envelope.", "adapter_error");
    }
    if (!SUCCESS_STATUS.test(parsed.status.code)) {
      throw new GatewayError(`Fabric Graph query failed with GQL status '${parsed.status.code}'.`, "adapter_error");
    }
    return parsed.result?.kind === "TABLE" ? parsed.result.data : [];
  }
}
