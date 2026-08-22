import { readFile } from "node:fs/promises";

import { afterEach, describe, expect, it } from "vitest";

import { serializeProjection, writeProjection } from "../src/exporter.js";
import { projectBundle } from "../src/projector.js";
import type { ConceptNode, SourceNode } from "../src/types.js";
import { createBundle, removeTemporaryDirectories, temporaryDirectory } from "./helpers.js";

afterEach(removeTemporaryDirectories);

const projectionOptions = {
  gitSha: "0123456789abcdef0123456789abcdef01234567",
  generatedAt: "2026-08-22T12:00:00+02:00",
  repository: "git@github.com:DittmannAxel/Where-the-Diagram-Ends.git",
  pathInRepository: "quickagenticmemory/knowledge",
};
const canonicalRepository = "https://github.com/DittmannAxel/Where-the-Diagram-Ends";

async function graphBundle(): Promise<string> {
  return createBundle({
    "index.md": `---
okf_version: "0.2"
---
# Concepts

* [Alpha](concepts/alpha.md) - Alpha concept
* [Beta](concepts/beta.md) - Beta concept
`,
    "concepts/alpha.md": `---
type: Architecture
title: Alpha
description: First architecture idea.
tags: [Azure, " azure "]
x-qam:
  uid: urn:uuid:alpha
  aliases: [First Idea, Primary]
sources:
  - id: azure-docs
    resource: https://learn.microsoft.com/azure/architecture
    title: Azure Architecture Center
    author: team:azure-docs
    usage_count: 10
    last_modified: 2026-08-20T00:00:00Z
---
See [Beta](./beta.md), [Beta again](./beta.md), and [future](./future.md).
`,
    "concepts/beta.md": `---
type: Concept
title: Beta
tags: [azure]
aliases: [Primary]
sources:
  - id: architecture
    resource: https://learn.microsoft.com/azure/architecture
    title: Official Azure docs
    usage_count: 20
---
Back to [Alpha](/concepts/alpha.md).
`,
  });
}

describe("deterministic graph projection", () => {
  it("projects Concept, Tag, Source, and Term nodes plus all edge kinds", async () => {
    const bundle = await graphBundle();
    const output = await projectBundle(bundle, projectionOptions);

    expect(output.manifest.counts).toEqual({ documents: 3, concepts: 2, nodes: 6, edges: 9 });
    expect(new Set(output.graph.nodes.map((node) => node.kind))).toEqual(
      new Set(["Concept", "Tag", "Source", "Term"]),
    );
    expect(new Set(output.graph.edges.map((edge) => edge.type))).toEqual(
      new Set(["LINKS_TO", "HAS_TAG", "DERIVED_FROM", "ALIASED_AS"]),
    );

    const alpha = output.graph.nodes.find(
      (node): node is ConceptNode => node.kind === "Concept" && node.path === "concepts/alpha.md",
    );
    expect(alpha).toMatchObject({
      title: "Alpha",
      summary: "First architecture idea.",
      repositoryPath: "quickagenticmemory/knowledge/concepts/alpha.md",
      tags: ["Azure"],
      aliases: ["First Idea", "Primary"],
      commitSha: projectionOptions.gitSha,
      sourceUrl:
        "https://github.com/DittmannAxel/Where-the-Diagram-Ends/blob/0123456789abcdef0123456789abcdef01234567/quickagenticmemory/knowledge/concepts/alpha.md",
    });

    const source = output.graph.nodes.find((node): node is SourceNode => node.kind === "Source");
    expect(source).toMatchObject({
      resource: "https://learn.microsoft.com/azure/architecture",
      title: "Azure Architecture Center",
      sourceIds: ["architecture", "azure-docs"],
      usageCounts: [10, 20],
      lastModified: "2026-08-20T00:00:00Z",
    });
    expect(output.graph.edges.filter((edge) => edge.type === "LINKS_TO")).toHaveLength(2);
    expect(output.graph.edges.filter((edge) => edge.type === "HAS_TAG")).toHaveLength(2);
    expect(output.graph.edges.filter((edge) => edge.type === "DERIVED_FROM")).toHaveLength(2);
    expect(output.graph.edges.filter((edge) => edge.type === "ALIASED_AS")).toHaveLength(3);
  });

  it("produces byte-identical JSON for identical content and metadata", async () => {
    const bundle = await graphBundle();
    const first = serializeProjection(await projectBundle(bundle, projectionOptions));
    const second = serializeProjection(await projectBundle(bundle, projectionOptions));

    expect(first).toEqual(second);
  });

  it("uses one immutable projection identity across nodes and edges", async () => {
    const bundle = await graphBundle();
    const first = await projectBundle(bundle, projectionOptions);
    const repeatedAtAnotherTime = await projectBundle(bundle, {
      ...projectionOptions,
      generatedAt: "2026-08-23T12:00:00+02:00",
    });

    expect(first.graph.source.projectionId).toMatch(/^urn:qam:projection:[a-f0-9]{64}$/u);
    expect(repeatedAtAnotherTime.graph.source.projectionId).toBe(first.graph.source.projectionId);
    expect(new Set(first.graph.nodes.map((node) => node.projectionId))).toEqual(
      new Set([first.graph.source.projectionId]),
    );
    expect(new Set(first.graph.edges.map((edge) => edge.projectionId))).toEqual(
      new Set([first.graph.source.projectionId]),
    );
    expect(new Set(first.graph.edges.map((edge) => edge.commitSha))).toEqual(
      new Set([projectionOptions.gitSha]),
    );
  });

  it("is independent of filesystem creation order", async () => {
    const alpha = "---\ntype: Concept\n---\n[Beta](beta.md)\n";
    const beta = "---\ntype: Concept\n---\nBody\n";
    const firstBundle = await createBundle({ "alpha.md": alpha, "beta.md": beta });
    const secondBundle = await createBundle({ "beta.md": beta, "alpha.md": alpha });

    expect(serializeProjection(await projectBundle(firstBundle, projectionOptions))).toEqual(
      serializeProjection(await projectBundle(secondBundle, projectionOptions)),
    );
  });

  it("keeps a concept node ID stable across file renames when an explicit uid is present", async () => {
    const firstBundle = await createBundle({
      "old-name.md": "---\ntype: Concept\nx-qam: { uid: urn:uuid:stable }\n---\nBody\n",
    });
    const secondBundle = await createBundle({
      "new-name.md": "---\ntype: Concept\nx-qam: { uid: urn:uuid:stable }\n---\nBody\n",
    });

    const first = await projectBundle(firstBundle, projectionOptions);
    const second = await projectBundle(secondBundle, projectionOptions);
    expect(first.graph.nodes.find((node) => node.kind === "Concept")?.id).toBe(
      second.graph.nodes.find((node) => node.kind === "Concept")?.id,
    );
  });

  it("does not merge concepts that accidentally share an explicit uid", async () => {
    const bundle = await createBundle({
      "one.md": "---\ntype: Concept\nx-qam: { uid: duplicate }\n---\nOne\n",
      "two.md": "---\ntype: Concept\nx-qam: { uid: duplicate }\n---\nTwo\n",
    });
    const output = await projectBundle(bundle, projectionOptions);
    const concepts = output.graph.nodes.filter((node) => node.kind === "Concept");

    expect(concepts).toHaveLength(2);
    expect(new Set(concepts.map((concept) => concept.id)).size).toBe(2);
    expect(output.validation.diagnostics).toContainEqual(
      expect.objectContaining({ code: "DUPLICATE_CONCEPT_UID", severity: "warning" }),
    );
  });

  it("sanitizes repository credentials and rejects credential-bearing source URL overrides", async () => {
    const bundle = await createBundle({ "one.md": "---\ntype: Concept\n---\nOne\n" });
    const output = await projectBundle(bundle, {
      ...projectionOptions,
      repository: "https://token:secret@github.com/example/repository.git",
    });
    expect(output.graph.source.repository).toBe("https://github.com/example/repository");
    expect(output.graph.nodes.find((node) => node.kind === "Concept")).toMatchObject({
      sourceUrl: `https://github.com/example/repository/blob/${projectionOptions.gitSha}/quickagenticmemory/knowledge/one.md`,
    });
    await expect(
      projectBundle(bundle, {
        ...projectionOptions,
        sourceBaseUrl: "https://token:secret@example.test/source",
      }),
    ).rejects.toThrow("must not contain credentials");
  });

  it("writes aggregate and split gateway-compatible JSON exports", async () => {
    const bundle = await graphBundle();
    const output = await projectBundle(bundle, projectionOptions);
    const directory = await temporaryDirectory("qam-output-");
    const paths = await writeProjection(output, directory);

    expect(paths.map((path) => path.split("/").at(-1))).toEqual([
      "edges.json",
      "edges.ndjson",
      "graph.json",
      "manifest.json",
      "nodes.json",
      "nodes.ndjson",
    ]);
    const graph = JSON.parse(await readFile(`${directory}/graph.json`, "utf8")) as Record<string, unknown>;
    expect(graph).toMatchObject({
      schemaVersion: "qam-graph/1.0",
      source: {
        repository: canonicalRepository,
        projectionId: expect.stringMatching(/^urn:qam:projection:[a-f0-9]{64}$/u),
        commitSha: projectionOptions.gitSha,
        generatedAt: projectionOptions.generatedAt,
      },
    });
    const nodeRows = (await readFile(`${directory}/nodes.ndjson`, "utf8"))
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(nodeRows).toHaveLength(output.graph.nodes.length);
    expect(nodeRows[0]).toMatchObject({
      kind: "Concept",
      tagsJson: expect.any(String),
      aliasesJson: expect.any(String),
      repositoryPath: expect.stringMatching(/^quickagenticmemory\/knowledge\/concepts\/(?:alpha|beta)\.md$/u),
      projectionId: output.graph.source.projectionId,
      commitSha: projectionOptions.gitSha,
      repository: canonicalRepository,
      projectionGeneratedAt: projectionOptions.generatedAt,
      okfVersion: "0.2",
    });
    expect(new Set(nodeRows.map((row) => row.repository))).toEqual(new Set([canonicalRepository]));
    expect(new Set(nodeRows.map((row) => row.projectionGeneratedAt))).toEqual(
      new Set([projectionOptions.generatedAt]),
    );
    expect(new Set(nodeRows.map((row) => row.okfVersion))).toEqual(new Set(["0.2"]));
    expect(Object.values(nodeRows[0] ?? {}).every((value) => value === null || typeof value !== "object")).toBe(
      true,
    );
    const edgeRows = (await readFile(`${directory}/edges.ndjson`, "utf8"))
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(edgeRows).toHaveLength(output.graph.edges.length);
    expect(Object.keys(edgeRows[0] ?? {})).toEqual([
      "id",
      "from",
      "to",
      "type",
      "projectionId",
      "commitSha",
      "label",
      "sourcePath",
    ]);
    expect(new Set(edgeRows.map((row) => row.projectionId))).toEqual(
      new Set([output.graph.source.projectionId]),
    );
    expect(new Set(edgeRows.map((row) => row.commitSha))).toEqual(new Set([projectionOptions.gitSha]));
  });

  it("keeps the checked-in gateway contract fixture synchronized", async () => {
    const fixtureRoot = "test/fixtures/okf";
    const actual = serializeProjection(
      await projectBundle(fixtureRoot, {
        gitSha: "0123456789abcdef0123456789abcdef01234567",
        generatedAt: "2026-08-22T12:00:00Z",
        repository: "https://github.com/example/where-diagram-ends",
        pathInRepository: "quickagenticmemory/knowledge",
      }),
    );

    await expect(readFile("test/fixtures/gateway-graph.json", "utf8")).resolves.toBe(actual["graph.json"]);
    await expect(readFile("test/fixtures/gateway-nodes.ndjson", "utf8")).resolves.toBe(actual["nodes.ndjson"]);
    await expect(readFile("test/fixtures/gateway-edges.ndjson", "utf8")).resolves.toBe(actual["edges.ndjson"]);
  });

  it("refuses invalid bundles and can make warnings fatal in strict mode", async () => {
    const invalid = await createBundle({ "invalid.md": "No frontmatter\n" });
    await expect(projectBundle(invalid, projectionOptions)).rejects.toThrow("cannot be projected");

    const warned = await createBundle({
      "warned.md": "---\ntype: Concept\n---\n[Missing](missing.md)\n",
    });
    await expect(projectBundle(warned, { ...projectionOptions, strict: true })).rejects.toThrow(
      "cannot be projected",
    );
  });
});
