# qam-graph/1.0 contract

[`qam-graph-1.0.ts`](./qam-graph-1.0.ts) is the canonical executable contract between the
Core projector, the flat Fabric tables, and the MCP gateway. Core validates the complete graph
before returning a projection and validates it again immediately before JSON or NDJSON
serialization. MCP executes the byte-identical schema for local JSON and reconstructed Fabric
snapshots.

Package builds remain independent: the canonical source is copied to each package as
`src/qam-graph-contract.ts`. `node scripts/sync-graph-contract.mjs` refreshes those generated
copies; `node scripts/sync-graph-contract.mjs --check` fails when either copy differs. Both package
test lifecycles run the check, so the slim MCP Docker build does not need Core or the repository's
contract directory at runtime.

## Limits

| Value | Contract |
| --- | --- |
| Snapshot | 1–100,000 nodes and 0–500,000 edges |
| OKF version | 1–50 characters |
| Repository | 1–500 characters |
| Node ID / edge endpoint | 1–512 safe concept-ID characters |
| Edge ID | 1–512 characters |
| Title | 1–1,024 characters |
| Type | 1–100 characters |
| Repository path | 1–1,024 characters; relative, supported segments, no traversal or empty segments |
| Concept ID property | 1–1,024 characters |
| Tags | at most 100; each 1–300 characters |
| Aliases | at most 100; each 1–1,024 characters |
| Summary | at most 4,000 characters |
| Resource | 1–4,096 characters |
| Normalized tag/term value | 1–1,024 characters |
| Source IDs | at most 100; each 1–1,024 characters |
| Authors | at most 100; each 1–1,024 characters |
| Usage counts | at most 100; each a non-negative safe integer |
| Edge label | optional; when present, 1–300 characters |

Commit IDs are lowercase full 40- or 64-character hexadecimal Git object IDs. Projection IDs are
`urn:qam:projection:` plus a lowercase SHA-256 value. Content hashes are lowercase SHA-256 values.
`generatedAt` and `lastModified` require ISO 8601 date-times with an explicit offset. `sourceUrl`,
when present, must be a URL.

Every edge type has one canonical endpoint-kind pair: `LINKS_TO` is Concept → Concept,
`HAS_TAG` is Concept → Tag, `DERIVED_FROM` is Concept → Source, and `ALIASED_AS` is Concept →
Term. The executable snapshot contract and the Fabric ingestion notebook both reject any other
pairing. A snapshot must contain at least one node so that its immutable projection provenance is
representable in the flat Fabric profile. It may contain zero edges; its flat `edges.ndjson`
representation is then an empty file.

## Failure and optional-field behavior

There is no truncation. Any required value, repeated-value collection, provenance value, or
snapshot relationship outside the contract makes projection fail before export. In non-strict
mode, Core deliberately omits permissive optional source metadata that cannot satisfy the graph
contract: fractional, negative, or unsafe `usage_count` values and malformed `last_modified`
timestamps remain validator warnings but never reach the graph. Strict mode already rejects those
warnings before projection.

An edge label is optional derived display metadata. When a valid alias, source title, source ID,
resource, or Markdown link label is longer than the edge-label limit, Core deliberately omits only
that edge label; it preserves the underlying node value and relationship. A source resource may be
up to 4,096 characters; when it is longer than the title limit and no title was supplied, Core uses
the deterministic fallback title `Source` and preserves the full resource.

The Fabric projection stores arrays as JSON strings. Its decoder applies the same field-specific
limits: tags use 300 characters per item, while aliases, source IDs, and authors use 1,024. It
rejects malformed JSON, 101-element arrays, and over-limit values before constructing the graph.
