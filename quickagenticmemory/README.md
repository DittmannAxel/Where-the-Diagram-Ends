# Quick Agentic Memory

> **Experimental proof of concept:** implemented with separate local and fully parameterized Azure/Fabric/Foundry acceptance paths. Cloud deployment remains an explicit, authorized operator action.

This is my small workbench for turning architectural ideas into executable proofs—where the diagram ends and the test begins. The idea is simple: seeing is believing, but a result is only useful when it can be traced back to the exact knowledge that produced it.

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
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Architecture, Azure diagrams, security boundaries, WAF assessment, and cost drivers. |
| [`docs/TESTING.md`](docs/TESTING.md) | Local, infrastructure, identity, and authorized cloud acceptance gates. |

## Local proof

Prerequisites are Node.js 22 or newer and npm.

```bash
cd quickagenticmemory
npm ci
npm run verify
npm run demo
```

`verify` checks contract synchronization, type-checks, tests, and builds both packages. `demo` validates the fixture, generates a graph and manifest under `.artifacts/local-demo/`, starts the MCP test path, and proves graph navigation plus commit-pinned Markdown retrieval.

No cloud resources are required for this path and no tracked repository or tenant state is modified. The demo refreshes only its ignored `.artifacts/local-demo/` directory; sibling cloud receipts under `.artifacts/` are preserved.

## Cloud proof

The live path is intentionally staged: deploy the foundation and isolated identities first; explicitly deploy the paid Fabric/Foundry platform; publish one approved commit to Fabric; configure GitHub source access and the Foundry project's system-assigned managed identity; then deploy the allowlisted Container App and attach the MCP-enabled Agent Application version. The application image is built inside ACR from that exact public Git URL and full commit SHA, so the reproducible cloud path needs no local Docker daemon; its checked-in helper waits for a terminal run, locks the output digest, and emits a source-bound JSON receipt. The Agent Application keeps a distinct identity for publication and invocation, while the secretless `ProjectManagedIdentity` RemoteTool connection uses the project identity for outbound MCP calls. OneLake publication uses a unique temporary directory, read-back byte and SHA-256 verification, and an atomic no-replace rename. The repository also creates the Fabric Workspace, Lakehouse, Graph Model, and Notebook through public APIs, generates the canonical Graph definition from the checked-in contract, and completes the official on-demand `RefreshGraph` job before accepting GQL evidence.

Nothing in `npm run verify` or `npm run demo` creates cloud resources. Azure deployment, role assignment, secret configuration, Fabric publication, and live smoke tests are separate operator actions and require explicit authorization. `scripts/deploy-industrial-platform.sh` provides an idempotent tenant-neutral deployment-and-smoke path without making what-if mandatory; `scripts/publish-industrial-fabric.sh` applies the clean commit-pinned data plane. See the [industrial scenario](tests/industrial-component-obsolescence/README.md), [infrastructure guide](infra/README.md), and [Foundry guide](agents/foundry/README.md).

## Security stance

The default MCP surface contains exactly `browse_index`, `resolve_concepts`, `get_neighbors`, `get_backlinks`, `find_path`, `read_concepts`, and `trace_provenance`. It does not accept arbitrary GQL, content paths are confined to the configured knowledge root, proposal/write behavior is disabled by default, and projected data carries its Git commit.

GitHub Actions uses OIDC for Azure deployment. The Foundry project's system-assigned managed identity is the outbound MCP caller and receives only `Qam.Read`; EasyAuth requires its exact token audience, client ID, and principal ID and deliberately contains no group-authorization rule. The published Agent Application retains a separate `defaultInstanceIdentity`, while an inbound operator or automation identity receives `Foundry User` only at that application scope. The Container App uses its own user-assigned managed identity for Fabric, Key Vault, and telemetry, while a selected-repository GitHub App receives only `Contents: read` and keeps its PEM private key in Key Vault. Fabric documents Viewer for Graph queries, but the industrial cloud path explicitly uses workspace Contributor as an observed managed-identity Preview compatibility workaround; that write-capable role is a recorded PoC risk and must be retested for downgrade to Viewer.

This remains a PoC, not a production claim. A live test still needs tenant-specific GitHub, Fabric, Foundry, and Azure configuration and explicit authorization to create chargeable resources.

[Back to Where the Diagram Ends](../README.md)
