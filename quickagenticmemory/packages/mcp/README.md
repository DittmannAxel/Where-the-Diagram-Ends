# Quick Agentic Memory MCP Gateway

This package exposes a small, auditable MCP surface over the Quick Agentic Memory graph and its
original Markdown. GitHub remains the source of truth; Fabric Graph is a replaceable projection
used to find relevant concepts and relationships. Every content read is pinned to the projection's
full commit SHA and verified against the concept's SHA-256 content hash.

The server supports stateless Streamable HTTP for Azure-hosted clients and stdio for local MCP
hosts. It targets Node.js 22 or newer and the split v2 Model Context Protocol TypeScript SDK.

## Trust boundary

```text
MCP client
  -> validated, bounded MCP tool
  -> GraphReadAdapter
       -> canonical local JSON
       -> direct Fabric Graph GQL with two server-owned queries
       -> curated HTTPS snapshot compatibility endpoint
  -> ContentReadAdapter
       -> local Markdown below a realpath-constrained root
       -> GitHub Contents API at a full commit SHA
```

No tool accepts GQL, SQL, a URL, an absolute path, or a branch name. The gateway accepts only
known concept IDs, constrained filters, safe bundle- or repository-relative Markdown paths, and lowercase
full 40- or 64-character Git object IDs. Paths, response sizes, pagination, hops, remote download
sizes, redirects, timeouts, hosts, and origins are bounded or denied.

## Tools

| Tool | Purpose | Hard bounds |
|---|---|---|
| `browse_index` | Browse concepts by directory, type, and tags | 100 results per page |
| `resolve_concepts` | Rank titles, aliases, tags, types, paths, and summaries | 20 terms, 100 results |
| `get_neighbors` | Traverse identified concepts | 2 hops, 100 concept nodes |
| `get_backlinks` | List incoming concept references | 100 results per page |
| `find_path` | Find a shortest concept-to-concept path | 6 hops |
| `read_concepts` | Read original SHA-pinned, hash-verified Markdown | 10 documents, 50k characters each, 100k aggregate |
| `trace_provenance` | Return a concept, projection provenance, `DERIVED_FROM` edges, and source nodes | One concept |

All seven tools carry read-only, non-destructive, idempotent annotations. Structured JSON is
returned in `structuredContent`; callers may request compact Markdown or JSON text.

`propose_wiki_update` is absent by default. It is registered only when
`QAM_ENABLE_PROPOSALS=true` and both a proposal endpoint and token are configured. The proposal
service—not this gateway—owns branch creation, commits, pull requests, approvals, and policy.

## Canonical graph contract

The local adapter consumes the Core projector's [`qam-graph/1.0` contract](../../contracts/README.md). The graph contains a
validated union of `Concept`, `Tag`, `Source`, and `Term` nodes. All edge endpoints are checked
against every node kind, but discovery and ordinary traversal expose only concepts. Provenance may
return source nodes.

```json
{
  "schemaVersion": "qam-graph/1.0",
  "okfVersion": "0.2",
  "source": {
    "repository": "https://github.com/owner/repository",
    "projectionId": "urn:qam:projection:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "commitSha": "1111111111111111111111111111111111111111",
    "generatedAt": "2026-08-22T12:00:00Z"
  },
  "nodes": [
    {
      "id": "urn:qam:concept:example",
      "kind": "Concept",
      "title": "Example",
      "type": "Architecture",
      "path": "knowledge/concepts/example.md",
      "repositoryPath": "quickagenticmemory/knowledge/concepts/example.md",
      "conceptId": "example",
      "tags": ["example"],
      "aliases": [],
      "projectionId": "urn:qam:projection:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "commitSha": "1111111111111111111111111111111111111111",
      "status": "stable",
      "contentHash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    {
      "id": "urn:qam:tag:example",
      "kind": "Tag",
      "title": "example",
      "type": "Tag",
      "tags": [],
      "aliases": ["example"],
      "projectionId": "urn:qam:projection:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "commitSha": "1111111111111111111111111111111111111111",
      "normalizedValue": "example"
    }
  ],
  "edges": [
    {
      "id": "urn:qam:edge:example-tag",
      "from": "urn:qam:concept:example",
      "to": "urn:qam:tag:example",
      "type": "HAS_TAG",
      "projectionId": "urn:qam:projection:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "commitSha": "1111111111111111111111111111111111111111",
      "sourcePath": "knowledge/concepts/example.md"
    }
  ]
}
```

Validation rejects duplicate node, edge, or concept-path IDs; dangling endpoints; edge types whose
source/target node kinds do not match the canonical matrix; unsafe paths; unknown node or edge
kinds; malformed hashes; and any node or edge whose projection identity or commit differs from the snapshot. `Concept.path` is bundle-relative and is used only by the local
Markdown adapter; `Concept.repositoryPath` is repository-relative and is used exclusively by the
GitHub adapter.

## Fabric Graph adapter

`fabric-gql` calls the Fabric Graph preview API directly:

```text
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/GraphModels/{graphModelId}/executeQuery?preview=true
Body: { "query": "<server-owned query>" }
```

The adapter executes exactly two server-owned query templates: one bounded `QamNode` projection and
one bounded `QamEdge` projection. Only validated integer limits are configurable; it never accepts a
query string from an MCP client. Edge endpoints
come from `source.id` and `target.id`, not duplicated relationship properties. A row count equal to
the configured query limit fails closed because the projection may be truncated. Defaults are
10,000 nodes and 50,000 edges; hard parser ceilings are 100,000 and 500,000 respectively.

The flat `QamNode` table must provide the Core export fields:

```text
id, kind, title, type, path, repositoryPath, conceptId, tagsJson, aliasesJson,
projectionId, commitSha, repository, projectionGeneratedAt, okfVersion,
summary, resource, status, contentHash, sourceUrl, normalizedValue,
sourceIdsJson, authorsJson, usageCountsJson, lastModified
```

`QamEdge` provides `id`, endpoint-derived `from` and `to`, `type`, `projectionId`, `commitSha`,
`label`, and `sourcePath`.
The `*Json` values are safely decoded as bounded JSON arrays. Repository, projection timestamp,
OKF version, projection ID, and commit SHA must be present and identical on every node row. Every
edge row must carry that exact same immutable projection ID and commit. Mixed or missing provenance
fails after retrieval before a `MemoryGraphAdapter` can be created. This post-fetch check is
deliberate because the preview GQL surface does not yet provide a verified parameterized filtering
contract. `QAM_SOURCE_REPOSITORY`, `QAM_EXPECTED_PROJECTION_ID`, and `QAM_EXPECTED_COMMIT_SHA`, when
set, are additional expected-value checks.

The direct adapter caches only a fully validated in-memory snapshot. The cache expires after 60
seconds by default (configurable from 1 to 300 seconds); concurrent callers share one refresh. An
expired refresh must validate completely before it atomically replaces the delegate. If token,
HTTP, provenance, or contract validation fails, all callers waiting on that refresh fail closed and
the next call retries instead of serving stale data indefinitely. Composite tool responses acquire
one immutable snapshot view, so cache expiry cannot combine source metadata from one projection
with query results from another.

Production authentication uses `DefaultAzureCredential`, including a user-assigned managed
identity when `QAM_AZURE_CLIENT_ID` or `AZURE_CLIENT_ID` is set. To prevent managed-identity token
exfiltration, production requests are pinned to `https://api.fabric.microsoft.com` and the scope
`https://api.fabric.microsoft.com/.default`. Custom hosts and a literal access token are accepted
only when explicit insecure-localhost test mode is enabled. The API is a Fabric preview surface;
deployments should run the provided contract smoke test after platform changes.

Fabric documents Viewer for Graph query. The industrial deployment currently selects workspace
Contributor as an observed managed-identity Preview compatibility workaround after its Viewer
acceptance returned GQL `42000`. The MCP surface remains read-only, but the identity role is not;
operators must treat a compromised runtime token as workspace-write capable and periodically rerun
the same test under Viewer so the workaround can be removed.

`fabric-http` remains a separate compatibility adapter. It reads the canonical snapshot from a
curated HTTPS endpoint owned by the deployment; it is not a direct Fabric GQL adapter and does not
claim that Fabric returns the snapshot JSON natively.

## Adapter configuration

| Variable | Meaning |
|---|---|
| `QAM_GRAPH_ADAPTER` | `local` (default), `fabric-gql`, or `fabric-http` |
| `QAM_GRAPH_JSON_PATH` | Canonical local graph snapshot path |
| `QAM_FABRIC_WORKSPACE_ID` | Fabric workspace UUID for `fabric-gql` |
| `QAM_FABRIC_GRAPH_MODEL_ID` | Fabric Graph Model UUID for `fabric-gql` |
| `QAM_FABRIC_API_URL` | Defaults to `https://api.fabric.microsoft.com`; production is pinned to that origin |
| `QAM_FABRIC_TOKEN_SCOPE` | Defaults to and is production-pinned to `https://api.fabric.microsoft.com/.default` |
| `QAM_AZURE_CLIENT_ID` | Optional user-assigned managed-identity client ID; falls back to `AZURE_CLIENT_ID` |
| `QAM_SOURCE_REPOSITORY` | Optional exact repository expectation for projection provenance |
| `QAM_EXPECTED_PROJECTION_ID` | Optional exact immutable Fabric projection expectation |
| `QAM_EXPECTED_COMMIT_SHA` | Optional exact graph/local-content commit expectation |
| `QAM_FABRIC_MAX_NODES` | Node query limit, default 10000, hard maximum 100000; equality fails closed |
| `QAM_FABRIC_MAX_EDGES` | Edge query limit, default 50000, hard maximum 500000; equality fails closed |
| `QAM_FABRIC_SNAPSHOT_TTL_MS` | Validated snapshot cache TTL, default 60000, minimum 1000, maximum 300000; expired refreshes are single-flight and fail closed |
| `QAM_FABRIC_ACCESS_TOKEN` | Localhost integration tests only; rejected in production mode |
| `QAM_FABRIC_GRAPH_SNAPSHOT_URL` | Curated HTTPS snapshot endpoint for `fabric-http` |
| `QAM_FABRIC_GRAPH_TOKEN` | Optional bearer token for the curated endpoint |
| `QAM_CONTENT_ADAPTER` | `local` (default) or `github` |
| `QAM_MARKDOWN_ROOT` | Local Markdown root; real paths must remain below it |
| `QAM_GITHUB_REPOSITORY` | `owner/repository` |
| `QAM_GITHUB_API_URL` | `https://api.github.com` or a GHES base on the same origin as the web URL with path `/api/v3` |
| `QAM_GITHUB_WEB_URL` | `https://github.com` or the root of the same pinned GHES origin |
| `QAM_GITHUB_AUTH_MODE` | `app` (recommended for private repositories), `token` (explicit fallback), or `none` |
| `QAM_GITHUB_APP_ID` | Positive decimal GitHub App ID for `app` mode |
| `QAM_GITHUB_INSTALLATION_ID` | Positive decimal installation ID for `app` mode |
| `QAM_GITHUB_PRIVATE_KEY` | PEM RSA private key supplied only through a Key Vault-backed secret reference |
| `QAM_GITHUB_TOKEN` | Fine-grained read-only PAT/bearer secret used only when mode is explicitly `token` |
| `QAM_ADAPTER_TIMEOUT_MS` | Remote adapter timeout, default 15000 |
| `QAM_ALLOW_INSECURE_LOCALHOST_ADAPTERS` | Test-only HTTP/localhost escape hatch |

The recommended private-repository mode creates a short-lived RS256 GitHub App JWT, exchanges it at
the pinned `/app/installations/{id}/access_tokens` endpoint, and requests an installation token
restricted to exactly the configured repository with `contents: read`. Tokens are cached, renewed
before expiry, and invalidated once on HTTP 401; a request is retried at most once. App credentials
and PAT fallback fields are mutually exclusive.

Content access performs only
`GET /repos/{owner}/{repo}/contents/{repositoryPath}?ref={fullSha}` with the raw-content media type.
Repository, full commit, and `repositoryPath` all originate from validated server configuration or
the immutable graph. Redirects are denied, `Content-Length` is checked, and the response stream
itself is stopped above 2 MiB. Official GitHub API/web hosts must be paired; GHES API and web URLs
must share one HTTPS origin and use `/api/v3` plus the web root. Existing branch protection, secret
scanning, audit logs, SSO, and approval policy remain outside this process.

Secrets are read only from the process environment. Do not put them in files, images, source,
deployment output, or graph snapshots.

## HTTP security

The default server binds to `127.0.0.1`, validates `Host` and `Origin`, and permits unauthenticated
access only on loopback. A non-loopback deployment must configure authentication and an explicit
allowed-host list.

| Variable | Meaning |
|---|---|
| `QAM_TRANSPORT` | `stdio` (default) or `http` |
| `QAM_HTTP_HOST` | Bind address, default `127.0.0.1` |
| `QAM_HTTP_PORT` | Port; `PORT` is used as a fallback |
| `QAM_HTTP_ALLOWED_HOSTS` | Comma-separated hostnames, without ports |
| `QAM_HTTP_ALLOWED_ORIGINS` | Comma-separated origin hostnames |
| `QAM_HTTP_AUTH_MODE` | `none`, `bearer`, or `trusted-header` |
| `QAM_MCP_BEARER_TOKEN` | Bearer secret of at least 24 characters |
| `QAM_TRUSTED_IDENTITY_HEADER` | Identity header, default `x-ms-client-principal-id` |

Use `trusted-header` only behind ingress that authenticates the caller and strips any
client-supplied copy of the trusted header. Host/Origin checks prevent DNS rebinding and unwanted
browser origins; they do not replace authentication. MCP request bodies are capped at 1 MiB and
HTTP server timeouts are enabled. `GET /healthz` is a minimal unauthenticated liveness endpoint.
Exceptions are logged only as redacted error class/code summaries; messages, stacks, request bodies,
tokens, and private-key material are never written by the gateway logger.

## Local test run

Install, type-check, build, and run all unit plus transport integration tests:

```bash
npm ci
npm run check
npm test
```

`npm test` builds before Vitest, so the stdio integration test never relies on stale `dist` output.
The suite exercises real MCP clients over Streamable HTTP and a spawned stdio process, the direct
Fabric boundary, the canonical Core fixture, content integrity, and adapter security controls.

Run the included fixture through stdio:

```bash
QAM_GRAPH_ADAPTER=local \
QAM_GRAPH_JSON_PATH="$PWD/test/fixtures/graph.json" \
QAM_CONTENT_ADAPTER=local \
QAM_MARKDOWN_ROOT="$PWD/test/fixtures/wiki" \
npm run start:stdio
```

Run it over authenticated Streamable HTTP:

```bash
QAM_GRAPH_ADAPTER=local \
QAM_GRAPH_JSON_PATH="$PWD/test/fixtures/graph.json" \
QAM_CONTENT_ADAPTER=local \
QAM_MARKDOWN_ROOT="$PWD/test/fixtures/wiki" \
QAM_HTTP_AUTH_MODE=bearer \
QAM_MCP_BEARER_TOKEN='replace-with-a-long-random-secret' \
npm run start:http
```

The MCP endpoint is `http://127.0.0.1:3000/mcp`.

## Container image

Build from the repository root because the deployment scripts use that context:

```bash
docker build \
  --file quickagenticmemory/packages/mcp/Dockerfile \
  --tag qam-mcp:test \
  .
```

The Node.js 22 multi-stage image compiles TypeScript, prunes development dependencies, runs as the
unprivileged `node` user, starts the HTTP transport on port 3000, handles `SIGTERM`, and includes a
`/healthz` container healthcheck. The repository-root `.dockerignore` restricts the build context to
the MCP package files required by the build.

## Evaluation

[`evaluation.xml`](./evaluation.xml) contains ten independent, stable, read-only questions over the
included fixture. They require concept resolution plus traversal, provenance, or Markdown reads and
have single string-comparable answers.
