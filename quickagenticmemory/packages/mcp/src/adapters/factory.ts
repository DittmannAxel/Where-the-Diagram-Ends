import type { GatewayConfig } from "../config.js";
import type { GatewayAdapters, GraphReadAdapter } from "../types.js";
import { FabricGqlGraphAdapter } from "./fabric-gql-graph.js";
import { FabricHttpGraphAdapter } from "./fabric-http-graph.js";
import { GitHubContentAdapter } from "./github-content.js";
import { HttpProposalAdapter } from "./http-proposal.js";
import { LocalJsonGraphAdapter } from "./local-json-graph.js";
import { LocalMarkdownContentAdapter } from "./local-markdown.js";

export async function createAdapters(config: GatewayConfig): Promise<GatewayAdapters> {
  let graph: GraphReadAdapter;
  if (config.graph.kind === "local") {
    graph = new LocalJsonGraphAdapter(config.graph.graphJsonPath);
  } else if (config.graph.kind === "fabric-http") {
    graph = new FabricHttpGraphAdapter({
          snapshotUrl: config.graph.snapshotUrl,
          ...(config.graph.token === undefined ? {} : { token: config.graph.token }),
          timeoutMs: config.graph.timeoutMs,
          allowInsecureLocalhost: config.graph.allowInsecureLocalhost,
        });
  } else {
    graph = new FabricGqlGraphAdapter({
      workspaceId: config.graph.workspaceId,
      graphModelId: config.graph.graphModelId,
      ...(config.graph.expectedRepository === undefined ? {} : { expectedRepository: config.graph.expectedRepository }),
      ...(config.graph.expectedProjectionId === undefined
        ? {}
        : { expectedProjectionId: config.graph.expectedProjectionId }),
      ...(config.graph.expectedCommitSha === undefined ? {} : { expectedCommitSha: config.graph.expectedCommitSha }),
      apiBaseUrl: config.graph.apiBaseUrl,
      tokenScope: config.graph.tokenScope,
      ...(config.graph.managedIdentityClientId === undefined ? {} : { managedIdentityClientId: config.graph.managedIdentityClientId }),
      ...(config.graph.accessToken === undefined ? {} : { accessToken: config.graph.accessToken }),
      timeoutMs: config.graph.timeoutMs,
      maxNodes: config.graph.maxNodes,
      maxEdges: config.graph.maxEdges,
      snapshotTtlMs: config.graph.snapshotTtlMs,
      allowInsecureLocalhost: config.graph.allowInsecureLocalhost,
    });
  }

  const snapshot = await graph.getSnapshot();
  const content =
    config.content.kind === "local"
      ? new LocalMarkdownContentAdapter(
          config.content.markdownRoot,
          config.content.expectedCommitSha ?? snapshot.source.commitSha,
        )
      : new GitHubContentAdapter({
          repository: config.content.repository,
          apiBaseUrl: config.content.apiBaseUrl,
          webBaseUrl: config.content.webBaseUrl,
          auth: config.content.auth,
          timeoutMs: config.content.timeoutMs,
          allowInsecureLocalhost: config.content.allowInsecureLocalhost,
        });

  const proposals = config.proposals.enabled
    ? new HttpProposalAdapter({
        endpoint: config.proposals.endpoint as string,
        token: config.proposals.token as string,
        timeoutMs: config.proposals.timeoutMs,
        allowInsecureLocalhost: config.proposals.allowInsecureLocalhost,
      })
    : undefined;

  return { graph, content, ...(proposals === undefined ? {} : { proposals }) };
}
