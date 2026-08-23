import * as z from "zod/v4";

import { GatewayError } from "../errors.js";
import type { ProposalAdapter, WikiUpdateProposal } from "../types.js";
import { bearerHeaders, fetchWithTimeout, validateRemoteUrl } from "./http-utils.js";

const ProposalResponseSchema = z
  .object({
    proposal_id: z.string().min(1).max(500),
    status: z.enum(["draft", "submitted"]),
    target_path: z.string().min(1).max(1_024),
    base_commit_sha: z.string().min(1).max(64),
    proposal_url: z.url().nullable(),
  })
  .strict();

export class HttpProposalAdapter implements ProposalAdapter {
  public readonly kind = "http-proposal";
  readonly #endpoint: URL;
  readonly #token: string;
  readonly #timeoutMs: number;

  public constructor(options: { endpoint: string; token: string; timeoutMs?: number; allowInsecureLocalhost?: boolean }) {
    if (options.token === "") throw new GatewayError("Proposal adapter token must not be empty.", "configuration_error");
    this.#endpoint = validateRemoteUrl(options.endpoint, options.allowInsecureLocalhost ?? false);
    this.#token = options.token;
    this.#timeoutMs = options.timeoutMs ?? 15_000;
  }

  public async propose(input: {
    readonly conceptId?: string;
    readonly targetPath: string;
    readonly title: string;
    readonly rationale: string;
    readonly markdown: string;
    readonly baseCommitSha: string;
  }): Promise<WikiUpdateProposal> {
    const body: Record<string, string> = {
      target_path: input.targetPath,
      title: input.title,
      rationale: input.rationale,
      markdown: input.markdown,
      base_commit_sha: input.baseCommitSha,
    };
    if (input.conceptId !== undefined) body.concept_id = input.conceptId;
    const response = await fetchWithTimeout(
      this.#endpoint,
      {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", ...bearerHeaders(this.#token) },
        body: JSON.stringify(body),
      },
      this.#timeoutMs,
      "Wiki proposal endpoint",
    );
    try {
      return ProposalResponseSchema.parse(await response.json());
    } catch {
      throw new GatewayError("Wiki proposal endpoint returned an invalid response.", "adapter_error");
    }
  }
}
