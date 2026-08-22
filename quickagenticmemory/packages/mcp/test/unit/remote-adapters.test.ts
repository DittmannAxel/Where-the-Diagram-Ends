import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { generateKeyPairSync, verify } from "node:crypto";
import { readFile } from "node:fs/promises";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import {
  assertProjectionWithinLimits,
  FabricGqlGraphAdapter,
  QAM_EDGE_LIMIT,
  QAM_EDGE_QUERY,
  QAM_NODE_LIMIT,
  QAM_NODE_QUERY,
} from "../../src/adapters/fabric-gql-graph.js";
import { FabricHttpGraphAdapter } from "../../src/adapters/fabric-http-graph.js";
import { GitHubContentAdapter } from "../../src/adapters/github-content.js";
import {
  GRAPH_CONTRACT_LIMITS,
  GraphSnapshotSchema,
  type GraphNode,
  type GraphSnapshot,
} from "../../src/schemas.js";
import { FIXTURE_COMMIT, FIXTURE_GRAPH } from "../helpers.js";

const WORKSPACE_ID = "11111111-1111-4111-8111-111111111111";
const GRAPH_MODEL_ID = "22222222-2222-4222-8222-222222222222";

function toFabricNodeRow(node: GraphNode, snapshot: GraphSnapshot): Record<string, unknown> {
  return {
    id: node.id,
    kind: node.kind,
    title: node.title,
    type: node.type,
    path: node.kind === "Concept" ? node.path : null,
    repositoryPath: node.kind === "Concept" ? node.repositoryPath : null,
    conceptId: node.kind === "Concept" ? node.conceptId : null,
    tagsJson: JSON.stringify(node.tags),
    aliasesJson: JSON.stringify(node.aliases),
    commitSha: node.commitSha,
    projectionId: node.projectionId,
    summary: node.kind === "Concept" ? (node.summary ?? null) : null,
    resource: node.kind === "Concept" || node.kind === "Source" ? (node.resource ?? null) : null,
    status: node.kind === "Concept" ? node.status : null,
    contentHash: node.kind === "Concept" ? node.contentHash : null,
    sourceUrl: node.kind === "Concept" ? (node.sourceUrl ?? null) : null,
    normalizedValue: node.kind === "Tag" || node.kind === "Term" ? node.normalizedValue : null,
    sourceIdsJson: node.kind === "Source" ? JSON.stringify(node.sourceIds) : null,
    authorsJson: node.kind === "Source" ? JSON.stringify(node.authors) : null,
    usageCountsJson: node.kind === "Source" ? JSON.stringify(node.usageCounts) : null,
    lastModified: node.kind === "Source" ? (node.lastModified ?? null) : null,
    repository: snapshot.source.repository,
    projectionGeneratedAt: snapshot.source.generatedAt,
    okfVersion: snapshot.okfVersion,
  };
}

function refreshedSnapshot(original: GraphSnapshot): GraphSnapshot {
  const projectionId = `urn:qam:projection:${"d".repeat(64)}`;
  const commitSha = "e".repeat(40);
  return GraphSnapshotSchema.parse({
    ...original,
    source: { ...original.source, projectionId, commitSha, generatedAt: "2026-08-22T12:01:00Z" },
    nodes: original.nodes.map((node) => ({ ...node, projectionId, commitSha })),
    edges: original.edges.map((edge) => ({ ...edge, projectionId, commitSha })),
  });
}

async function jsonRequest(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
}

describe("remote adapter boundaries", () => {
  let server: Server;
  let origin: string;
  let graphJson: string;
  let snapshot: GraphSnapshot;
  let activeFabricSnapshot: GraphSnapshot;
  let fabricQueries: string[];
  let fabricRequestUrls: string[];
  let fabricHttpFailure: boolean;
  let inconsistentFabricMetadata: boolean;
  let fabricEdgeMode: "normal" | "mixed" | "mixed-commit" | "missing";
  let fabricStringArrayOverride:
    | { readonly kind: GraphNode["kind"]; readonly field: string; readonly values: string[] }
    | undefined;
  let githubAppTokenExchanges: number;
  let githubAppTokenBodies: Record<string, unknown>[];
  let githubAppJwtClaims: Record<string, unknown> | undefined;
  let rejectInstallationTokenOnce: boolean;
  const appKeys = generateKeyPairSync("rsa", { modulusLength: 2_048 });
  const appPrivateKey = appKeys.privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const appNow = Date.parse("2026-08-22T12:00:00Z");

  beforeAll(async () => {
    graphJson = await readFile(FIXTURE_GRAPH, "utf8");
    snapshot = GraphSnapshotSchema.parse(JSON.parse(graphJson) as unknown);
    activeFabricSnapshot = snapshot;
    fabricQueries = [];
    fabricRequestUrls = [];
    fabricHttpFailure = false;
    inconsistentFabricMetadata = false;
    fabricEdgeMode = "normal";
    fabricStringArrayOverride = undefined;
    githubAppTokenExchanges = 0;
    githubAppTokenBodies = [];
    githubAppJwtClaims = undefined;
    rejectInstallationTokenOnce = false;

    const handleRequest = async (request: IncomingMessage, response: ServerResponse): Promise<void> => {
      const url = new URL(request.url ?? "/", "http://localhost");
      if (url.pathname === "/snapshot") {
        if (request.headers.authorization !== "Bearer fabric-test-token") {
          response.writeHead(401).end();
          return;
        }
        response.writeHead(200, { "Content-Type": "application/json" }).end(graphJson);
        return;
      }
      if (
        url.pathname === `/v1/workspaces/${WORKSPACE_ID}/GraphModels/${GRAPH_MODEL_ID}/executeQuery` &&
        url.searchParams.get("preview") === "true"
      ) {
        if (request.headers.authorization !== "Bearer direct-fabric-test-token") {
          response.writeHead(401).end();
          return;
        }
        const body = await jsonRequest(request);
        const query = body.query;
        if (typeof query !== "string" || (query !== QAM_NODE_QUERY && query !== QAM_EDGE_QUERY)) {
          response.writeHead(400).end();
          return;
        }
        fabricQueries.push(query);
        fabricRequestUrls.push(request.url ?? "");
        if (fabricHttpFailure) {
          response.writeHead(503, { "Content-Type": "application/json" }).end('{"error":"unavailable"}');
          return;
        }
        let rows: Record<string, unknown>[];
        if (query === QAM_NODE_QUERY) {
          rows = activeFabricSnapshot.nodes.map((node) => toFabricNodeRow(node, activeFabricSnapshot));
          if (fabricStringArrayOverride !== undefined) {
            const index = rows.findIndex((row) => row.kind === fabricStringArrayOverride?.kind);
            if (index >= 0 && rows[index] !== undefined) {
              rows[index] = {
                ...rows[index],
                [fabricStringArrayOverride.field]: JSON.stringify(fabricStringArrayOverride.values),
              };
            }
          }
          if (inconsistentFabricMetadata && rows[1] !== undefined) {
            rows[1] = { ...rows[1], repository: "https://github.com/example/different" };
          }
        } else {
          rows = activeFabricSnapshot.edges.map((edge) => ({ ...edge }));
          if (fabricEdgeMode === "mixed" && rows[0] !== undefined) {
            rows[0] = { ...rows[0], projectionId: `urn:qam:projection:${"0".repeat(64)}` };
          } else if (fabricEdgeMode === "mixed-commit" && rows[0] !== undefined) {
            rows[0] = { ...rows[0], commitSha: "2".repeat(40) };
          } else if (fabricEdgeMode === "missing" && rows[0] !== undefined) {
            const withoutProjectionId = { ...rows[0] };
            delete withoutProjectionId.projectionId;
            rows[0] = withoutProjectionId;
          }
        }
        response
          .writeHead(200, { "Content-Type": "application/json" })
          .end(JSON.stringify({ status: { code: "0000" }, result: { kind: "TABLE", data: rows } }));
        return;
      }
      if (url.pathname === "/api/v3/app/installations/12345/access_tokens" && request.method === "POST") {
        const authorization = request.headers.authorization;
        if (typeof authorization !== "string" || !authorization.startsWith("Bearer ")) {
          response.writeHead(401).end();
          return;
        }
        const jwt = authorization.slice("Bearer ".length);
        const parts = jwt.split(".");
        if (
          parts.length !== 3 ||
          !verify(
            "RSA-SHA256",
            Buffer.from(`${parts[0]}.${parts[1]}`, "ascii"),
            appKeys.publicKey,
            Buffer.from(parts[2] ?? "", "base64url"),
          )
        ) {
          response.writeHead(401).end();
          return;
        }
        githubAppJwtClaims = JSON.parse(Buffer.from(parts[1] ?? "", "base64url").toString("utf8")) as Record<
          string,
          unknown
        >;
        githubAppTokenBodies.push(await jsonRequest(request));
        githubAppTokenExchanges += 1;
        response
          .writeHead(201, { "Content-Type": "application/json" })
          .end(
            JSON.stringify({
              token: "installation-token-with-minimum-length",
              expires_at: new Date(appNow + 60 * 60 * 1_000).toISOString(),
            }),
          );
        return;
      }
      if (
        (url.pathname === "/api/v3/repos/acme/wiki/contents/quickagenticmemory/knowledge/concepts/example.md" ||
          url.pathname === "/api/v3/repos/acme/wiki/contents/quickagenticmemory/knowledge/concepts/large.md" ||
          url.pathname ===
            "/api/v3/repos/acme/wiki/contents/quickagenticmemory/knowledge/concepts/declared-large.md") &&
        url.searchParams.get("ref") === FIXTURE_COMMIT
      ) {
        if (
          request.headers.authorization === "Bearer installation-token-with-minimum-length" &&
          rejectInstallationTokenOnce
        ) {
          rejectInstallationTokenOnce = false;
          response.writeHead(401).end();
          return;
        }
        if (
          request.headers.authorization !== "Bearer github-test-token-with-minimum-length" &&
          request.headers.authorization !== "Bearer installation-token-with-minimum-length"
        ) {
          response.writeHead(401).end();
          return;
        }
        if (url.pathname.endsWith("/declared-large.md")) {
          response
            .writeHead(200, {
              "Content-Type": "application/vnd.github.raw+json",
              "Content-Length": String(2 * 1024 * 1024 + 1),
            })
            .end("x".repeat(2 * 1024 * 1024 + 1));
          return;
        }
        if (url.pathname.endsWith("/large.md")) {
          response.writeHead(200, { "Content-Type": "application/vnd.github.raw+json" });
          response.write("x".repeat(1024 * 1024));
          response.end("x".repeat(1024 * 1024 + 1));
          return;
        }
        response.writeHead(200, { "Content-Type": "application/vnd.github.raw+json" }).end("# Remote example\n");
        return;
      }
      response.writeHead(404).end();
    };
    server = createServer((request, response) => {
      void handleRequest(request, response).catch(() => response.writeHead(500).end());
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => {
        server.off("error", reject);
        resolve();
      });
    });
    const address = server.address();
    if (address === null || typeof address === "string") throw new Error("test server did not bind TCP");
    origin = `http://127.0.0.1:${address.port}`;
  });

  afterAll(async () => {
    await new Promise<void>((resolve, reject) => server.close((error) => (error === undefined ? resolve() : reject(error))));
  });

  it("validates a curated Fabric projection snapshot before querying it", async () => {
    const adapter = new FabricHttpGraphAdapter({
      snapshotUrl: `${origin}/snapshot`,
      token: "fabric-test-token",
      allowInsecureLocalhost: true,
    });
    const result = await adapter.resolveConcepts({ terms: ["Graph Projector"], limit: 5, offset: 0 });
    expect(result.items[0]?.concept.id).toBe("qam:fabric-projector");
  });

  it("queries Fabric Graph directly with only the two fixed server-owned GQL statements", async () => {
    fabricQueries.length = 0;
    fabricRequestUrls.length = 0;
    const adapter = new FabricGqlGraphAdapter({
      workspaceId: WORKSPACE_ID,
      graphModelId: GRAPH_MODEL_ID,
      expectedRepository: snapshot.source.repository,
      expectedProjectionId: snapshot.source.projectionId,
      expectedCommitSha: snapshot.source.commitSha,
      apiBaseUrl: origin,
      accessToken: "direct-fabric-test-token",
      allowInsecureLocalhost: true,
    });

    const result = await adapter.resolveConcepts({ terms: ["Graph Projector"], limit: 5, offset: 0 });
    expect(result.items[0]?.concept.id).toBe("qam:fabric-projector");
    expect(new Set(fabricQueries)).toEqual(new Set([QAM_NODE_QUERY, QAM_EDGE_QUERY]));
    expect(fabricRequestUrls).toHaveLength(2);
    expect(fabricRequestUrls.every((value) => value.endsWith("/executeQuery?preview=true"))).toBe(true);
    expect(QAM_EDGE_QUERY).toContain("source.id AS `from`");
    expect(QAM_EDGE_QUERY).toContain("target.id AS `to`");
    expect(QAM_EDGE_QUERY).toContain("e.projectionId AS `projectionId`");
    expect(QAM_EDGE_QUERY).toContain("e.commitSha AS `commitSha`");
    expect(QAM_NODE_QUERY).toContain("n.repositoryPath AS `repositoryPath`");
  });

  it("refreshes an expired Fabric snapshot once for concurrent callers", async () => {
    fabricQueries.length = 0;
    let now = 0;
    let tokenCalls = 0;
    const adapter = new FabricGqlGraphAdapter({
      workspaceId: WORKSPACE_ID,
      graphModelId: GRAPH_MODEL_ID,
      expectedRepository: snapshot.source.repository,
      apiBaseUrl: origin,
      credential: {
        getToken: async () => {
          tokenCalls += 1;
          return { token: "direct-fabric-test-token" };
        },
      },
      snapshotTtlMs: 1_000,
      now: () => now,
      allowInsecureLocalhost: true,
    });

    try {
      const initial = await adapter.getSnapshot();
      expect(initial.source.projectionId).toBe(snapshot.source.projectionId);
      await adapter.getSnapshot();
      now = 999;
      await adapter.getSnapshot();
      const leased = await adapter.acquireSnapshot();
      expect(fabricQueries).toHaveLength(2);
      expect(tokenCalls).toBe(1);

      const refreshed = refreshedSnapshot(snapshot);
      activeFabricSnapshot = refreshed;
      now = 1_000;
      const results = await Promise.all(Array.from({ length: 12 }, async () => adapter.getSnapshot()));
      expect(new Set(results.map((result) => result.source.projectionId))).toEqual(
        new Set([refreshed.source.projectionId]),
      );
      expect(fabricQueries).toHaveLength(4);
      expect(tokenCalls).toBe(2);
      await expect(leased.graph.getSnapshot()).resolves.toMatchObject({
        source: { projectionId: snapshot.source.projectionId },
      });
    } finally {
      activeFabricSnapshot = snapshot;
    }
  });

  it("fails closed and retries after an invalid or unavailable expired refresh", async () => {
    fabricQueries.length = 0;
    let now = 0;
    let tokenCalls = 0;
    const adapter = new FabricGqlGraphAdapter({
      workspaceId: WORKSPACE_ID,
      graphModelId: GRAPH_MODEL_ID,
      apiBaseUrl: origin,
      credential: {
        getToken: async () => {
          tokenCalls += 1;
          return { token: "direct-fabric-test-token" };
        },
      },
      snapshotTtlMs: 1_000,
      now: () => now,
      allowInsecureLocalhost: true,
    });

    try {
      await adapter.getSnapshot();
      const refreshed = refreshedSnapshot(snapshot);
      activeFabricSnapshot = refreshed;
      fabricEdgeMode = "mixed";
      now = 1_000;
      const invalidResults = await Promise.allSettled(
        Array.from({ length: 8 }, async () => adapter.getSnapshot()),
      );
      expect(invalidResults.every((result) => result.status === "rejected")).toBe(true);
      expect(fabricQueries).toHaveLength(4);
      expect(tokenCalls).toBe(2);

      fabricEdgeMode = "normal";
      await expect(adapter.getSnapshot()).resolves.toMatchObject({
        source: { projectionId: refreshed.source.projectionId },
      });
      expect(fabricQueries).toHaveLength(6);
      expect(tokenCalls).toBe(3);

      now = 2_000;
      fabricHttpFailure = true;
      const unavailableResults = await Promise.allSettled(
        Array.from({ length: 8 }, async () => adapter.getSnapshot()),
      );
      expect(unavailableResults.every((result) => result.status === "rejected")).toBe(true);
      expect(tokenCalls).toBe(4);

      fabricHttpFailure = false;
      await expect(adapter.getSnapshot()).resolves.toMatchObject({
        source: { projectionId: refreshed.source.projectionId },
      });
      expect(tokenCalls).toBe(5);
    } finally {
      activeFabricSnapshot = snapshot;
      fabricEdgeMode = "normal";
      fabricHttpFailure = false;
    }
  });

  it("does not replace the cached delegate when refreshed provenance violates its deployment pin", async () => {
    let now = 0;
    const adapter = new FabricGqlGraphAdapter({
      workspaceId: WORKSPACE_ID,
      graphModelId: GRAPH_MODEL_ID,
      expectedRepository: snapshot.source.repository,
      expectedProjectionId: snapshot.source.projectionId,
      expectedCommitSha: snapshot.source.commitSha,
      apiBaseUrl: origin,
      accessToken: "direct-fabric-test-token",
      snapshotTtlMs: 1_000,
      now: () => now,
      allowInsecureLocalhost: true,
    });

    try {
      await adapter.getSnapshot();
      activeFabricSnapshot = refreshedSnapshot(snapshot);
      now = 1_000;
      await expect(adapter.getSnapshot()).rejects.toThrow(/QAM_EXPECTED_PROJECTION_ID/u);

      activeFabricSnapshot = snapshot;
      await expect(adapter.getSnapshot()).resolves.toMatchObject({
        source: { projectionId: snapshot.source.projectionId },
      });
    } finally {
      activeFabricSnapshot = snapshot;
    }
  });

  it("rejects mixed or missing QamEdge snapshot provenance", async () => {
    for (const mode of ["mixed", "mixed-commit", "missing"] as const) {
      fabricEdgeMode = mode;
      try {
        const adapter = new FabricGqlGraphAdapter({
          workspaceId: WORKSPACE_ID,
          graphModelId: GRAPH_MODEL_ID,
          apiBaseUrl: origin,
          accessToken: "direct-fabric-test-token",
          allowInsecureLocalhost: true,
        });
        await expect(adapter.getSnapshot()).rejects.toThrow(/projection|missing required string field/u);
      } finally {
        fabricEdgeMode = "normal";
      }
    }
  });

  it("fails closed when Fabric projection provenance differs between rows", async () => {
    inconsistentFabricMetadata = true;
    try {
      const adapter = new FabricGqlGraphAdapter({
        workspaceId: WORKSPACE_ID,
        graphModelId: GRAPH_MODEL_ID,
        apiBaseUrl: origin,
        accessToken: "direct-fabric-test-token",
        allowInsecureLocalhost: true,
      });
      await expect(adapter.getSnapshot()).rejects.toThrow(/inconsistent projection provenance/u);
    } finally {
      inconsistentFabricMetadata = false;
    }
  });

  it("decodes every Fabric string-array field at its exact contract maxima", async () => {
    const cases = [
      {
        kind: "Concept",
        field: "tagsJson",
        count: GRAPH_CONTRACT_LIMITS.tags,
        itemLength: GRAPH_CONTRACT_LIMITS.tag,
      },
      {
        kind: "Concept",
        field: "aliasesJson",
        count: GRAPH_CONTRACT_LIMITS.aliases,
        itemLength: GRAPH_CONTRACT_LIMITS.alias,
      },
      {
        kind: "Source",
        field: "sourceIdsJson",
        count: GRAPH_CONTRACT_LIMITS.sourceIds,
        itemLength: GRAPH_CONTRACT_LIMITS.sourceId,
      },
      {
        kind: "Source",
        field: "authorsJson",
        count: GRAPH_CONTRACT_LIMITS.authors,
        itemLength: GRAPH_CONTRACT_LIMITS.author,
      },
    ] as const;

    for (const boundary of cases) {
      fabricStringArrayOverride = {
        kind: boundary.kind,
        field: boundary.field,
        values: [
          "x".repeat(boundary.itemLength),
          ...Array.from({ length: boundary.count - 1 }, (_, index) => `value-${index}`),
        ],
      };
      try {
        const adapter = new FabricGqlGraphAdapter({
          workspaceId: WORKSPACE_ID,
          graphModelId: GRAPH_MODEL_ID,
          apiBaseUrl: origin,
          accessToken: "direct-fabric-test-token",
          allowInsecureLocalhost: true,
        });
        await expect(adapter.getSnapshot()).resolves.toMatchObject({ schemaVersion: "qam-graph/1.0" });
      } finally {
        fabricStringArrayOverride = undefined;
      }
    }
  });

  it("rejects over-limit Fabric string-array counts and item lengths field by field", async () => {
    const cases = [
      {
        kind: "Concept",
        field: "tagsJson",
        count: GRAPH_CONTRACT_LIMITS.tags,
        itemLength: GRAPH_CONTRACT_LIMITS.tag,
      },
      {
        kind: "Concept",
        field: "aliasesJson",
        count: GRAPH_CONTRACT_LIMITS.aliases,
        itemLength: GRAPH_CONTRACT_LIMITS.alias,
      },
      {
        kind: "Source",
        field: "sourceIdsJson",
        count: GRAPH_CONTRACT_LIMITS.sourceIds,
        itemLength: GRAPH_CONTRACT_LIMITS.sourceId,
      },
      {
        kind: "Source",
        field: "authorsJson",
        count: GRAPH_CONTRACT_LIMITS.authors,
        itemLength: GRAPH_CONTRACT_LIMITS.author,
      },
    ] as const;

    for (const boundary of cases) {
      for (const values of [
        Array.from({ length: boundary.count + 1 }, (_, index) => `value-${index}`),
        ["x".repeat(boundary.itemLength + 1)],
      ]) {
        fabricStringArrayOverride = { kind: boundary.kind, field: boundary.field, values };
        try {
          const adapter = new FabricGqlGraphAdapter({
            workspaceId: WORKSPACE_ID,
            graphModelId: GRAPH_MODEL_ID,
            apiBaseUrl: origin,
            accessToken: "direct-fabric-test-token",
            allowInsecureLocalhost: true,
          });
          await expect(adapter.getSnapshot()).rejects.toThrow(/not a valid JSON string array/u);
        } finally {
          fabricStringArrayOverride = undefined;
        }
      }
    }
  });

  it("rejects token-exfiltration hosts and fails closed at fixed projection limits", () => {
    const credential = { getToken: async () => ({ token: "unused" }) };
    expect(
      () =>
        new FabricGqlGraphAdapter({
          workspaceId: WORKSPACE_ID,
          graphModelId: GRAPH_MODEL_ID,
          apiBaseUrl: "https://attacker.example",
          credential,
        }),
    ).toThrow(/tokens may be sent only/u);
    expect(
      () =>
        new FabricGqlGraphAdapter({
          workspaceId: WORKSPACE_ID,
          graphModelId: GRAPH_MODEL_ID,
          tokenScope: "https://attacker.example/.default",
          credential,
        }),
    ).toThrow(/scope is fixed/u);
    expect(() => assertProjectionWithinLimits(QAM_NODE_LIMIT - 1, QAM_EDGE_LIMIT - 1)).not.toThrow();
    expect(() => assertProjectionWithinLimits(QAM_NODE_LIMIT, 0)).toThrow(/potentially incomplete graph/u);
    expect(() => assertProjectionWithinLimits(1, QAM_EDGE_LIMIT)).toThrow(/potentially incomplete graph/u);
  });

  it("reads GitHub Markdown only by safe path and immutable SHA", async () => {
    const adapter = new GitHubContentAdapter({
      repository: "acme/wiki",
      apiBaseUrl: `${origin}/api/v3`,
      webBaseUrl: origin,
      auth: { mode: "token", token: "github-test-token-with-minimum-length" },
      allowInsecureLocalhost: true,
    });
    const result = await adapter.readMarkdown("quickagenticmemory/knowledge/concepts/example.md", FIXTURE_COMMIT);
    expect(result.content).toBe("# Remote example\n");
    expect(result.source_url).toBe(
      `${origin}/acme/wiki/blob/${FIXTURE_COMMIT}/quickagenticmemory/knowledge/concepts/example.md`,
    );
    await expect(adapter.readMarkdown("../secret.md", FIXTURE_COMMIT)).rejects.toThrow();
    await expect(adapter.readMarkdown("quickagenticmemory/knowledge/concepts/example.md", "main")).rejects.toThrow();
    await expect(
      adapter.readMarkdown("quickagenticmemory/knowledge/concepts/large.md", FIXTURE_COMMIT),
    ).rejects.toThrow(/2 MiB/u);
    await expect(
      adapter.readMarkdown("quickagenticmemory/knowledge/concepts/declared-large.md", FIXTURE_COMMIT),
    ).rejects.toThrow(/2 MiB/u);
  });

  it("exchanges a signed GitHub App JWT once and caches the installation token", async () => {
    const adapter = new GitHubContentAdapter({
      repository: "acme/wiki",
      apiBaseUrl: `${origin}/api/v3`,
      webBaseUrl: origin,
      auth: { mode: "app", appId: "123", installationId: "12345", privateKey: appPrivateKey },
      allowInsecureLocalhost: true,
      now: () => appNow,
    });

    await adapter.readMarkdown("quickagenticmemory/knowledge/concepts/example.md", FIXTURE_COMMIT);
    await adapter.readMarkdown("quickagenticmemory/knowledge/concepts/example.md", FIXTURE_COMMIT);
    expect(githubAppTokenExchanges).toBe(1);
    expect(githubAppTokenBodies).toEqual([
      { repositories: ["wiki"], permissions: { contents: "read" } },
    ]);
    expect(githubAppJwtClaims?.iss).toBe("123");
    expect(Number(githubAppJwtClaims?.exp) - Number(githubAppJwtClaims?.iat)).toBe(600);
  });

  it("invalidates an installation token on one 401, refreshes once, and does not loop", async () => {
    const exchangesBefore = githubAppTokenExchanges;
    rejectInstallationTokenOnce = true;
    const adapter = new GitHubContentAdapter({
      repository: "acme/wiki",
      apiBaseUrl: `${origin}/api/v3`,
      webBaseUrl: origin,
      auth: { mode: "app", appId: "123", installationId: "12345", privateKey: appPrivateKey },
      allowInsecureLocalhost: true,
      now: () => appNow,
    });
    await adapter.readMarkdown("quickagenticmemory/knowledge/concepts/example.md", FIXTURE_COMMIT);
    expect(githubAppTokenExchanges - exchangesBefore).toBe(2);
  });

  it("pins authenticated GitHub traffic to the official API host outside localhost tests", () => {
    expect(
      () =>
        new GitHubContentAdapter({
          repository: "acme/wiki",
          apiBaseUrl: "https://attacker.example",
          auth: { mode: "token", token: "github-test-token-with-minimum-length" },
        }),
    ).toThrow(/official github.com pair|pinned GHES origin/u);
    expect(
      () =>
        new GitHubContentAdapter({
          repository: "acme/wiki",
          apiBaseUrl: "https://github.enterprise.example/api/v3",
          webBaseUrl: "https://github.enterprise.example",
          auth: { mode: "token", token: "github-test-token-with-minimum-length" },
        }),
    ).not.toThrow();
    expect(
      () =>
        new GitHubContentAdapter({
          repository: "acme/wiki",
          apiBaseUrl: "https://api.enterprise.example/api/v3",
          webBaseUrl: "https://github.enterprise.example",
          auth: { mode: "token", token: "github-test-token-with-minimum-length" },
        }),
    ).toThrow(/same pinned GHES origin/u);
  });
});
