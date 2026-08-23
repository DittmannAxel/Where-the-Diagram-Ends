import { timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

import { hostHeaderValidation, originValidation, toNodeHandler } from "@modelcontextprotocol/node";
import { createMcpHandler } from "@modelcontextprotocol/server";

import { GatewayError, redactedErrorForLog } from "./errors.js";
import { createGatewayServer } from "./server.js";
import type { GatewayAdapters } from "./types.js";

const MAX_REQUEST_BYTES = 1024 * 1024;

export type HttpAuth =
  | { readonly mode: "none" }
  | { readonly mode: "bearer"; readonly token: string }
  | { readonly mode: "trusted-header"; readonly headerName: string };

export interface HttpServerOptions {
  readonly host: string;
  readonly port: number;
  readonly path?: string;
  readonly allowedHosts: readonly string[];
  readonly allowedOrigins: readonly string[];
  readonly auth: HttpAuth;
}

export interface RunningHttpServer {
  readonly server: Server;
  readonly url: URL;
  close(): Promise<void>;
}

function isLoopback(host: string): boolean {
  return host === "127.0.0.1" || host === "localhost" || host === "::1";
}

function safeTokenEquals(actual: string, expected: string): boolean {
  const actualBytes = Buffer.from(actual, "utf8");
  const expectedBytes = Buffer.from(expected, "utf8");
  return actualBytes.length === expectedBytes.length && timingSafeEqual(actualBytes, expectedBytes);
}

function authorize(req: IncomingMessage, res: ServerResponse, auth: HttpAuth): boolean {
  if (auth.mode === "none") return true;
  if (auth.mode === "trusted-header") {
    const value = req.headers[auth.headerName];
    if (typeof value === "string" && value.trim() !== "") return true;
  } else {
    const header = req.headers.authorization;
    if (typeof header === "string" && header.startsWith("Bearer ") && safeTokenEquals(header.slice(7), auth.token)) return true;
  }

  res.writeHead(401, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "WWW-Authenticate": "Bearer",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(JSON.stringify({ error: "unauthorized" }));
  return false;
}

async function parseBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as Uint8Array);
    size += buffer.length;
    if (size > MAX_REQUEST_BYTES) {
      throw new GatewayError("MCP request exceeds the 1 MiB limit.", "forbidden");
    }
    chunks.push(buffer);
  }
  if (chunks.length === 0) return undefined;
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
  } catch {
    throw new GatewayError("MCP request body is not valid JSON.", "invalid_reference");
  }
}

function requestError(res: ServerResponse, status: number, message: string): void {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  res.end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32_700, message }, id: null }));
}

export async function startHttpServer(adapters: GatewayAdapters, options: HttpServerOptions): Promise<RunningHttpServer> {
  if (options.auth.mode === "none" && !isLoopback(options.host)) {
    throw new GatewayError("Unauthenticated HTTP is allowed only on a loopback bind.", "configuration_error");
  }
  if (options.auth.mode === "bearer" && options.auth.token.length < 24) {
    throw new GatewayError("Bearer token must contain at least 24 characters.", "configuration_error");
  }
  if (options.allowedHosts.length === 0) {
    throw new GatewayError("At least one allowed Host hostname is required.", "configuration_error");
  }

  const mcpPath = options.path ?? "/mcp";
  if (!mcpPath.startsWith("/") || mcpPath.includes("?")) {
    throw new GatewayError("HTTP MCP path must be an absolute path without a query string.", "configuration_error");
  }

  const handler = createMcpHandler(() => createGatewayServer(adapters), {
    responseMode: "json",
    onerror: (error) => console.error("MCP HTTP handler error:", redactedErrorForLog(error)),
  });
  const nodeHandler = toNodeHandler(handler, {
    onerror: (error) => console.error("MCP Node adapter error:", redactedErrorForLog(error)),
  });
  const validateHost = hostHeaderValidation([...options.allowedHosts]);
  const validateOrigin = originValidation([...options.allowedOrigins]);

  const server = createServer((req, res) => {
    void (async () => {
      if (!validateHost(req, res) || !validateOrigin(req, res)) return;
      const requestUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
      if (requestUrl.pathname === "/healthz" && req.method === "GET") {
        res.writeHead(200, {
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
          "X-Content-Type-Options": "nosniff",
        });
        res.end(JSON.stringify({ status: "ok" }));
        return;
      }
      if (requestUrl.pathname !== mcpPath) {
        requestError(res, 404, "Not found");
        return;
      }
      if (!authorize(req, res, options.auth)) return;
      if (req.method !== "POST" && req.method !== "GET" && req.method !== "DELETE") {
        requestError(res, 405, "Method not allowed");
        return;
      }
      try {
        const parsedBody = req.method === "POST" ? await parseBody(req) : undefined;
        await nodeHandler(req as Parameters<typeof nodeHandler>[0], res, parsedBody);
      } catch (error) {
        const status = error instanceof GatewayError && error.code === "forbidden" ? 413 : 400;
        requestError(res, status, error instanceof Error ? error.message : "Invalid request");
      }
    })();
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(options.port, options.host, () => {
      server.off("error", reject);
      resolve();
    });
  });
  const address = server.address();
  if (address === null || typeof address === "string") {
    await handler.close();
    throw new GatewayError("HTTP server did not expose a TCP address.", "adapter_error");
  }
  const displayHost = options.host === "::1" ? "[::1]" : options.host;
  const url = new URL(`http://${displayHost}:${address.port}${mcpPath}`);
  return {
    server,
    url,
    async close(): Promise<void> {
      await handler.close();
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error === undefined ? resolve() : reject(error)));
      });
    },
  };
}

function splitList(value: string | undefined, fallback: readonly string[]): string[] {
  const values = value?.split(",").map((entry) => entry.trim()).filter((entry) => entry !== "") ?? [];
  return values.length > 0 ? values : [...fallback];
}

export function loadHttpServerOptions(environment: NodeJS.ProcessEnv = process.env): HttpServerOptions {
  const host = environment.QAM_HTTP_HOST ?? "127.0.0.1";
  const rawPort = environment.QAM_HTTP_PORT ?? environment.PORT ?? "3000";
  const port = Number(rawPort);
  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    throw new GatewayError("QAM_HTTP_PORT must be an integer between 0 and 65535.", "configuration_error");
  }

  const defaultHosts = isLoopback(host)
    ? [host, ...(host === "127.0.0.1" ? ["localhost"] : [])]
    : [environment.WEBSITE_HOSTNAME, environment.CONTAINER_APP_HOSTNAME].filter(
        (value): value is string => value !== undefined && value !== "",
      );
  const allowedHosts = splitList(environment.QAM_HTTP_ALLOWED_HOSTS, defaultHosts);
  const allowedOrigins = splitList(environment.QAM_HTTP_ALLOWED_ORIGINS, isLoopback(host) ? [host, "localhost"] : allowedHosts);

  const authMode = environment.QAM_HTTP_AUTH_MODE ?? (environment.QAM_MCP_BEARER_TOKEN === undefined ? "none" : "bearer");
  let auth: HttpAuth;
  if (authMode === "none") {
    auth = { mode: "none" };
  } else if (authMode === "bearer") {
    const token = environment.QAM_MCP_BEARER_TOKEN;
    if (token === undefined || token === "") {
      throw new GatewayError("QAM_MCP_BEARER_TOKEN is required for bearer authentication.", "configuration_error");
    }
    auth = { mode: "bearer", token };
  } else if (authMode === "trusted-header") {
    const headerName = (environment.QAM_TRUSTED_IDENTITY_HEADER ?? "x-ms-client-principal-id").toLocaleLowerCase("en-US");
    if (!/^[a-z0-9-]+$/u.test(headerName)) {
      throw new GatewayError("QAM_TRUSTED_IDENTITY_HEADER is not a valid HTTP header name.", "configuration_error");
    }
    auth = { mode: "trusted-header", headerName };
  } else {
    throw new GatewayError("QAM_HTTP_AUTH_MODE must be 'none', 'bearer', or 'trusted-header'.", "configuration_error");
  }

  return { host, port, path: environment.QAM_HTTP_PATH ?? "/mcp", allowedHosts, allowedOrigins, auth };
}
