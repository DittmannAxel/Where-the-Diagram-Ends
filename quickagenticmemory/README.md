# Quick Agentic Memory

> **Experimental proof of concept:** implemented for local end-to-end testing; Azure and Fabric deployment remains an explicit, parameterized step.

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

`verify` checks contract synchronization, type-checks, tests, and builds both packages. `demo` validates the fixture, generates a graph and manifest under `.artifacts/`, starts the MCP test path, and proves graph navigation plus commit-pinned Markdown retrieval.

No cloud resources are required for this path and no tracked repository or tenant state is modified. The demo refreshes only the ignored local `.artifacts/` directory.

## Cloud proof

The live path is intentionally a two-stage tenant bootstrap: deploy the foundation first; configure the existing Fabric items, GitHub App secret and permissions, and the published Foundry application's distinct identity; then deploy the allowlisted Container App and attach the MCP-enabled agent version. OneLake publication uses a unique temporary directory, read-back byte and SHA-256 verification, and an atomic no-replace rename before the existing GraphModel is manually mapped, saved, and refreshed.

Nothing in `npm run verify` or `npm run demo` creates cloud resources. Azure what-if, deployment, role assignment, secret configuration, Fabric publication, and live smoke tests are separate operator actions and require explicit authorization. See the [infrastructure guide](infra/README.md) and [Foundry guide](agents/foundry/README.md).

## Security stance

The default MCP surface contains exactly `browse_index`, `resolve_concepts`, `get_neighbors`, `get_backlinks`, `find_path`, `read_concepts`, and `trace_provenance`. It does not accept arbitrary GQL, content paths are confined to the configured knowledge root, proposal/write behavior is disabled by default, and projected data carries its Git commit.

GitHub Actions uses OIDC for Azure deployment. The published Foundry Agent Application's distinct `defaultInstanceIdentity` is the outbound MCP caller and receives `Qam.Read`; an inbound operator or automation identity separately receives `Foundry User` only at that Agent Application scope. The Container App uses its own user-assigned managed identity for Fabric, Key Vault, and telemetry, while a selected-repository GitHub App receives only `Contents: read` and keeps its PEM private key in Key Vault.

This remains a PoC, not a production claim. A live test still needs tenant-specific GitHub, Fabric, Foundry, and Azure configuration and explicit authorization to create chargeable resources.

[Back to Where the Diagram Ends](../README.md)
