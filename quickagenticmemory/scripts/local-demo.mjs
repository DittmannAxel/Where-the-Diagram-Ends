import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

import { resetLocalDemoArtifacts } from "./lib/local-demo-artifacts.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(root, "..");
const knowledgeRoot = join(root, "knowledge");
const coreCli = join(root, "packages", "core", "dist", "cli.js");
const mcpCli = join(root, "packages", "mcp", "dist", "cli.js");

function invariant(condition, message) {
  if (!condition) throw new Error(message);
}

function runNode(script, args) {
  return execFileSync(process.execPath, [script, ...args], {
    cwd: repositoryRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function toolOutput(result, toolName) {
  invariant(result.isError !== true, `${toolName} returned an MCP error`);
  invariant(
    typeof result.structuredContent === "object" && result.structuredContent !== null,
    `${toolName} did not return structured content`,
  );
  return result.structuredContent;
}

for (const builtCli of [coreCli, mcpCli]) {
  invariant(existsSync(builtCli), `Missing ${builtCli}; run npm run build first.`);
}

const validation = JSON.parse(runNode(coreCli, ["validate", knowledgeRoot, "--json", "--strict"]));
invariant(validation.strictValid === true, "The example OKF bundle is not strict-valid.");

const artifactRoot = resetLocalDemoArtifacts(join(root, ".artifacts"));
runNode(coreCli, ["project", knowledgeRoot, "--output", artifactRoot, "--strict"]);

const manifest = JSON.parse(readFileSync(join(artifactRoot, "manifest.json"), "utf8"));
const graphPath = join(artifactRoot, "graph.json");
for (const expectedFile of ["graph.json", "manifest.json", "nodes.ndjson", "edges.ndjson"]) {
  invariant(existsSync(join(artifactRoot, expectedFile)), `Projection did not create ${expectedFile}.`);
}

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [mcpCli, "--transport=stdio"],
  cwd: root,
  env: {
    PATH: process.env.PATH ?? "",
    QAM_GRAPH_ADAPTER: "local",
    QAM_GRAPH_JSON_PATH: graphPath,
    QAM_CONTENT_ADAPTER: "local",
    QAM_MARKDOWN_ROOT: knowledgeRoot,
    QAM_EXPECTED_COMMIT_SHA: manifest.source.commitSha,
  },
  stderr: "pipe",
});
const client = new Client({ name: "quick-agentic-memory-local-demo", version: "0.1.0" });

try {
  await client.connect(transport);
  const tools = await client.listTools();
  const toolNames = tools.tools.map((tool) => tool.name).sort();
  const expectedTools = [
    "browse_index",
    "find_path",
    "get_backlinks",
    "get_neighbors",
    "read_concepts",
    "resolve_concepts",
    "trace_provenance",
  ];
  invariant(JSON.stringify(toolNames) === JSON.stringify(expectedTools), "The default MCP tool surface is not read-only.");

  const gatewayResolution = toolOutput(
    await client.callTool({
      name: "resolve_concepts",
      arguments: { terms: ["Wiki MCP gateway"], response_format: "json" },
    }),
    "resolve_concepts",
  );
  const storeResolution = toolOutput(
    await client.callTool({
      name: "resolve_concepts",
      arguments: { terms: ["GitHub enterprise memory"], response_format: "json" },
    }),
    "resolve_concepts",
  );
  const gateway = gatewayResolution.matches?.[0]?.concept;
  const store = storeResolution.matches?.[0]?.concept;
  invariant(gateway?.id !== undefined && store?.id !== undefined, "The demo concepts could not be resolved.");

  const path = toolOutput(
    await client.callTool({
      name: "find_path",
      arguments: {
        from_id: store.id,
        to_id: gateway.id,
        max_hops: 4,
        direction: "outgoing",
        response_format: "json",
      },
    }),
    "find_path",
  );
  invariant(path.found === true && path.hop_count >= 2, "No multi-hop graph path connects storage to the MCP gateway.");

  const backlinks = toolOutput(
    await client.callTool({
      name: "get_backlinks",
      arguments: { concept_id: gateway.id, response_format: "json" },
    }),
    "get_backlinks",
  );
  invariant(backlinks.total >= 1, "The MCP gateway has no projected backlinks.");

  const provenance = toolOutput(
    await client.callTool({
      name: "trace_provenance",
      arguments: { concept_id: gateway.id, response_format: "json" },
    }),
    "trace_provenance",
  );
  invariant(provenance.snapshot?.commitSha === manifest.source.commitSha, "Provenance commit does not match the manifest.");
  invariant(provenance.originating_edges?.length >= 1, "The MCP gateway has no source provenance.");

  const read = toolOutput(
    await client.callTool({
      name: "read_concepts",
      arguments: {
        concept_ids: [gateway.id],
        commit_sha: manifest.source.commitSha,
        response_format: "json",
      },
    }),
    "read_concepts",
  );
  const document = read.documents?.[0]?.document;
  invariant(document?.commit_sha === manifest.source.commitSha, "The Markdown read was not pinned to the projected commit.");
  invariant(document?.content.includes("default interface is read-only"), "The expected Markdown was not returned.");

  console.log("Quick Agentic Memory local proof passed.");
  console.log(`Commit: ${manifest.source.commitSha}`);
  console.log(`Projection: ${manifest.counts.nodes} nodes, ${manifest.counts.edges} edges`);
  console.log(`Shortest source-to-gateway path: ${path.hop_count} hop(s)`);
  console.log(`Default MCP tools: ${toolNames.length} read-only tools`);
  console.log(`Artifacts: ${artifactRoot}`);
} finally {
  await client.close();
}
