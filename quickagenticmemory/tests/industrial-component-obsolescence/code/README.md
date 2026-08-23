# Industrial component-obsolescence A/B evaluation

This directory contains a deterministic **retrieval evaluation**, not an LLM answer grader. It compares two arms over exactly the same Markdown snapshot:

- **Arm A — local BM25 lexical retrieval:** Markdown is split into bounded sections, concept metadata is attached to every chunk, and BM25 ranks the chunks. The best chunk per concept is retained, the focus concept is removed, and only then is the concept budget applied. There are no embeddings, reranker, generation model, or fabricated semantic/hallucination scores.
- **Arm B — Quick Agentic Memory:** the existing QAM Core projects the OKF bundle, and the existing MCP adapters perform alias resolution, backlinks, bounded neighbor traversal, path finding, provenance tracing, and content-hash-checked reads at one Git commit.

Both arms use the question's `top_k` as a concept output budget after resolving/removing the focus concept. Both receive the same visible query-derived terms, lifecycle filter, and result-type scope. Arm A still reports its supporting best chunk for auditability.

## Required data layout

```text
../data/
├── knowledge/
│   ├── index.md
│   └── ... valid OKF 0.2 Markdown concepts
├── gold/
│   └── gold.json
└── questions/
    └── questions.json
```

`questions/questions.json`:

```json
{
  "schema_version": "qam-industrial-questions/1.0",
  "dataset_version": "1.0.0",
  "questions": [
    {
      "id": "Q-001-full-impact",
      "query": "Which delivered variants use IOL-M8, and which I/O mappings and FAT/SAT cases must be reviewed?",
      "terms": ["IOL-M8", "delivered variants", "I/O mappings", "FAT", "SAT"],
      "focus_concept_uid": "urn:qam:industrial:component:iol-m8",
      "allowed_statuses": ["stable"],
      "top_k": 12,
      "max_hops": 2
    }
  ]
}
```

`gold/gold.json`:

```json
{
  "schema_version": "qam-industrial-gold/1.0",
  "dataset_version": "1.0.0",
  "cases": [
    {
      "question_id": "Q-001-full-impact",
      "required_concept_uids": ["urn:qam:industrial:machine-variant:pkg-200-v500"],
      "excluded_concept_uids": ["urn:qam:industrial:component:iol-m8s"],
      "required_statuses": {
        "urn:qam:industrial:machine-variant:pkg-200-v500": "stable"
      },
      "required_paths": [
        [
          "urn:qam:industrial:component:iol-m8",
          "urn:qam:industrial:machine-variant:pkg-200-v500"
        ]
      ]
    }
  ]
}
```

Every required path must start with the configured focus UID and contain no more than two generic `LINKS_TO` graph hops (three UIDs). Traversal is bidirectional for this test, so a path is coverage evidence rather than a claim that the Markdown link direction encodes an industrial dependency. The focus UID is an assertion on entity resolution; it is never used to choose a result. Gold UIDs must not include the focus concept itself in `required_concept_uids`.

`terms[0]` is the component/entity mention used for the first `resolve_concepts` call. Every term must occur visibly in the question. Additional terms describe the requested impact slice and rank the complete bounded traversal by matched-term count, QAM resolution score, distance, title, and UID. This deterministic rule is part of the public question contract; it avoids using gold UIDs or paths as hidden retrieval hints.

`expected_commit_sha` is optional. If omitted, the selected runtime HEAD is the expectation. It may instead be a full 40/64-character Git SHA; `CURRENT` is accepted for local fixtures. None of these options claims that uncommitted files belong to a commit: the report always exposes whether `data/knowledge` is tracked and byte-clean at the selected SHA.

## Run

From this directory:

```bash
./run.sh
```

For publication evidence, run from a clean checkout and require the check:

```bash
./run.sh --require-clean-commit
```

Useful explicit options:

```bash
node runner.mjs \
  --data ../data \
  --output ../screens/evidence/latest \
  --commit "$(git rev-parse HEAD)" \
  --repository https://github.com/OWNER/REPOSITORY \
  --require-clean-commit
```

The output directory receives:

- `run-results.json` — complete machine-readable evidence;
- `report-data.json` — stable, presentation-oriented HTML input;
- `report.html` — self-contained static report, suitable for screenshots;
- `qam-artifacts/` — the projected `graph.json`, manifest, node/edge JSON and NDJSON artifacts.

The command writes its evidence before returning a non-zero status for a QAM acceptance failure. QAM must meet complete required-concept recall, zero exclusions, lifecycle and path checks, commit consistency, and the declared harness minimum precision of `0.8`. Arm A is allowed to miss gold items; that is the experiment, not a runner failure.

## Authorized cloud proof

[`cloud-run.sh`](cloud-run.sh) is the fail-closed, resumable entry point for the complete cloud
acceptance chain. It does not run this directory's local A/B evaluation and does not use local
Docker. Instead, it requires one validated public Git SHA, projects that exact checkout, publishes
it through OneLake/Fabric Notebook/RefreshGraph/GQL, builds the MCP image with ACR Tasks from the
same public Git commit, deploys the digest-pinned Container App, and runs the published Foundry
four-event MCP smoke.

Copy the placeholder config into the ignored artifacts boundary before filling tenant values:

```bash
mkdir -p ../../../.artifacts
cp cloud-config.example.json ../../../.artifacts/cloud-config.json
```

From a clean checkout whose `HEAD` is the configured public commit:

```bash
./cloud-run.sh --config ../../../.artifacts/cloud-config.json
```

For a reviewed staged run:

```bash
./cloud-run.sh \
  --config ../../../.artifacts/cloud-config.json \
  --through-stage fabric

./cloud-run.sh \
  --config ../../../.artifacts/cloud-config.json \
  --resume \
  --from-stage image
```

The populated config is required to remain under `quickagenticmemory/.artifacts/`; it contains no
credentials, but it does contain tenant and identity metadata that must not be published. Every
completed stage has a commit- and config-bound receipt marker. The final private receipt is
`.artifacts/cloud-<sha-prefix>/receipts/cloud-acceptance.json`.

See the complete tenant-neutral prerequisites, stage contracts, timing guidance, and evidence
boundary in [`../../../docs/CLOUD_REPRODUCTION.md`](../../../docs/CLOUD_REPRODUCTION.md).

## Tests

```bash
npm test
```

The tests use a temporary synthetic OKF bundle and cover deterministic BM25 ranking, exact alias resolution versus the `IOL-M8S` distractor, gold-list metrics, deprecated-status filtering, required paths, schema versions, content-hash-checked reads, and commit consistency.

## Interpretation limits

This harness measures retrieval and graph evidence only. It does not establish statistical significance, production latency, answer quality, or general superiority over every RAG design. A hybrid/GraphRAG system with entity resolution and traversal may close the gap; that is a meaningful architectural result rather than a defect in the test.
