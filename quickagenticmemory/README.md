# Quick Agentic Memory

> **Experimental proof of concept:** implemented with separate local and fully parameterized Azure/Fabric/Foundry acceptance paths. The synthetic industrial showcase has passed the complete cloud path; deployment in another tenant remains an explicit, authorized operator action.

This is my small workbench for turning architectural ideas into executable proofs—where the diagram ends and the test begins. The idea is simple: seeing is believing, but a result is only useful when it can be traced back to the exact knowledge that produced it.

## Why this proof exists

In manufacturing, a seemingly simple question such as “What changes when this field component reaches end of life?” is usually a relationship problem. The answer can span delivered machine variants, electrical mappings, PLC diagnostic blocks, parameter sets, service/change records, and controlled FAT/SAT specifications. Missing one link can make an otherwise fluent answer incomplete.

A conventional RAG pipeline is strong at finding semantically similar text, but its chunk-retrieval stage does not automatically guarantee stable component identity, complete multi-hop impact coverage, lifecycle filtering, exclusion of near-name distractors, or source consistency across a changing repository. Quick Agentic Memory adds those controls as a graph-and-provenance layer; it does not claim that graphs universally replace RAG.

The synthetic public scenario makes the difference visible with `IOL-M8`: two delivered variants have distinct controlled impact chains, while `IOL-M8S` and superseded guidance are deliberate distractors. The experiment compares the lexical BM25 retrieval stage with bounded link traversal over the same Markdown and records what each method retrieved. It evaluates retrieval evidence, not LLM answer style.

## Public evidence

[![Redacted end-to-end cloud acceptance](tests/industrial-component-obsolescence/screens/04-cloud-chain-acceptance.jpg)](tests/industrial-component-obsolescence/screens/04-cloud-chain-acceptance.jpg)

The redacted cloud proof shows the tested chain from one public Git commit through Fabric Graph, the Entra-protected MCP gateway, and the Foundry Agent Application. It records 28 source documents, 107 graph nodes, 167 edges, live boundary checks, and the four ordered agent tool events. The [evidence gallery](tests/industrial-component-obsolescence/screens/) also contains the local retrieval comparison, public GitHub source view, Foundry smoke trace, checksums, and a machine-readable redacted cloud receipt.

One design influence is [Andrej Karpathy's sketch of a persistent, compounding wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f). This repository independently tests that general idea with Git-reviewed Markdown, deterministic projections, and bounded agent retrieval; it does not copy implementation code from the gist.

Quick Agentic Memory turns OKF v0.2 Markdown in GitHub into a navigable graph and exposes it to agents through a constrained MCP interface:

- GitHub is the reviewed, versioned source of truth.
- The OKF Validator checks the portable Markdown bundle.
- The Fabric Graph Projector creates a deterministic, commit-pinned snapshot that must satisfy the canonical `qam-graph/1.0` executable contract.
- Microsoft Fabric Graph is a rebuildable navigation index.
- The Wiki MCP Gateway gives a published Microsoft Foundry Agent Application exactly seven bounded read-only tools for graph navigation and selected source retrieval.

The implementation deliberately calls the projection component **Fabric Graph Projector**, not “OKF Graph Compiler”: OKF remains ordinary Markdown and the graph is only one disposable representation of it.

## Repository map

| Path | Purpose |
| --- | --- |
| [`knowledge/`](knowledge/) | Small OKF v0.2 bundle used by the complete local test. |
| [`contracts/`](contracts/) | Canonical executable `qam-graph/1.0` contract shared by projection, Fabric decoding, and MCP retrieval. |
| [`packages/core/`](packages/core/) | Validator, deterministic projector, manifest, and CLI. |
| [`packages/mcp/`](packages/mcp/) | Read-only MCP gateway with local and cloud adapter boundaries. |
| [`agents/foundry/`](agents/foundry/) | Published Foundry Agent Application registration, identity bootstrap, and smoke test. |
| [`infra/`](infra/) | Azure Bicep, Fabric integration guidance, and deployment parameters. |
| [`scripts/`](scripts/) | Validation, what-if, deployment, and smoke-test helpers. |
| [`tests/industrial-component-obsolescence/`](tests/industrial-component-obsolescence/) | Synthetic industrial A/B proof comparing classical BM25 chunk retrieval with bounded graph and provenance retrieval. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Architecture, Azure diagrams, security boundaries, and WAF assessment. |
| [`docs/TESTING.md`](docs/TESTING.md) | Local, infrastructure, identity, and authorized cloud acceptance gates. |
| [`docs/CLOUD_REPRODUCTION.md`](docs/CLOUD_REPRODUCTION.md) | Canonical public-SHA installation and full Azure/Fabric/Foundry acceptance runbook. |

## How to install and run locally

Prerequisites are Git, Node.js 22 or newer, and npm. From the directory in which you want the repository:

```bash
git clone https://github.com/DittmannAxel/Where-the-Diagram-Ends.git
cd Where-the-Diagram-Ends/quickagenticmemory
npm ci
npm run verify
npm run demo
```

`verify` checks contract synchronization, type-checks, tests, and builds both packages. `demo` validates the fixture, generates a graph and manifest under `.artifacts/local-demo/`, starts the MCP test path, and proves graph navigation plus commit-pinned Markdown retrieval.

No cloud resources are required for this path and no tracked repository or tenant state is modified. The demo refreshes only its ignored `.artifacts/local-demo/` directory; sibling cloud receipts under `.artifacts/` are preserved.

## How to deploy and test the complete Azure proof

The canonical cloud entry point is the fail-closed [`cloud-run.sh`](tests/industrial-component-obsolescence/code/cloud-run.sh) driver. It deploys the Azure foundation, Fabric and Foundry platform, graph data plane, ACR-built MCP image, Entra identities and access, Container App, Agent Application, and the final end-to-end smoke test. It then emits `cloud-acceptance.json` only if every stage passed.

> **Permissions and lifecycle:** the example configuration selects a Fabric F64 capacity and a Foundry model deployment. Run it only in an isolated resource group with an authorized Azure/Fabric/Entra operator, and pause the Fabric capacity after the test. Regional service availability and model quota are tenant-specific.

### 1. Install the operator tools

You need Azure CLI with Bicep and the Container Apps extension, Bash, Git, `curl`, `jq`, `uuidgen`, `base64`, `openssl`, Node.js 22 with npm, Python 3.11 or newer, and `uv`. Docker is not required because Azure Container Registry builds the image from the public Git commit.

```bash
az bicep install
az extension add --name containerapp --upgrade
az login
az account set --subscription '<subscription-name-or-id>'

for QAM_NAMESPACE in \
  Microsoft.App \
  Microsoft.ContainerRegistry \
  Microsoft.CognitiveServices \
  Microsoft.Fabric \
  Microsoft.Insights \
  Microsoft.KeyVault \
  Microsoft.ManagedIdentity \
  Microsoft.Network \
  Microsoft.OperationalInsights
do
  az provider register --namespace "${QAM_NAMESPACE}" --wait
done
```

The signed-in user must be the configured Fabric capacity administrator, Foundry operator, and final smoke-test invoker. Provider registration and creation of a new resource group require subscription-level permissions. Before continuing, complete the detailed [cloud prerequisites](docs/CLOUD_REPRODUCTION.md#prerequisites), including the Fabric tenant setting for service principals.

### 2. Select one validated public commit

Choose a full commit SHA whose public GitHub Actions **QAM validate / validate** check succeeded, then use a clean detached checkout:

```bash
git clone https://github.com/DittmannAxel/Where-the-Diagram-Ends.git qam-public-proof
cd qam-public-proof
git checkout --detach '<40-lowercase-public-git-sha>'
git rev-parse HEAD
git status --short
```

The command uses the public upstream source. If your fork is the configured source, replace the clone URL with that fork's canonical `.git` URL. In either case, use the same repository in `cloud-config.json`. The final command must print nothing. The driver rejects a private or dirty source, a branch name, an abbreviated SHA, and a commit without the successful check for that repository.

The source may be this upstream repository or your public fork. If the fork is the configured source, clone that fork, enable Actions there, and require `validate` on its exact commit. The separate OIDC credential must always target a repository and GitHub Environment that you administer; it can target your controlled fork even when the interactive driver reads the public upstream source. Never bind an Azure federated credential to a repository or Environment controlled by someone else.

### 3. Bootstrap the isolated deployment identity

If the tenant does not already have a separately governed GitHub OIDC deployment principal, the bootstrap can create the isolated resource group, user-assigned identity, and an Azure federated credential scoped to the operator-controlled GitHub Environment. Creating a new resource group and registering providers requires the subscription permissions listed in the runbook:

```bash
quickagenticmemory/scripts/bootstrap-github-oidc.sh \
  --subscription-id '<azure-subscription-id>' \
  --resource-group '<new-or-existing-isolated-resource-group>' \
  --location '<supported-azure-region>' \
  --github-owner '<your-fork-owner>' \
  --github-repository '<your-fork-repository>' \
  --github-environment qam-test
```

Keep the printed `AZURE_PRINCIPAL_ID`; it becomes `principals.deploymentPrincipalId` in the cloud configuration. The interactive driver still runs as the signed-in user. The OIDC identity is the separately governed role target, is used as the deployment caller only by the protected GitHub workflow, and must remain distinct from the runtime managed identity.

The bootstrap does not create or protect the GitHub Environment. A repository administrator must create `qam-test`, configure reviewers and branch restrictions, and add the printed non-secret variables before using the workflow. The interactive driver needs only the separate role target.

### 4. Create the ignored configuration

```bash
mkdir -p quickagenticmemory/.artifacts
cp \
  quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-config.example.json \
  quickagenticmemory/.artifacts/cloud-config.json

az ad signed-in-user show \
  --query '{fabricAdminMember:userPrincipalName,objectId:id}' \
  --output json
```

Edit only the ignored `cloud-config.json`. Set the public repository, canonical `.git` URL, exact SHA, subscription, resource group, region, printed OIDC principal ID, signed-in user's UPN/object ID, and an available tool-capable Foundry model/version. For a first run, set `principals.temporaryAcrWriter` to the signed-in user; use `null` only if that user already has `Container Registry Repository Writer` on the registry. Remove every `<placeholder>`.

Keep the scenario contract unchanged: `image.repository` is `qam-mcp`; `foundry.connectionName` is `qam-mcp-project-identity`; cleanup remains `true`; and acceptance remains 28 documents, 107 nodes, 167 edges, `IOL-M8`, and `XK8-IO`.

### 5. Run acceptance and pause the Fabric capacity

```bash
quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-run.sh \
  --config quickagenticmemory/.artifacts/cloud-config.json
```

The driver prints the private receipt path only after terminal acceptance. Its `cleanup` stage removes superseded access; it does **not** pause or delete deployed resources. If the run reached the `platform` stage, follow the [capacity lifecycle step](docs/CLOUD_REPRODUCTION.md#pause-the-fabric-capacity) after acceptance or after any later failure/interruption.

For the complete permission checklist, resource-provider registration, resumable stages, receipt checks, and capacity pause/resume command, use the canonical [public-SHA cloud runbook](docs/CLOUD_REPRODUCTION.md).

## How the cloud proof works

The live path is intentionally staged: deploy the foundation and isolated identities first; explicitly deploy the Fabric/Foundry platform; publish one approved commit to Fabric; configure GitHub source access and the Foundry project's system-assigned managed identity; then deploy the allowlisted Container App and attach the MCP-enabled Agent Application version. The application image is built inside ACR from that exact public Git URL and full commit SHA, so the reproducible cloud path needs no local Docker daemon; its checked-in helper waits for a terminal run, locks the output digest, and emits a source-bound JSON receipt. The Agent Application keeps a distinct identity for publication and invocation, while the secretless `ProjectManagedIdentity` RemoteTool connection uses the project identity for outbound MCP calls. OneLake publication uses a unique temporary directory, read-back byte and SHA-256 verification, and an atomic no-replace rename. The repository also creates the Fabric Workspace, Lakehouse, Graph Model, and Notebook through public APIs, generates the canonical Graph definition from the checked-in contract, and completes the official on-demand `RefreshGraph` job before accepting GQL evidence.

Nothing in `npm run verify` or `npm run demo` creates cloud resources. Azure deployment, role assignment, secret configuration, Fabric publication, and live smoke tests are separate operator actions and require explicit authorization. `scripts/deploy-industrial-platform.sh` provides an idempotent tenant-neutral deployment-and-smoke path without making what-if mandatory; `scripts/publish-industrial-fabric.sh` applies the clean commit-pinned data plane. The public [cloud evidence](tests/industrial-component-obsolescence/screens/) records the successful redacted acceptance outcome. See also the [industrial scenario](tests/industrial-component-obsolescence/README.md), [infrastructure guide](infra/README.md), and [Foundry guide](agents/foundry/README.md).

## Security stance

The default MCP surface contains exactly `browse_index`, `resolve_concepts`, `get_neighbors`, `get_backlinks`, `find_path`, `read_concepts`, and `trace_provenance`. It does not accept arbitrary GQL, content paths are confined to the configured knowledge root, proposal/write behavior is disabled by default, and projected data carries its Git commit.

GitHub Actions uses OIDC for Azure deployment. The Foundry project's system-assigned managed identity is the outbound MCP caller and receives only `Qam.Read`; EasyAuth requires its exact token audience, client ID, and principal ID and deliberately contains no group-authorization rule. The published Agent Application retains a separate `defaultInstanceIdentity`, while an inbound operator or automation identity receives `Foundry User` only at that application scope. The Container App uses its own user-assigned managed identity for Fabric, Key Vault, and telemetry. This public showcase reads the exact public Git commit without a credential; a private deployment can instead use a selected-repository GitHub App with only `Contents: read` and a PEM private key kept in Key Vault. Fabric documents Viewer for Graph queries, but the industrial cloud path explicitly uses workspace Contributor as an observed managed-identity Preview compatibility workaround; that write-capable role is a recorded PoC risk and must be retested for downgrade to Viewer.

This remains a PoC, not a production claim. A live test still needs tenant-specific GitHub, Fabric, Foundry, and Azure configuration plus explicit deployment authorization.

[Back to Where the Diagram Ends](../README.md)
