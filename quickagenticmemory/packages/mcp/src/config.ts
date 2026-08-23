import { resolve } from "node:path";

import { GatewayError } from "./errors.js";
import {
  QAM_FABRIC_SNAPSHOT_TTL_DEFAULT_MS,
  QAM_FABRIC_SNAPSHOT_TTL_MAX_MS,
  QAM_FABRIC_SNAPSHOT_TTL_MIN_MS,
} from "./fabric-settings.js";
import { GitShaSchema, MAX_GRAPH_EDGES, MAX_GRAPH_NODES, ProjectionIdSchema } from "./schemas.js";

export type GraphAdapterConfig =
  | { readonly kind: "local"; readonly graphJsonPath: string }
  | {
      readonly kind: "fabric-http";
      readonly snapshotUrl: string;
      readonly token?: string;
      readonly timeoutMs: number;
      readonly allowInsecureLocalhost: boolean;
    }
  | {
      readonly kind: "fabric-gql";
      readonly workspaceId: string;
      readonly graphModelId: string;
      readonly expectedRepository?: string;
      readonly expectedProjectionId?: string;
      readonly expectedCommitSha?: string;
      readonly apiBaseUrl: string;
      readonly tokenScope: string;
      readonly managedIdentityClientId?: string;
      readonly accessToken?: string;
      readonly timeoutMs: number;
      readonly maxNodes: number;
      readonly maxEdges: number;
      readonly snapshotTtlMs: number;
      readonly allowInsecureLocalhost: boolean;
    };

export type ContentAdapterConfig =
  | { readonly kind: "local"; readonly markdownRoot: string; readonly expectedCommitSha?: string }
  | {
      readonly kind: "github";
      readonly repository: string;
      readonly apiBaseUrl: string;
      readonly webBaseUrl: string;
      readonly auth:
        | { readonly mode: "none" }
        | { readonly mode: "token"; readonly token: string }
        | {
            readonly mode: "app";
            readonly appId: string;
            readonly installationId: string;
            readonly privateKey: string;
          };
      readonly timeoutMs: number;
      readonly allowInsecureLocalhost: boolean;
    };

export interface ProposalConfig {
  readonly enabled: boolean;
  readonly endpoint?: string;
  readonly token?: string;
  readonly timeoutMs: number;
  readonly allowInsecureLocalhost: boolean;
}

export interface GatewayConfig {
  readonly graph: GraphAdapterConfig;
  readonly content: ContentAdapterConfig;
  readonly proposals: ProposalConfig;
}

function integer(value: string | undefined, defaultValue: number, minimum: number, maximum: number, name: string): number {
  if (value === undefined || value === "") return defaultValue;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new GatewayError(`${name} must be an integer between ${minimum} and ${maximum}.`, "configuration_error");
  }
  return parsed;
}

function enabled(value: string | undefined): boolean {
  return value?.toLocaleLowerCase("en-US") === "true";
}

function required(value: string | undefined, name: string): string {
  if (value === undefined || value.trim() === "") {
    throw new GatewayError(`${name} is required for the selected adapter.`, "configuration_error");
  }
  return value;
}

export function loadGatewayConfig(environment: NodeJS.ProcessEnv = process.env): GatewayConfig {
  const timeoutMs = integer(environment.QAM_ADAPTER_TIMEOUT_MS, 15_000, 100, 120_000, "QAM_ADAPTER_TIMEOUT_MS");
  const allowInsecureLocalhost = enabled(environment.QAM_ALLOW_INSECURE_LOCALHOST_ADAPTERS);

  const graphKind = environment.QAM_GRAPH_ADAPTER ?? "local";
  let graph: GraphAdapterConfig;
  if (graphKind === "local") {
    graph = { kind: "local", graphJsonPath: resolve(environment.QAM_GRAPH_JSON_PATH ?? "graph.json") };
  } else if (graphKind === "fabric-http") {
    const token = environment.QAM_FABRIC_GRAPH_TOKEN;
    graph = {
      kind: "fabric-http",
      snapshotUrl: required(environment.QAM_FABRIC_GRAPH_SNAPSHOT_URL, "QAM_FABRIC_GRAPH_SNAPSHOT_URL"),
      ...(token === undefined || token === "" ? {} : { token }),
      timeoutMs,
      allowInsecureLocalhost,
    };
  } else if (graphKind === "fabric-gql") {
    const managedIdentityClientId = environment.QAM_AZURE_CLIENT_ID ?? environment.AZURE_CLIENT_ID;
    const accessToken = environment.QAM_FABRIC_ACCESS_TOKEN;
    const expectedRepository = environment.QAM_SOURCE_REPOSITORY;
    const expectedProjectionId = environment.QAM_EXPECTED_PROJECTION_ID;
    const expectedCommitSha = environment.QAM_EXPECTED_COMMIT_SHA;
    graph = {
      kind: "fabric-gql",
      workspaceId: required(environment.QAM_FABRIC_WORKSPACE_ID, "QAM_FABRIC_WORKSPACE_ID"),
      graphModelId: required(environment.QAM_FABRIC_GRAPH_MODEL_ID, "QAM_FABRIC_GRAPH_MODEL_ID"),
      ...(expectedRepository === undefined || expectedRepository === "" ? {} : { expectedRepository }),
      ...(expectedProjectionId === undefined || expectedProjectionId === ""
        ? {}
        : { expectedProjectionId: ProjectionIdSchema.parse(expectedProjectionId) }),
      ...(expectedCommitSha === undefined || expectedCommitSha === ""
        ? {}
        : { expectedCommitSha: GitShaSchema.parse(expectedCommitSha) }),
      apiBaseUrl: environment.QAM_FABRIC_API_URL ?? "https://api.fabric.microsoft.com",
      tokenScope: environment.QAM_FABRIC_TOKEN_SCOPE ?? "https://api.fabric.microsoft.com/.default",
      ...(managedIdentityClientId === undefined || managedIdentityClientId === "" ? {} : { managedIdentityClientId }),
      ...(accessToken === undefined || accessToken === "" ? {} : { accessToken }),
      timeoutMs,
      maxNodes: integer(environment.QAM_FABRIC_MAX_NODES, 10_000, 1, MAX_GRAPH_NODES, "QAM_FABRIC_MAX_NODES"),
      maxEdges: integer(environment.QAM_FABRIC_MAX_EDGES, 50_000, 1, MAX_GRAPH_EDGES, "QAM_FABRIC_MAX_EDGES"),
      snapshotTtlMs: integer(
        environment.QAM_FABRIC_SNAPSHOT_TTL_MS,
        QAM_FABRIC_SNAPSHOT_TTL_DEFAULT_MS,
        QAM_FABRIC_SNAPSHOT_TTL_MIN_MS,
        QAM_FABRIC_SNAPSHOT_TTL_MAX_MS,
        "QAM_FABRIC_SNAPSHOT_TTL_MS",
      ),
      allowInsecureLocalhost,
    };
  } else {
    throw new GatewayError("QAM_GRAPH_ADAPTER must be 'local', 'fabric-http', or 'fabric-gql'.", "configuration_error");
  }

  const contentKind = environment.QAM_CONTENT_ADAPTER ?? "local";
  let content: ContentAdapterConfig;
  if (contentKind === "local") {
    const expectedCommitSha = environment.QAM_EXPECTED_COMMIT_SHA;
    content = {
      kind: "local",
      markdownRoot: resolve(environment.QAM_MARKDOWN_ROOT ?? "."),
      ...(expectedCommitSha === undefined || expectedCommitSha === ""
        ? {}
        : { expectedCommitSha: GitShaSchema.parse(expectedCommitSha) }),
    };
  } else if (contentKind === "github") {
    const token = environment.QAM_GITHUB_TOKEN;
    const appId = environment.QAM_GITHUB_APP_ID;
    const installationId = environment.QAM_GITHUB_INSTALLATION_ID;
    const privateKey = environment.QAM_GITHUB_PRIVATE_KEY;
    const authMode = environment.QAM_GITHUB_AUTH_MODE ?? "none";
    const hasToken = token !== undefined && token !== "";
    const hasAnyAppField = [appId, installationId, privateKey].some((value) => value !== undefined && value !== "");
    let auth: Extract<ContentAdapterConfig, { readonly kind: "github" }>["auth"];
    if (authMode === "none") {
      if (hasToken || hasAnyAppField) {
        throw new GatewayError(
          "GitHub credentials require an explicit QAM_GITHUB_AUTH_MODE of 'app' or 'token'.",
          "configuration_error",
        );
      }
      auth = { mode: "none" };
    } else if (authMode === "token") {
      if (hasAnyAppField) {
        throw new GatewayError("GitHub App fields and token fallback are mutually exclusive.", "configuration_error");
      }
      auth = { mode: "token", token: required(token, "QAM_GITHUB_TOKEN") };
    } else if (authMode === "app") {
      if (hasToken) {
        throw new GatewayError("GitHub App fields and token fallback are mutually exclusive.", "configuration_error");
      }
      auth = {
        mode: "app",
        appId: required(appId, "QAM_GITHUB_APP_ID"),
        installationId: required(installationId, "QAM_GITHUB_INSTALLATION_ID"),
        privateKey: required(privateKey, "QAM_GITHUB_PRIVATE_KEY"),
      };
    } else {
      throw new GatewayError("QAM_GITHUB_AUTH_MODE must be 'none', 'app', or 'token'.", "configuration_error");
    }
    content = {
      kind: "github",
      repository: required(environment.QAM_GITHUB_REPOSITORY, "QAM_GITHUB_REPOSITORY"),
      apiBaseUrl: environment.QAM_GITHUB_API_URL ?? "https://api.github.com",
      webBaseUrl: environment.QAM_GITHUB_WEB_URL ?? "https://github.com",
      auth,
      timeoutMs,
      allowInsecureLocalhost,
    };
  } else {
    throw new GatewayError("QAM_CONTENT_ADAPTER must be 'local' or 'github'.", "configuration_error");
  }

  const proposalsEnabled = enabled(environment.QAM_ENABLE_PROPOSALS);
  const proposalToken = environment.QAM_PROPOSAL_TOKEN;
  const proposalEndpoint = environment.QAM_PROPOSAL_ENDPOINT;
  const proposals: ProposalConfig = {
    enabled: proposalsEnabled,
    ...(proposalEndpoint === undefined || proposalEndpoint === "" ? {} : { endpoint: proposalEndpoint }),
    ...(proposalToken === undefined || proposalToken === "" ? {} : { token: proposalToken }),
    timeoutMs,
    allowInsecureLocalhost,
  };
  if (proposalsEnabled && (proposals.endpoint === undefined || proposals.token === undefined)) {
    throw new GatewayError(
      "QAM_PROPOSAL_ENDPOINT and QAM_PROPOSAL_TOKEN are required when QAM_ENABLE_PROPOSALS=true.",
      "configuration_error",
    );
  }

  return { graph, content, proposals };
}
