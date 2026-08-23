import { createHash } from "node:crypto";

import { GatewayError } from "./errors.js";
import { MAX_RESPONSE_CHARACTERS } from "./schemas.js";
import type { GatewayAdapters, ReadConceptResult, WikiUpdateProposal } from "./types.js";

export class KnowledgeService {
  public constructor(public readonly adapters: GatewayAdapters) {}

  public async readConcepts(
    conceptIds: readonly string[],
    requestedCommitSha: string | undefined,
    maxCharactersPerDocument: number,
  ): Promise<{ repository: string; commit_sha: string; documents: readonly ReadConceptResult[] }> {
    const snapshot = await this.adapters.graph.getSnapshot();
    const commitSha = requestedCommitSha ?? snapshot.source.commitSha;
    if (commitSha !== snapshot.source.commitSha) {
      throw new GatewayError(
        `commit_sha '${commitSha}' does not match graph snapshot '${snapshot.source.commitSha}'. Refresh the graph before reading a different revision.`,
        "invalid_reference",
      );
    }

    const byId = new Map(snapshot.nodes.filter((node) => node.kind === "Concept").map((node) => [node.id, node]));
    const uniqueIds = [...new Set(conceptIds)];
    let remainingCharacters = MAX_RESPONSE_CHARACTERS;
    const documents: ReadConceptResult[] = [];

    for (const id of uniqueIds) {
      const concept = byId.get(id);
      if (concept === undefined) {
        throw new GatewayError(`Concept '${id}' was not found. Use resolve_concepts first.`, "not_found");
      }
      if (concept.commitSha !== commitSha) {
        throw new GatewayError(`Concept '${id}' is not indexed at commit '${commitSha}'.`, "invalid_reference");
      }
      const contentPath = this.adapters.content.pathScope === "repository" ? concept.repositoryPath : concept.path;
      const document = await this.adapters.content.readMarkdown(contentPath, commitSha);
      const actualHash = createHash("sha256").update(document.content, "utf8").digest("hex");
      if (actualHash !== concept.contentHash) {
        throw new GatewayError(
          `Markdown content for '${concept.id}' does not match the graph's content hash at commit '${commitSha}'.`,
          "invalid_reference",
        );
      }
      const characterLimit = Math.min(maxCharactersPerDocument, remainingCharacters);
      const originalCharacters = document.content.length;
      const content = document.content.slice(0, characterLimit);
      remainingCharacters -= content.length;
      documents.push({
        concept,
        document: { ...document, content },
        truncated: content.length < originalCharacters,
        original_characters: originalCharacters,
      });
    }

    return { repository: snapshot.source.repository, commit_sha: commitSha, documents };
  }

  public async proposeWikiUpdate(input: {
    readonly conceptId?: string;
    readonly targetPath: string;
    readonly title: string;
    readonly rationale: string;
    readonly markdown: string;
    readonly baseCommitSha: string;
  }): Promise<WikiUpdateProposal> {
    const adapter = this.adapters.proposals;
    if (adapter === undefined) {
      throw new GatewayError("Wiki proposals are disabled on this server.", "forbidden");
    }
    const snapshot = await this.adapters.graph.getSnapshot();
    if (input.baseCommitSha !== snapshot.source.commitSha) {
      throw new GatewayError("base_commit_sha must match the current graph snapshot.", "invalid_reference");
    }
    if (input.conceptId !== undefined && !snapshot.nodes.some((node) => node.kind === "Concept" && node.id === input.conceptId)) {
      throw new GatewayError(`Concept '${input.conceptId}' was not found.`, "not_found");
    }
    return adapter.propose(input);
  }
}
