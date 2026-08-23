import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";
import * as z from "zod/v4";

import { FIXTURE_COMMIT, FIXTURE_GRAPH, FIXTURE_WIKI } from "../helpers.js";

const ReadResultSchema = z.object({
  commit_sha: z.string(),
  documents: z.array(z.object({ document: z.object({ content: z.string() }) })),
});

describe("stdio transport", () => {
  it("spawns the built CLI and reads SHA-pinned Markdown", async () => {
    const cli = fileURLToPath(new URL("../../dist/cli.js", import.meta.url));
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [cli, "--transport=stdio"],
      cwd: fileURLToPath(new URL("../..", import.meta.url)),
      env: {
        PATH: process.env.PATH ?? "",
        QAM_GRAPH_ADAPTER: "local",
        QAM_GRAPH_JSON_PATH: FIXTURE_GRAPH,
        QAM_CONTENT_ADAPTER: "local",
        QAM_MARKDOWN_ROOT: FIXTURE_WIKI,
      },
      stderr: "pipe",
    });
    const client = new Client({ name: "stdio-integration-test", version: "1.0.0" });
    try {
      await client.connect(transport);
      const result = await client.callTool({
        name: "read_concepts",
        arguments: { concept_ids: ["qam:mcp-gateway"], commit_sha: FIXTURE_COMMIT, response_format: "json" },
      });
      expect(result.isError).not.toBe(true);
      const output = ReadResultSchema.parse(result.structuredContent);
      expect(output.commit_sha).toBe(FIXTURE_COMMIT);
      expect(output.documents[0]?.document.content).toContain("Arbitrary");

      const invalid = await client.callTool({
        name: "read_concepts",
        arguments: { concept_ids: ["qam:mcp-gateway"], commit_sha: "main" },
      });
      expect(invalid.isError).toBe(true);
    } finally {
      await client.close();
    }
  });
});
