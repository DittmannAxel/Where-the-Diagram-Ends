import { describe, expect, it } from "vitest";

import { loadGatewayConfig } from "../../src/config.js";
import { GatewayError, redactedErrorForLog } from "../../src/errors.js";
import { GitShaSchema, GraphSnapshotSchema, RepoPathSchema } from "../../src/schemas.js";
import graph from "../fixtures/graph.json" with { type: "json" };

describe("security schemas", () => {
  it("accepts only immutable full Git SHAs", () => {
    expect(GitShaSchema.parse("a".repeat(40))).toBe("a".repeat(40));
    expect(() => GitShaSchema.parse("main")).toThrow(/full 40- or 64-character/u);
    expect(() => GitShaSchema.parse("A".repeat(40))).toThrow(/lowercase/u);
    expect(() => GitShaSchema.parse("a".repeat(7))).toThrow();
  });

  it("rejects absolute and traversing repository paths", () => {
    expect(RepoPathSchema.parse("knowledge/concepts/a.md")).toBe("knowledge/concepts/a.md");
    expect(() => RepoPathSchema.parse("../secret.md")).toThrow(/parent-directory/u);
    expect(() => RepoPathSchema.parse("/etc/passwd")).toThrow(/repository-relative/u);
    expect(() => RepoPathSchema.parse("knowledge//a.md")).toThrow(/empty/u);
  });

  it("validates graph referential integrity and commit consistency", () => {
    const snapshot = GraphSnapshotSchema.parse(graph);
    expect(snapshot.nodes).toHaveLength(10);
    expect(new Set(snapshot.nodes.map((node) => node.kind))).toEqual(new Set(["Concept", "Tag", "Source", "Term"]));
    const invalid = structuredClone(graph);
    invalid.edges[0]!.to = "qam:missing";
    expect(() => GraphSnapshotSchema.parse(invalid)).toThrow(/unknown edge target/u);

    const mixedProjection = structuredClone(graph);
    mixedProjection.edges[0]!.projectionId = `urn:qam:projection:${"0".repeat(64)}`;
    expect(() => GraphSnapshotSchema.parse(mixedProjection)).toThrow(/edge projectionId must match/u);
  });

  it("requires explicit, mutually exclusive GitHub authentication modes", () => {
    const base = { QAM_CONTENT_ADAPTER: "github", QAM_GITHUB_REPOSITORY: "acme/wiki" };
    expect(() => loadGatewayConfig({ ...base, QAM_GITHUB_TOKEN: "secret-token" })).toThrow(/explicit/u);
    expect(() =>
      loadGatewayConfig({
        ...base,
        QAM_GITHUB_AUTH_MODE: "app",
        QAM_GITHUB_APP_ID: "123",
        QAM_GITHUB_INSTALLATION_ID: "456",
        QAM_GITHUB_PRIVATE_KEY: "pem",
        QAM_GITHUB_TOKEN: "secret-token",
      }),
    ).toThrow(/mutually exclusive/u);
    const config = loadGatewayConfig({
      ...base,
      QAM_GITHUB_AUTH_MODE: "token",
      QAM_GITHUB_TOKEN: "token-with-at-least-twenty-characters",
    });
    expect(config.content.kind === "github" ? config.content.auth.mode : "wrong-adapter").toBe("token");
  });

  it("bounds the Fabric snapshot refresh TTL", () => {
    const base = {
      QAM_GRAPH_ADAPTER: "fabric-gql",
      QAM_FABRIC_WORKSPACE_ID: "11111111-1111-4111-8111-111111111111",
      QAM_FABRIC_GRAPH_MODEL_ID: "22222222-2222-4222-8222-222222222222",
    };
    const defaults = loadGatewayConfig(base);
    expect(defaults.graph.kind === "fabric-gql" ? defaults.graph.snapshotTtlMs : undefined).toBe(60_000);

    for (const ttl of ["1000", "300000"]) {
      const config = loadGatewayConfig({ ...base, QAM_FABRIC_SNAPSHOT_TTL_MS: ttl });
      expect(config.graph.kind === "fabric-gql" ? config.graph.snapshotTtlMs : undefined).toBe(Number(ttl));
    }
    for (const ttl of ["999", "300001", "1.5"]) {
      expect(() => loadGatewayConfig({ ...base, QAM_FABRIC_SNAPSHOT_TTL_MS: ttl })).toThrow(
        /QAM_FABRIC_SNAPSHOT_TTL_MS/u,
      );
    }
  });

  it("redacts exception details before server logging", () => {
    expect(redactedErrorForLog(new Error("private-key-material"))).toBe("Error(details=redacted)");
    expect(redactedErrorForLog(new GatewayError("sensitive-token", "adapter_error"))).toBe(
      "GatewayError(code=adapter_error; details=redacted)",
    );
  });
});
