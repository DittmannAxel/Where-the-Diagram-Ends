import { readFile, realpath, stat } from "node:fs/promises";
import { relative, resolve, sep } from "node:path";

import { GatewayError } from "../errors.js";
import { GitShaSchema, RepoPathSchema } from "../schemas.js";
import type { ContentReadAdapter, DocumentReadResult } from "../types.js";

const MAX_MARKDOWN_BYTES = 2 * 1024 * 1024;

export class LocalMarkdownContentAdapter implements ContentReadAdapter {
  public readonly kind = "local-markdown";
  public readonly pathScope = "bundle";
  readonly #root: string;
  readonly #commitSha: string;

  public constructor(root: string, commitSha: string) {
    this.#root = resolve(root);
    this.#commitSha = GitShaSchema.parse(commitSha);
  }

  public async readMarkdown(path: string, commitSha: string): Promise<DocumentReadResult> {
    const safePath = RepoPathSchema.parse(path);
    const safeSha = GitShaSchema.parse(commitSha);
    if (safeSha !== this.#commitSha) {
      throw new GatewayError(
        `Local fixture only represents commit '${this.#commitSha}', not '${safeSha}'. Use the graph snapshot SHA.`,
        "invalid_reference",
      );
    }
    if (!safePath.toLocaleLowerCase("en-US").endsWith(".md")) {
      throw new GatewayError("Only Markdown documents may be read through the content adapter.", "forbidden");
    }

    try {
      const realRoot = await realpath(this.#root);
      const realFile = await realpath(resolve(this.#root, safePath));
      const relativePath = relative(realRoot, realFile);
      if (relativePath.startsWith(`..${sep}`) || relativePath === ".." || relativePath.startsWith(sep)) {
        throw new GatewayError("The requested path escapes the configured Markdown root.", "forbidden");
      }

      const metadata = await stat(realFile);
      if (!metadata.isFile() || metadata.size > MAX_MARKDOWN_BYTES) {
        throw new GatewayError("The requested Markdown document is not a readable file or exceeds 2 MiB.", "forbidden");
      }
      const content = await readFile(realFile, "utf8");
      return { path: safePath, commit_sha: safeSha, content, source_url: null };
    } catch (error) {
      if (error instanceof GatewayError) throw error;
      throw new GatewayError(`Markdown document '${safePath}' was not found in the local knowledge root.`, "not_found");
    }
  }
}
