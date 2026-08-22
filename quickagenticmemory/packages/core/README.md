# Quick Agentic Memory Core

`@quick-agentic-memory/core` validates Open Knowledge Format bundles and projects their Markdown concepts into a deterministic graph snapshot. GitHub remains the source of truth; the snapshot contains metadata, provenance, and relationships, not the Markdown body.

The validator targets the official [Open Knowledge Format v0.2 specification](https://github.com/GoogleCloudPlatform/open-knowledge-format/blob/main/SPEC.md).

## Install and verify

Node.js 20 or newer is required.

```bash
npm ci
npm run verify
```

`verify` runs strict TypeScript checking, all unit/integration tests, and a production build.

## CLI

During development:

```bash
npm run dev -- validate ../../knowledge
npm run dev -- validate ../../knowledge --strict --json
npm run dev -- project ../../knowledge --output ../../artifacts/graph
```

After `npm run build`:

```bash
node dist/cli.js validate /path/to/bundle
node dist/cli.js project /path/to/bundle --output /path/to/output
```

The project command reads the commit SHA, commit timestamp, origin remote, and bundle path from Git. It fails closed when the bundle contains modified, staged, untracked, or ignored content; changes elsewhere in the worktree do not block it. Metadata overrides are assertions and must match the clean worktree rather than bypassing this check. CI can assert its checked-out SHA and canonical repository URL:

```bash
node dist/cli.js project /path/to/bundle \
  --output /path/to/output \
  --git-sha "$GITHUB_SHA" \
  --repository "https://github.com/example/repository"
```

`generatedAt` is the Git commit timestamp, not the wall-clock projection time. Identical content and metadata therefore produce byte-identical exports. Credential-bearing HTTP remotes are sanitized before being written.

Exit codes are `0` for success, `1` for validation failure, and `2` for CLI or I/O errors. Default OKF validation fails only on conformance errors. `--strict` additionally fails on warnings such as broken links or malformed optional v0.2 fields.

## OKF validation behavior

Hard errors follow OKF v0.2 conformance:

- Every non-reserved `.md` file needs parseable YAML frontmatter and a non-empty `type`.
- `index.md` and `log.md` must follow their reserved structures.
- Documents must be valid UTF-8.

The validator deliberately does not reject unknown types, unknown frontmatter fields, absent optional families, or broken cross-links. Provenance, trust, lifecycle, actor, timestamp, and Attested Computation shapes produce warnings when present but malformed. A bare `verified: { by, at }` mapping is normalized as the one-element list required for consumers.

An empty bundle remains diagnosable as the `EMPTY_BUNDLE` validator warning, but it cannot be
projected: the canonical graph contract requires at least one node so the flat Fabric projection
can carry its immutable source provenance. A bundle with one isolated concept and zero edges is
valid and exports an empty `edges.ndjson`.

## Graph model

The projector creates four node kinds:

- `Concept`: one non-reserved OKF document.
- `Tag`: one normalized value from `tags`.
- `Source`: one canonical `sources[].resource`.
- `Term`: one normalized explicit alias.

It creates four directed edge types:

- `LINKS_TO`: Concept → Concept for a resolvable Markdown link.
- `HAS_TAG`: Concept → Tag.
- `DERIVED_FROM`: Concept → Source.
- `ALIASED_AS`: Concept → Term.

Repeated links and repeated normalized values are de-duplicated. All nodes and edges are sorted deterministically.

OKF defines a Concept ID as its bundle-relative path without `.md`. Consequently, the default Concept node ID changes when a file is moved. Authors who need rename-stable identity can use this optional producer extension:

```yaml
x-qam:
  uid: urn:uuid:0198d5c6-5ca2-7e52-84be-32f9f4f3aa13
  aliases:
    - Fabric Graph Projector
    - OKF Fabric Projector
```

For migration compatibility, top-level `uid`/`aliases` and `x-kg.uid`/`x-kg.aliases` are also consumed. These are projector extensions; they do not change OKF conformance because OKF consumers must preserve and tolerate unknown keys.

UIDs must be unique within a bundle. A duplicate produces `DUPLICATE_CONCEPT_UID` warnings and path-disambiguated IDs so that two documents are never silently merged; strict validation rejects that warning.

## Export files

Each projection writes:

| File | Purpose |
| --- | --- |
| `graph.json` | Gateway-friendly aggregate `{ schemaVersion, okfVersion, source, nodes, edges }`. |
| `manifest.json` | Projector version, Git provenance, bundle digest, per-file hashes, and counts. |
| `nodes.json` | The sorted graph node array. |
| `edges.json` | The sorted graph edge array. |
| `nodes.ndjson` | Flat, line-oriented rows for a OneLake `QamNode` table. |
| `edges.ndjson` | Flat, line-oriented rows for a OneLake `QamEdge` table. |

The NDJSON files contain one JSON object per line and no nested values. Node arrays are stored in the string columns `tagsJson`, `aliasesJson`, `sourceIdsJson`, `authorsJson`, and `usageCountsJson`; inapplicable optional values are `null`. Every node row repeats `projectionId`, `commitSha`, `repository`, `projectionGeneratedAt`, and `okfVersion`; every edge repeats the same immutable `projectionId` and `commitSha`. Fabric can therefore reject a mixed node/edge snapshot instead of relying on deployment-time environment variables or the current clock. This gives Fabric ingestion a stable flat schema while preserving the richer aggregate contract.

The complete `QamNode` column order is `id`, `kind`, `title`, `type`, `path`, `repositoryPath`, `conceptId`, `tagsJson`, `aliasesJson`, `projectionId`, `commitSha`, `repository`, `projectionGeneratedAt`, `okfVersion`, `summary`, `resource`, `status`, `contentHash`, `sourceUrl`, `normalizedValue`, `sourceIdsJson`, `authorsJson`, `usageCountsJson`, `lastModified`. `QamEdge` uses `id`, `from`, `to`, `type`, `projectionId`, `commitSha`, `label`, `sourcePath`. The exact limits and failure behavior are defined by the canonical [`qam-graph/1.0` contract](../../contracts/README.md); Core executes it both after projection and immediately before serialization.

Concept nodes match the MCP gateway's expected fields (`id`, `title`, bundle-relative `path`, repository-relative `repositoryPath`, `type`, `tags`, `aliases`, `summary`, `projectionId`, `commitSha`, `sourceUrl`). The local adapter uses `path`; the GitHub adapter uses only `repositoryPath`. Every graph node also carries `kind`; non-Concept node properties depend on that discriminator. Edges use `id`, `from`, `to`, `type`, `projectionId`, `commitSha`, optional `label`, and `sourcePath`.

The checked-in [`test/fixtures/gateway-graph.json`](test/fixtures/gateway-graph.json) is a minimal real full-graph snapshot containing every node and edge kind. Matching `gateway-nodes.ndjson` and `gateway-edges.ndjson` files provide the exact flat Fabric contract. Their source OKF bundle lives in `test/fixtures/okf/`, and a synchronization test fails if projector behavior changes without deliberately updating the gateway contract fixtures.

## Library API

```ts
import {
  projectBundle,
  serializeProjection,
  validateBundle,
  writeProjection,
} from "@quick-agentic-memory/core";

const validation = await validateBundle("./knowledge");

// The bundle must be clean and committed. SHA, commit time, repository path,
// and origin metadata are discovered from its Git worktree.
const projection = await projectBundle("./knowledge");

await writeProjection(projection, "./artifacts/graph");
const inMemoryFiles = serializeProjection(projection);
```

Lower-level exports include `loadBundle`, `parseMarkdownDocument`, `validateLoadedBundle`, `projectValidatedBundle`, `resolveLink`, stable ID helpers, frontmatter helpers, and the flat-row adapters `flattenNode`/`flattenEdge`. `flattenNode` takes both a node and the snapshot-level `FlatNodeProjectionMetadata` copied onto its row.
