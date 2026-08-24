# Quick Agentic Memory architecture

Quick Agentic Memory adds a version-controlled, commit-pinned knowledge dimension to existing enterprise data without moving or replacing the systems that own that data. GitHub is the durable record and native review surface for the added knowledge; Microsoft Fabric Graph is a disposable navigation index; Microsoft Foundry reaches both through a narrow MCP gateway.

This proof of concept uses these names deliberately:

| Component | Responsibility |
| --- | --- |
| Wiki Curator | Future GitHub proposal service behind the already gated MCP proposal transport. It may create a branch, commit, and pull request against an exact base commit; it never approves its own change, writes to the protected branch, or edits the graph directly. |
| Markdown Validator | Parses and validates the human-readable `.md` files, lightweight metadata, and explicit links used by the reference implementation. |
| Fabric Graph Projector | Deterministically maps concepts, links, tags, aliases, and sources into nodes and edges. The graph is a generated projection, not a second knowledge record. |
| Wiki MCP Gateway | Gives agents bounded graph-navigation and commit-pinned content tools. |

## Inspiration and independent scope

[Andrej Karpathy's persistent, compounding wiki sketch](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) is a design influence: useful knowledge should accumulate in a durable, inspectable form instead of disappearing inside a chat. This PoC independently explores that principle with version-controlled Markdown, commit-pinned provenance, a disposable graph index, and constrained retrieval. It does not copy code from the gist.

## GitHub-native knowledge governance

QAM deliberately separates the read plane from the authoring and approval plane. It does not need a custom workflow engine for wiki maintenance because GitHub already provides the right primitives:

1. A proposed Markdown change starts from an exact base commit on a separate branch.
2. A pull request exposes the diff, rationale, sources, and link changes for human review.
3. The checked-in [`QAM validate`](../../.github/workflows/qam-validate.yml) workflow runs on relevant pull requests and validates the knowledge set, infrastructure, code, tests, secrets, local demo, Foundry integration, and deployable image.
4. Repository [rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets), required reviews, and [CODEOWNERS](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners) can make those checks and approvals mandatory before merge.
5. The projector accepts the resulting merged commit as a new immutable input and rebuilds the Fabric index from it.

The current published Foundry application remains strictly read-only. The MCP package implements a disabled-by-default `propose_wiki_update` transport to an external endpoint, but this repository does not yet implement the GitHub service that creates the branch, commit, and pull request. It also cannot create repository rulesets, CODEOWNERS, or reviewer policy as part of an Azure deployment; those controls are GitHub administrator configuration. QAM therefore demonstrates a governed, commit-pinned read path and a defined native approval boundary, not yet a complete agent-driven authoring lifecycle.

## Canonical graph contract

[`qam-graph/1.0`](../contracts/) is the executable boundary between Core, the flat Fabric tables, and MCP. It fixes node and edge shapes, provenance fields, identifiers, relationships, safe repository paths, timestamps, and size limits. Core validates a complete snapshot before returning it and again before JSON or NDJSON serialization; MCP executes a byte-identical generated copy when reading local JSON or reconstructing Fabric results. Package tests fail if either generated copy drifts from the canonical source.

Invalid or oversized values fail closed rather than being truncated into a different graph. Every node and edge must agree with the snapshot's `projectionId` and full Git `commitSha`, edge endpoints must exist, and concept paths and node/edge IDs must be unique.

## System context

![Quick Agentic Memory system context](diagrams/system-context.png)

Microsoft Fabric services are shown directly inside the Microsoft Azure boundary; Fabric is part of Azure, not a separate external platform in this architecture.

1. A GitHub workflow checks out an exact commit and validates the linked `.md` knowledge set.
2. The projector creates a deterministic `qam-graph/1.0` snapshot, manifest, and flat `QamNode`/`QamEdge` NDJSON tables containing that source commit.
3. Publication writes both NDJSON files below a unique OneLake temporary directory, reads them back, verifies exact byte counts and SHA-256 hashes, and atomically renames the complete directory without replacing an existing target. A pre-existing target is accepted only when both files are byte-identical.
4. A Fabric notebook validates the immutable pair and writes the `QamNode` and `QamEdge` Delta tables. The publisher applies the canonical GraphModel definition, starts the official on-demand `RefreshGraph` job only after both writes succeed, and polls its exact Core job instance to a successful terminal state before GQL acceptance.
5. A published Microsoft Foundry Agent Application uses a secretless `ProjectManagedIdentity` RemoteTool connection. The Foundry project's system-assigned identity calls the MCP gateway over Entra-authenticated HTTPS; the application's distinct identity remains the publication/invocation boundary.
6. The gateway runs only fixed `QamNode`/`QamEdge` GQL reads through Fabric's preview Query API, then uses a selected-repository GitHub App to read only the selected Markdown source at the pinned revision.

The local test path uses the same interfaces with JSON and filesystem adapters. That makes the complete retrieval flow testable without pretending that a local test is a live Fabric deployment. Fabric currently builds graphs from structured OneLake tables and requires the GraphModel mapping to exist; the project does not claim an undocumented automatic schema-creation API. See [how graph in Microsoft Fabric works](https://learn.microsoft.com/fabric/graph/how-graph-works) and the [GQL Query API](https://learn.microsoft.com/fabric/graph/gql-query-api).

The MCP surface contains exactly seven bounded read-only tools:

| Tool | Boundary |
| --- | --- |
| `browse_index` | Paged concept browsing by known fields. |
| `resolve_concepts` | Bounded term-to-concept resolution. |
| `get_neighbors` | Bounded graph traversal from an identified concept. |
| `get_backlinks` | Paged incoming concept references. |
| `find_path` | Bounded shortest-path search. |
| `read_concepts` | Hash-verified Markdown at the graph's immutable commit. |
| `trace_provenance` | One concept's projection and source lineage. |

## Azure deployment

![Quick Agentic Memory Azure deployment](diagrams/azure-deployment.png)

The deployment view uses the same boundary: Microsoft Fabric Graph is an Azure service inside the Microsoft Azure environment.

The supplied Bicep and workflows provision or configure:

- Azure Container Registry for the MCP image.
- Azure Container Apps for the stateless HTTP MCP service.
- Separate user-assigned managed identities for image pull and Container App runtime access.
- Azure Key Vault for the selected-repository GitHub App's PEM private key, referenced by the runtime identity; the installation token is short-lived and requested with `Contents: read` for exactly that repository.
- Log Analytics for Container Apps platform/console telemetry and an Entra-ready Application Insights target for later application tracing.
- GitHub Actions federation through OpenID Connect, avoiding a stored Azure deployment secret.

Microsoft Foundry's MCP integration, MCP authentication guidance, and Container Apps authentication are documented by Microsoft in [MCP tools for Foundry agents](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol), [MCP authentication](https://learn.microsoft.com/azure/foundry/agents/how-to/mcp-authentication), and [Container Apps MCP authentication](https://learn.microsoft.com/azure/container-apps/mcp-authentication).

The editable diagram sources are [system-context.mmd](diagrams/system-context.mmd) and [azure-deployment.mmd](diagrams/azure-deployment.mmd). Re-render either one with:

```bash
npx --yes @mermaid-js/mermaid-cli@11.16.0 \
  -i diagram.mmd \
  -o diagram.png \
  --iconPacksNamesAndUrls "azure#https://raw.githubusercontent.com/NakayamaKento/AzureIcons/refs/heads/main/icons.json" \
  -b white
```

## Identity model

These identities are intentionally not interchangeable:

| Identity | Direction and permission |
| --- | --- |
| GitHub Actions deployment principal | Uses federated OIDC to deploy Azure resources and push the image within assigned Azure scopes; no stored Azure client secret. |
| Foundry project system-assigned identity | Outbound caller from Foundry to MCP for the `ProjectManagedIdentity` RemoteTool connection. Its client/principal pair is resolved through ARM and Graph, live-verified, allowlisted by Container Apps EasyAuth, and assigned only the MCP API's `Qam.Read` application role. |
| Published Agent Application `defaultInstanceIdentity` | Separate publication and inbound application boundary. Its client/principal pair is stability-checked across deployment changes but receives no downstream MCP role. |
| Human or automation invoker | Inbound caller of the published Responses endpoint. It receives `Foundry User` at exactly the Agent Application resource and does not receive `Qam.Read`. |
| Container App runtime UAMI | Acquires Fabric tokens, reads its required Key Vault secrets, and publishes telemetry. The industrial Preview path currently assigns Fabric workspace Contributor as an observed managed-identity query compatibility workaround despite documented Viewer support. It is neither the Agent Application caller nor the inbound invoker. |
| GitHub App installation | Reads `Contents` from one selected repository. Its PEM is held in Key Vault and is never committed or emitted as a deployment output. |

The RemoteTool connection is project-scoped, so agents in the same Foundry project share its outbound identity. The bootstrap makes that boundary explicit: it first publishes an inert, tool-less Agent Application, records and stability-checks both the application's distinct `properties.defaultInstanceIdentity` and the project's system identity, grants only the latter downstream access, and only then attaches the MCP-enabled version. See the [Foundry integration guide](../agents/foundry/README.md).

## Two-stage tenant bootstrap

A fresh tenant cannot safely create every dependency in one opaque operation. The supported order is:

1. Run local/static validation and, with tenant parameters, Azure what-if. These steps do not authorize a deployment.
2. After explicit approval, deploy the Azure foundation without the Container App. This creates the registry, Container Apps environment, Key Vault, monitoring, runtime identities, and a deterministic planned MCP URL.
3. An authorized administrator configures the GitHub App PEM secret and exact selected-repository permission, grants the runtime UAMI the explicitly reviewed Fabric role, and prepares the existing Lakehouse, notebook, and GraphModel. The industrial path selects Contributor as a Preview workaround and records the need to retest Viewer.
4. Publish the inert Foundry Agent Application, live-verify its distinct `defaultInstanceIdentity`, derive the project's system-assigned identity through ARM and Graph, assign only the project identity `Qam.Read`, and use its client/principal pair for both EasyAuth allowlists. Assign an inbound smoke-test identity `Foundry User` only at the published application scope.
5. Publish the verified projection to OneLake and run the notebook. Only after the complete table write succeeds, apply the canonical GraphModel definition, complete the bounded on-demand `RefreshGraph` job, and run the commit-pinned Fabric GQL smoke before application deployment.
6. Build the immutable image, deploy the allowlisted Container App, verify health and anonymous rejection, then attach the seven-tool MCP version to the published Agent Application. Run the GitHub, MCP, and published-agent smokes against the same commit.

Every live mutation—deployment, role assignment, secret write, Fabric publication, GraphModel refresh, or Foundry publication—is an explicit operator action. The local verification and demo commands do not perform these actions.

## Security and trust boundaries

The design follows Zero Trust in three concrete ways:

- **Verify explicitly:** Microsoft Entra ID protects the public HTTPS entry point; the server does not treat network reachability as authorization.
- **Use least privilege where the Preview permits it:** GitHub deployment uses federated OIDC, the runtime uses its own UAMI, the GitHub App is selected-repository `Contents: read`, MCP tools are read-only, and the Fabric adapter exposes fixed operations instead of arbitrary GQL. Runtime Fabric Contributor is an explicit, write-capable exception retained only because the recorded Viewer acceptance failed.
- **Assume breach:** every response can be traced to a path and commit, proposal tools are disabled by default, tool inputs and output sizes are bounded, and the derived graph can be discarded and rebuilt.

Secrets must never be committed or passed as Bicep outputs. Key Vault references are used only for integrations that cannot use workload identity. Production should additionally apply private endpoints, an approved egress path, Defender for Cloud, central SIEM integration, Azure Policy, and resource locks according to the organization's landing-zone controls. See Microsoft's [Zero Trust guidance](https://learn.microsoft.com/security/zero-trust/), [managed identities guidance](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview), and [Key Vault security guidance](https://learn.microsoft.com/azure/key-vault/general/security-features).

## Well-Architected assessment

| Pillar | PoC decision | Tradeoff / production step |
| --- | --- | --- |
| Reliability | Git history is authoritative and every graph snapshot is reproducible from a commit. Health and readiness endpoints support deployment checks. | The PoC is single-region. Production needs availability targets, at least two ready replicas where required, zone/region analysis, recovery drills, and tested Fabric-capacity recovery. |
| Security | Entra authentication, GitHub OIDC, managed identity, Key Vault references, fixed read-only MCP operations, SHA pinning, and no arbitrary graph query. | External Container Apps ingress is needed for Foundry connectivity. The runtime's Fabric Contributor Preview workaround gives a compromised runtime token workspace write authority; retest/downgrade to Viewer, and add private networking or an approved API perimeter, Defender, Policy, PIM, and SIEM controls. |
| Operational Excellence | Bicep, validation/deployment workflows, immutable image tags, structured health checks, and Azure Monitor/Log Analytics make changes repeatable and observable. | Wire the prepared Application Insights resource to an OpenTelemetry SDK, then add environment promotion, dashboards, SLOs, alert routing, runbooks, and rollback exercises before production. |
| Performance Efficiency | Stateless MCP instances scale horizontally; tools use pagination and bounded results; graph traversal is separated from Markdown retrieval. | Load and path tests use a small fixture. Benchmark realistic graph sizes, tune Fabric queries, cache only commit-addressed data, and set explicit concurrency limits. |

This assessment applies the relevant [Azure Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/) guidance to the PoC.

## Scope boundaries

- A live Azure/Fabric deployment requires tenant-specific identifiers, permissions, capacity, and explicit deployment approval; local tests do not create cloud resources.
- GitHub's enterprise controls are treated as an existing prerequisite, not re-provisioned here.
- The graph is never a replacement for repository review, history, branch protection, secret scanning, or code-owner policy.
- The supplied automation stages validated files, updates the existing GraphModel definition, and executes the bounded on-demand refresh gate. An authorized operator still owns the required Fabric permissions and the explicit live publication action.
- The optional MCP proposal transport is implemented but disabled by default. The GitHub branch/commit/pull-request service and repository-specific rulesets, CODEOWNERS, and reviewer policy remain a future, separately authorized authoring path.
- Application Insights is provisioned and ready for Entra-authenticated ingestion, but this PoC currently relies on Container Apps console/platform telemetry; application-level OpenTelemetry instrumentation is not yet wired.

Deployment parameters and operational commands are documented in [the infrastructure guide](../infra/README.md).
