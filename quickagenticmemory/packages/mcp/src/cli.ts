#!/usr/bin/env node

import { createAdapters } from "./adapters/factory.js";
import { loadGatewayConfig } from "./config.js";
import { publicErrorMessage } from "./errors.js";
import { loadHttpServerOptions, startHttpServer } from "./http.js";
import { startStdioServer } from "./stdio.js";

function selectedTransport(arguments_: readonly string[], environment: NodeJS.ProcessEnv): "http" | "stdio" {
  const argument = arguments_.find((value) => value.startsWith("--transport="));
  const value = argument?.slice("--transport=".length) ?? environment.QAM_TRANSPORT ?? "stdio";
  if (value !== "http" && value !== "stdio") {
    throw new Error("transport must be 'http' or 'stdio'");
  }
  return value;
}

async function main(): Promise<void> {
  const transport = selectedTransport(process.argv.slice(2), process.env);
  const adapters = await createAdapters(loadGatewayConfig());
  if (transport === "stdio") {
    const handle = startStdioServer(adapters);
    console.error("Quick Agentic Memory MCP listening on stdio");
    const close = (): void => {
      void handle.close().finally(() => {
        process.exitCode = 0;
      });
    };
    process.once("SIGINT", close);
    process.once("SIGTERM", close);
    return;
  }

  const server = await startHttpServer(adapters, loadHttpServerOptions());
  console.error(`Quick Agentic Memory MCP listening at ${server.url.toString()}`);
  const close = (): void => {
    void server.close().finally(() => {
      process.exitCode = 0;
    });
  };
  process.once("SIGINT", close);
  process.once("SIGTERM", close);
}

main().catch((error: unknown) => {
  console.error(`Quick Agentic Memory MCP failed: ${publicErrorMessage(error)}`);
  process.exitCode = 1;
});
