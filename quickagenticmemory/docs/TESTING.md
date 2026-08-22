# Testing strategy

The proof is split into layers so a passing local demo has a precise meaning and is not confused with a live tenant deployment.

| Layer | What it proves | Default command |
| --- | --- | --- |
| Graph contract tests | The canonical `qam-graph/1.0` source and both generated package copies are byte-identical; field limits, provenance agreement, uniqueness, and edge references fail closed. | `node scripts/sync-graph-contract.mjs --check` and package tests |
| Core unit tests | OKF parsing, permissive conformance, link resolution, stable IDs, deterministic projection, contract validation, and flat Fabric exports. | `npm run test --workspace @quick-agentic-memory/core` |
| MCP unit tests | Canonical schemas, pagination, traversal, provenance, path confinement, bounded Fabric decoding, GitHub authentication, adapter errors, and disabled writes. | `npm run test --workspace @where-the-diagram-ends/quick-agentic-memory-mcp` |
| MCP integration tests | Real stdio and Streamable HTTP handshakes, the exact seven-tool surface, authentication, host/origin checks, Core-to-MCP contract compatibility, and health behavior. | Included in `npm run verify` |
| Local end to end | The sample wiki is validated, projected, served, traversed, and read back at the projected Git commit. | `npm run demo` |
| Foundry integration tests | Published Agent Application payloads, distinct identity and access-receipt checks, live Graph/EasyAuth fail-before-mutation gates, persisted exact tool allowlist, endpoint/resource binding, attach sequencing, and four-event smoke evidence. | `cd agents/foundry && uv run --frozen pytest` |
| Infrastructure static checks | Bicep compilation/linting, shell syntax, workflow structure, secret scanning, GitHub access controls, and OneLake failure/retry/idempotency behavior. | `npm run verify:infra` |
| Azure what-if | The tenant-specific deployment plan is accepted by Azure Resource Manager without creating resources. | Run the parameterized what-if helper explicitly. |
| Authorized cloud smoke | The deployed Container App, Entra identity chain, selected-repository GitHub read, verified OneLake publication, existing Fabric GraphModel query, and published Foundry application work against one commit. | Run only after an authorized deployment and tenant bootstrap. |

## Required security cases

The automated suite must cover these boundaries, not only happy-path retrieval:

- a path cannot escape the configured Markdown root;
- only Markdown files can be read from GitHub;
- an unpinned or malformed Git revision is rejected;
- an unauthenticated non-loopback HTTP listener is rejected;
- invalid Host, Origin, authentication, oversized body, and malformed input fail closed;
- clients cannot submit arbitrary Fabric GQL through an MCP argument;
- malformed or oversized `qam-graph/1.0` snapshots, mixed projection/commit values, duplicate identifiers, and dangling edges are rejected before export or retrieval;
- GitHub App credentials are mutually exclusive with token fallback, redirects/origin changes fail closed, and installation tokens are requested for exactly one selected repository with `Contents: read`;
- a partial, truncated, or hash-mismatched OneLake upload is never promoted; retry accepts an existing target only when both immutable files match exactly;
- an unpublished/shared Foundry identity cannot receive MCP access, the attach receipt is bound to
  the live enabled `Qam.Read` role/assignment and exact ACA audience/client/principal policy before
  each mutation, and inbound `Foundry User` remains separate from outbound `Qam.Read`;
- proposal/write functionality is absent or disabled by default;
- adapter failures return useful errors without exposing tokens or internal stack traces;
- result counts, page sizes, traversal depth, and document size are bounded.

## Local acceptance criteria

`npm run verify && npm run demo` is the local runtime gate. It must finish without modifying GitHub, Azure, Fabric, or Foundry and must demonstrate:

1. zero OKF validation errors and warnings for the fixture;
2. byte-stable graph, manifest, node-table, and edge-table output for identical inputs and metadata;
3. an MCP client can discover the read tools;
4. the client can resolve a concept, traverse at least one multi-hop path, inspect backlinks/provenance, and read the corresponding Markdown;
5. the returned path and source commit equal the projector manifest;
6. the write/proposal path is unavailable by default.

The full repository gate additionally runs `npm run verify:infra`, the locked Foundry test/lint suite, a clean-checkout assertion, and the MCP container build. Infrastructure negative tests mock Azure/OneLake/GitHub boundaries; they do not assign roles, write secrets, publish Fabric data, publish an Agent Application, or call a model.

Run the Foundry local gate with:

```bash
cd agents/foundry
uv sync --locked --all-groups
uv run --frozen pytest
uv run --frozen ruff check .
uv run --frozen ruff format --check .
bash -n configure-access.sh configure-invoker.sh
shellcheck -x configure-access.sh configure-invoker.sh
```

## Cloud acceptance criteria

A full tenant smoke is intentionally a separate gate because deployment, role assignment, secret configuration, Fabric publication, Foundry publication, and model calls can change tenant state or incur cost. After explicit authorization and the documented two-stage bootstrap, it must verify:

1. GitHub Actions obtains Azure access through OIDC without a stored client secret;
2. the image is addressed by an immutable digest and starts in Container Apps;
3. anonymous MCP requests receive `401`, while only the live-verified published Agent Application `defaultInstanceIdentity` pair passes EasyAuth and `Qam.Read`;
4. an independently authorized invoker with `Foundry User` at the individual Agent Application scope can call its published Responses endpoint without gaining outbound MCP access;
5. the Container App runtime UAMI obtains Fabric access and only its required Key Vault secret/telemetry permissions; it is not accepted as the Foundry caller;
6. the GitHub App produces a short-lived installation token restricted to the selected repository and `Contents: read`, then reads the expected Markdown path at the full immutable commit;
7. OneLake reads both uploads back with matching byte counts and SHA-256 values, atomically publishes the pair, and the Fabric notebook completes both validated Delta table writes before an operator maps/saves/refreshes the existing GraphModel;
8. fixed node and edge GQL smokes return the expected projection and commit, and arbitrary GQL remains unavailable through MCP;
9. the published Foundry application exposes exactly seven tools and completes the required `resolve_concepts` → `get_neighbors` → `trace_provenance` → `read_concepts` evidence sequence against that same commit.

The exact two-stage deployment and smoke commands are maintained in the [infrastructure guide](../infra/README.md) and [Foundry guide](../agents/foundry/README.md). A local pass is evidence for deterministic software behavior; only the separately authorized cloud gate is evidence for tenant RBAC, service connectivity, Fabric mappings, and model-mediated tool use.

Application-level correlation IDs and redacted per-operation success audit events are a production gate, not a capability claimed by this PoC. The current deployment exposes Container Apps platform, console, HTTP, and health telemetry, while tool errors are redacted; it does not yet provide an executable Application Insights/OpenTelemetry audit-log acceptance test.
