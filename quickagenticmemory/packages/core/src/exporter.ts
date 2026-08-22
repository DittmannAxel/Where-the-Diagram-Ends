import { mkdir, rename, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

import { GraphEdgeSchema, GraphNodeSchema } from "./qam-graph-contract.js";
import { assertProjectedGraphContract } from "./projector.js";
import type {
  FlatEdgeRow,
  FlatNodeProjectionMetadata,
  FlatNodeRow,
  GraphEdge,
  GraphNode,
  ProjectionOutput,
} from "./types.js";

export interface SerializedProjection {
  "graph.json": string;
  "nodes.json": string;
  "edges.json": string;
  "manifest.json": string;
  "nodes.ndjson": string;
  "edges.ndjson": string;
}

function json(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export function flattenNode(node: GraphNode, metadata: FlatNodeProjectionMetadata): FlatNodeRow {
  GraphNodeSchema.parse(node);
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
    projectionId: node.projectionId,
    commitSha: node.commitSha,
    repository: metadata.repository,
    projectionGeneratedAt: metadata.projectionGeneratedAt,
    okfVersion: metadata.okfVersion,
    summary: node.kind === "Concept" ? (node.summary ?? null) : null,
    resource:
      node.kind === "Concept" || node.kind === "Source" ? (node.resource ?? null) : null,
    status: node.kind === "Concept" ? node.status : null,
    contentHash: node.kind === "Concept" ? node.contentHash : null,
    sourceUrl: node.kind === "Concept" ? (node.sourceUrl ?? null) : null,
    normalizedValue: node.kind === "Tag" || node.kind === "Term" ? node.normalizedValue : null,
    sourceIdsJson: JSON.stringify(node.kind === "Source" ? node.sourceIds : []),
    authorsJson: JSON.stringify(node.kind === "Source" ? node.authors : []),
    usageCountsJson: JSON.stringify(node.kind === "Source" ? node.usageCounts : []),
    lastModified: node.kind === "Source" ? (node.lastModified ?? null) : null,
  };
}

export function flattenEdge(edge: GraphEdge): FlatEdgeRow {
  GraphEdgeSchema.parse(edge);
  return {
    id: edge.id,
    from: edge.from,
    to: edge.to,
    type: edge.type,
    projectionId: edge.projectionId,
    commitSha: edge.commitSha,
    label: edge.label ?? null,
    sourcePath: edge.sourcePath ?? null,
  };
}

function ndjson(rows: unknown[]): string {
  return rows.length === 0 ? "" : `${rows.map((row) => JSON.stringify(row)).join("\n")}\n`;
}

export function serializeProjection(output: ProjectionOutput): SerializedProjection {
  assertProjectedGraphContract(output.graph);
  const nodeMetadata: FlatNodeProjectionMetadata = {
    repository: output.graph.source.repository,
    projectionGeneratedAt: output.graph.source.generatedAt,
    okfVersion: output.graph.okfVersion,
  };
  return {
    "graph.json": json(output.graph),
    "nodes.json": json(output.graph.nodes),
    "edges.json": json(output.graph.edges),
    "manifest.json": json(output.manifest),
    "nodes.ndjson": ndjson(output.graph.nodes.map((node) => flattenNode(node, nodeMetadata))),
    "edges.ndjson": ndjson(output.graph.edges.map(flattenEdge)),
  };
}

async function atomicWrite(path: string, content: string): Promise<void> {
  const temporaryPath = `${path}.tmp-${process.pid}`;
  await writeFile(temporaryPath, content, { encoding: "utf8", mode: 0o644 });
  await rename(temporaryPath, path);
}

export async function writeProjection(output: ProjectionOutput, outputDirectory: string): Promise<string[]> {
  const directory = resolve(outputDirectory);
  await mkdir(directory, { recursive: true });
  const serialized = serializeProjection(output);
  const files = Object.entries(serialized).map(([filename, content]) => ({
    path: join(directory, filename),
    content,
  }));
  await Promise.all(files.map((file) => atomicWrite(file.path, file.content)));
  return files.map((file) => file.path).sort();
}
