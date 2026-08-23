import { createPrivateKey, sign, type KeyObject } from "node:crypto";

import * as z from "zod/v4";

import { GatewayError } from "../errors.js";
import { GitShaSchema, RepoPathSchema } from "../schemas.js";
import type { ContentReadAdapter, DocumentReadResult } from "../types.js";
import { fetchResponseWithTimeout, fetchWithTimeout, validateRemoteUrl } from "./http-utils.js";

const REPOSITORY = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/u;
const POSITIVE_DECIMAL_ID = /^[1-9][0-9]{0,19}$/u;
const MAX_MARKDOWN_BYTES = 2 * 1024 * 1024;
const MAX_TOKEN_RESPONSE_BYTES = 64 * 1024;
const GITHUB_API_ORIGIN = "https://api.github.com";
const TOKEN_REFRESH_SKEW_MS = 5 * 60 * 1_000;

const InstallationTokenSchema = z
  .object({
    token: z.string().min(20).max(2_000),
    expires_at: z.iso.datetime({ offset: true }),
  })
  .loose();

export type GitHubContentAuth =
  | { readonly mode: "none" }
  | { readonly mode: "token"; readonly token: string }
  | {
      readonly mode: "app";
      readonly appId: string;
      readonly installationId: string;
      readonly privateKey: string;
    };

type RuntimeAuth =
  | { readonly mode: "none" }
  | { readonly mode: "token"; readonly token: string }
  | {
      readonly mode: "app";
      readonly appId: string;
      readonly installationId: string;
      readonly privateKey: KeyObject;
    };

async function readBoundedUtf8(response: Response, maximumBytes: number, errorMessage: string): Promise<string> {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null) {
    const declaredBytes = Number(contentLength);
    if (!Number.isSafeInteger(declaredBytes) || declaredBytes < 0 || declaredBytes > maximumBytes) {
      throw new GatewayError(errorMessage, "forbidden");
    }
  }
  if (response.body === null) return "";

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      bytes += part.value.byteLength;
      if (bytes > maximumBytes) {
        await reader.cancel();
        throw new GatewayError(errorMessage, "forbidden");
      }
      chunks.push(part.value);
    }
  } finally {
    reader.releaseLock();
  }

  const combined = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    combined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(combined);
}

function isLocalhost(url: URL): boolean {
  return url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]";
}

function normalizedBasePath(url: URL): string {
  const path = url.pathname.replace(/\/+$/u, "");
  return path === "" ? "/" : path;
}

function isPinnedGitHubPair(apiBaseUrl: URL, webBaseUrl: URL, allowLocalhost: boolean): boolean {
  if (apiBaseUrl.search !== "" || apiBaseUrl.hash !== "" || webBaseUrl.search !== "" || webBaseUrl.hash !== "") {
    return false;
  }
  const apiPath = normalizedBasePath(apiBaseUrl);
  const webPath = normalizedBasePath(webBaseUrl);
  const official =
    apiBaseUrl.origin === GITHUB_API_ORIGIN &&
    apiPath === "/" &&
    webBaseUrl.origin === "https://github.com" &&
    webPath === "/";
  if (official) return true;

  const sameOriginEnterprise =
    apiBaseUrl.origin === webBaseUrl.origin && apiPath === "/api/v3" && webPath === "/";
  if (!sameOriginEnterprise) return false;
  if (apiBaseUrl.protocol === "https:") return true;
  return allowLocalhost && isLocalhost(apiBaseUrl) && isLocalhost(webBaseUrl);
}

function jwtPart(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

export interface GitHubContentAdapterOptions {
  readonly repository: string;
  readonly apiBaseUrl?: string;
  readonly webBaseUrl?: string;
  readonly auth?: GitHubContentAuth;
  readonly timeoutMs?: number;
  readonly allowInsecureLocalhost?: boolean;
  /** Injectable clock for deterministic token-cache tests; never configured by an MCP caller. */
  readonly now?: () => number;
}

export class GitHubContentAdapter implements ContentReadAdapter {
  public readonly kind = "github";
  public readonly pathScope = "repository";
  readonly #repository: string;
  readonly #repositoryName: string;
  readonly #apiBaseUrl: URL;
  readonly #webBaseUrl: URL;
  readonly #auth: RuntimeAuth;
  readonly #timeoutMs: number;
  readonly #now: () => number;
  #cachedInstallationToken: { readonly token: string; readonly expiresAt: number } | undefined;
  #installationTokenRefresh: Promise<string> | undefined;

  public constructor(options: GitHubContentAdapterOptions) {
    if (!REPOSITORY.test(options.repository)) {
      throw new GatewayError("QAM_GITHUB_REPOSITORY must use the 'owner/repository' form.", "configuration_error");
    }
    this.#repository = options.repository;
    this.#repositoryName = options.repository.slice(options.repository.indexOf("/") + 1);
    const allowInsecureLocalhost = options.allowInsecureLocalhost ?? false;
    this.#apiBaseUrl = validateRemoteUrl(options.apiBaseUrl ?? GITHUB_API_ORIGIN, allowInsecureLocalhost);
    this.#webBaseUrl = validateRemoteUrl(options.webBaseUrl ?? "https://github.com", allowInsecureLocalhost);
    const auth = options.auth ?? { mode: "none" };
    if (!isPinnedGitHubPair(this.#apiBaseUrl, this.#webBaseUrl, allowInsecureLocalhost)) {
      throw new GatewayError(
        "GitHub API and web bases must be the official github.com pair or the same pinned GHES origin with /api/v3.",
        "configuration_error",
      );
    }

    const authRecord = auth as unknown as Readonly<Record<string, unknown>>;
    const hasTokenField = "token" in authRecord;
    const hasAppField = "appId" in authRecord || "installationId" in authRecord || "privateKey" in authRecord;
    if (
      (auth.mode === "none" && (hasTokenField || hasAppField)) ||
      (auth.mode === "token" && hasAppField) ||
      (auth.mode === "app" && hasTokenField)
    ) {
      throw new GatewayError("GitHub App and token authentication fields are mutually exclusive.", "configuration_error");
    }

    if (auth.mode === "none") {
      this.#auth = auth;
    } else if (auth.mode === "token") {
      if (auth.token.trim().length < 20) {
        throw new GatewayError("QAM_GITHUB_TOKEN must contain at least 20 characters.", "configuration_error");
      }
      this.#auth = auth;
    } else {
      if (!POSITIVE_DECIMAL_ID.test(auth.appId) || !POSITIVE_DECIMAL_ID.test(auth.installationId)) {
        throw new GatewayError("GitHub App and installation IDs must be positive decimal identifiers.", "configuration_error");
      }
      let privateKey: KeyObject;
      try {
        privateKey = createPrivateKey(auth.privateKey);
      } catch {
        throw new GatewayError("QAM_GITHUB_PRIVATE_KEY must be a valid PEM RSA private key.", "configuration_error");
      }
      if (privateKey.asymmetricKeyType !== "rsa") {
        throw new GatewayError("QAM_GITHUB_PRIVATE_KEY must contain an RSA private key for RS256.", "configuration_error");
      }
      this.#auth = { ...auth, privateKey };
    }
    this.#timeoutMs = options.timeoutMs ?? 15_000;
    this.#now = options.now ?? Date.now;
  }

  public async readMarkdown(repositoryPath: string, commitSha: string): Promise<DocumentReadResult> {
    const safePath = RepoPathSchema.parse(repositoryPath);
    const safeSha = GitShaSchema.parse(commitSha);
    if (!safePath.toLocaleLowerCase("en-US").endsWith(".md")) {
      throw new GatewayError("Only Markdown documents may be read through the GitHub adapter.", "forbidden");
    }

    const repository = this.#repository.split("/").map(encodeURIComponent).join("/");
    const encodedPath = safePath.split("/").map(encodeURIComponent).join("/");
    const url = new URL(`repos/${repository}/contents/${encodedPath}`, this.#ensureTrailingSlash(this.#apiBaseUrl));
    url.searchParams.set("ref", safeSha);

    const response = await this.#fetchMarkdown(url, safePath);
    const contentType = response.headers.get("content-type") ?? "";
    if (
      !contentType.includes("text/plain") &&
      !contentType.includes("application/octet-stream") &&
      !contentType.includes("application/vnd.github.raw")
    ) {
      throw new GatewayError("GitHub returned an unexpected content type for a Markdown document.", "adapter_error");
    }
    const content = await readBoundedUtf8(
      response,
      MAX_MARKDOWN_BYTES,
      "GitHub Markdown content exceeds the 2 MiB download limit.",
    );
    const sourceUrl = new URL(`${this.#repository}/blob/${safeSha}/${encodedPath}`, this.#ensureTrailingSlash(this.#webBaseUrl));
    return { path: safePath, commit_sha: safeSha, content, source_url: sourceUrl.toString() };
  }

  async #authorizationHeader(): Promise<Record<string, string>> {
    if (this.#auth.mode === "none") return {};
    const token = this.#auth.mode === "token" ? this.#auth.token : await this.#installationToken();
    return { Authorization: `Bearer ${token}` };
  }

  async #fetchMarkdown(url: URL, safePath: string): Promise<Response> {
    const request = async (): Promise<Response> =>
      fetchResponseWithTimeout(
        url,
        {
          headers: {
            Accept: "application/vnd.github.raw+json",
            "X-GitHub-Api-Version": "2022-11-28",
            ...(await this.#authorizationHeader()),
          },
        },
        this.#timeoutMs,
        `GitHub Markdown document '${safePath}'`,
      );

    let response = await request();
    if (response.status === 401 && this.#auth.mode === "app") {
      await response.body?.cancel();
      this.#cachedInstallationToken = undefined;
      response = await request();
    }
    if (!response.ok) {
      throw new GatewayError(`GitHub Markdown document '${safePath}' returned HTTP ${response.status}.`, "adapter_error");
    }
    return response;
  }

  async #installationToken(): Promise<string> {
    if (this.#auth.mode !== "app") {
      throw new GatewayError("GitHub App authentication is not configured.", "configuration_error");
    }
    const now = this.#now();
    if (
      this.#cachedInstallationToken !== undefined &&
      now < this.#cachedInstallationToken.expiresAt - TOKEN_REFRESH_SKEW_MS
    ) {
      return this.#cachedInstallationToken.token;
    }
    if (this.#installationTokenRefresh !== undefined) return this.#installationTokenRefresh;
    this.#installationTokenRefresh = this.#exchangeInstallationToken().finally(() => {
      this.#installationTokenRefresh = undefined;
    });
    return this.#installationTokenRefresh;
  }

  async #exchangeInstallationToken(): Promise<string> {
    if (this.#auth.mode !== "app") {
      throw new GatewayError("GitHub App authentication is not configured.", "configuration_error");
    }
    const endpoint = new URL(
      `app/installations/${encodeURIComponent(this.#auth.installationId)}/access_tokens`,
      this.#ensureTrailingSlash(this.#apiBaseUrl),
    );
    const response = await fetchWithTimeout(
      endpoint,
      {
        method: "POST",
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${this.#appJwt()}`,
          "Content-Type": "application/json",
          "X-GitHub-Api-Version": "2022-11-28",
        },
        body: JSON.stringify({
          repositories: [this.#repositoryName],
          permissions: { contents: "read" },
        }),
      },
      this.#timeoutMs,
      "GitHub App installation token exchange",
    );
    let parsed: z.infer<typeof InstallationTokenSchema>;
    try {
      const body = await readBoundedUtf8(
        response,
        MAX_TOKEN_RESPONSE_BYTES,
        "GitHub App token response exceeds the 64 KiB limit.",
      );
      parsed = InstallationTokenSchema.parse(JSON.parse(body) as unknown);
    } catch (error) {
      if (error instanceof GatewayError) throw error;
      throw new GatewayError("GitHub App token exchange returned an invalid response.", "adapter_error");
    }
    const expiresAt = Date.parse(parsed.expires_at);
    if (!Number.isFinite(expiresAt) || expiresAt <= this.#now()) {
      throw new GatewayError("GitHub App installation token is already expired.", "adapter_error");
    }
    this.#cachedInstallationToken = { token: parsed.token, expiresAt };
    return parsed.token;
  }

  #appJwt(): string {
    if (this.#auth.mode !== "app") {
      throw new GatewayError("GitHub App authentication is not configured.", "configuration_error");
    }
    const nowSeconds = Math.floor(this.#now() / 1_000);
    const header = jwtPart({ alg: "RS256", typ: "JWT" });
    const claims = jwtPart({ iat: nowSeconds - 60, exp: nowSeconds + 9 * 60, iss: this.#auth.appId });
    const signingInput = `${header}.${claims}`;
    const signature = sign("RSA-SHA256", Buffer.from(signingInput, "ascii"), this.#auth.privateKey).toString("base64url");
    return `${signingInput}.${signature}`;
  }

  #ensureTrailingSlash(url: URL): URL {
    const result = new URL(url);
    if (!result.pathname.endsWith("/")) result.pathname += "/";
    return result;
  }
}
