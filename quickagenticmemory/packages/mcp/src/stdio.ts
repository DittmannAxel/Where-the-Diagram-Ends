import { serveStdio, type StdioServerHandle } from "@modelcontextprotocol/server/stdio";

import { redactedErrorForLog } from "./errors.js";
import { createGatewayServer } from "./server.js";
import type { GatewayAdapters } from "./types.js";

export function startStdioServer(adapters: GatewayAdapters): StdioServerHandle {
  return serveStdio(() => createGatewayServer(adapters), {
    onerror: (error) => console.error("MCP stdio error:", redactedErrorForLog(error)),
  });
}
