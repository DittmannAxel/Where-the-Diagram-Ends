# Industrial component obsolescence proof

> A synthetic, commit-pinned retrieval experiment that asks a practical industrial question: when one field component reaches end of life, can an agent recover the complete controlled impact chain without mixing in a similar but unrelated installation?

The scenario models the discontinuation of the fictional `IOL-M8` eight-port IO-Link master. Two delivered machine variants use the component. Each variant has its own I/O mapping, PLC diagnostic block, parameter set, and FAT/SAT specifications. A similarly named stainless installation, `IOL-M8S`, is deliberately present as a distractor, together with superseded guidance.

The controlled synthetic demonstration compares two retrieval arms over exactly the same Markdown corpus and questions:

- **BM25 lexical retrieval** ranks status-filtered Markdown chunks, aggregates them to concepts, removes the focus concept, and then applies the same concept budget used by QAM. It represents only the lexical retrieval stage of a conventional RAG pipeline; it does not generate or grade an LLM answer.
- **Quick Agentic Memory** resolves the component identity, traverses bounded bidirectional `LINKS_TO` relationships, reports path coverage and provenance, and rereads selected Markdown at the exact Git commit.

The point is not that graphs universally beat RAG. The test isolates a situation where lexical similarity alone can be insufficient: impact analysis benefits from stable identity, bounded link traversal, lifecycle status, exclusions, and source provenance. The graph does not infer typed industrial dependencies; it follows the generic links authored in the synthetic Markdown.

## Directory map

| Path | Purpose |
| --- | --- |
| [`code/`](code/) | Deterministic BM25/QAM runner, contracts, tests, and the offline evidence report generator. |
| [`data/`](data/) | Synthetic linked `.md` knowledge, evaluation questions, and human-authored gold truth. |
| [`screens/`](screens/) | Presentation screenshots plus machine-readable, non-secret evidence from clean local and authorized cloud runs. |

## Industrial question

The main case asks:

> Which delivered variants use `IOL-M8`, and which I/O mappings, PLC blocks, parameter sets, service/change records, and FAT/SAT specifications must be reviewed—without including `IOL-M8S` or superseded guidance?

The expected impact chains are:

```text
IOL-M8
├── PKG-200/V500 ── IO-MAP-17 · FB_IO_DIAG · PARAM-SET-17 · FAT-042 · SAT-021
└── PAL-80/V2    ── IO-MAP-22 · FB_PALLET_DIAG · PARAM-SET-09 · FAT-057 · SAT-011
```

`NXL-R8` is only a replacement candidate. The synthetic records never claim that it is a released drop-in replacement. FAT/SAT files are controlled test specifications, not fabricated proof that a physical machine test was executed.

## Reproduce the local proof

From the repository root, install the shared workspace dependencies once and run the scenario:

```bash
npm --prefix quickagenticmemory ci
cd quickagenticmemory/tests/industrial-component-obsolescence/code
npm test
./run.sh --require-clean-commit
```

The strict run refuses to present a clean evidence receipt unless `data/knowledge/` is tracked and unchanged at the selected Git commit. It writes the report, results, and projected graph artifacts below `screens/evidence/latest/`.

That output directory contains the tracked publication evidence, so reproducing the local report
intentionally changes the checkout. Use a separate fresh detached checkout for the cloud path; the
cloud driver rejects tracked source changes.

## Deploy the cloud proof in another tenant

The repository contains a complete tenant-neutral driver. Tenant identities, resource IDs, names,
model quota, and the approved Git commit remain runtime inputs below the ignored `.artifacts/`
boundary.

From the repository root, copy and populate the cloud configuration, then run the canonical driver:

```bash
mkdir -p quickagenticmemory/.artifacts
cp \
  quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-config.example.json \
  quickagenticmemory/.artifacts/cloud-config.json
```

Edit the ignored copy, replace every placeholder, and keep the fixed acceptance contract described
in the [cloud runbook](../../docs/CLOUD_REPRODUCTION.md#3-prepare-the-untracked-configuration).

```bash
quickagenticmemory/tests/industrial-component-obsolescence/code/cloud-run.sh \
  --config quickagenticmemory/.artifacts/cloud-config.json
```

The source must be a clean checkout of one public 40-character Git SHA whose **QAM validate /
validate** check passed. The driver performs the foundation, platform, projection, Fabric,
ACR-image, Entra, Container App, Foundry Agent Application, smoke, and acceptance stages. It emits
`cloud-acceptance.json` only when the exact commit, graph, source reread, identities, and four MCP
tool events agree.

Follow the [complete public-SHA installation runbook](../../docs/CLOUD_REPRODUCTION.md) for tools,
permissions, resource-provider registration, OIDC bootstrap, required config fields, staged resume,
receipt verification, and the post-test Fabric-capacity lifecycle step. The lower-level component
commands remain documented in the [infrastructure guide](../../infra/README.md) for operators who
need a manual or GitHub Actions deployment path.

## Acceptance gates

For every gold case, QAM must:

1. resolve the intended component UID from the question's entity term;
2. retrieve every required controlled concept within at most two hops;
3. retrieve none of the explicitly excluded distractors;
4. match required lifecycle states;
5. meet the harness minimum precision of `0.8`;
6. cover every required bounded `LINKS_TO` path; and
7. keep graph, provenance, and source reads on one full Git SHA.

Path coverage is a QAM capability gate. It is `N/A` for the BM25 arm rather than an artificial zero and is not used to manufacture a path-recall delta.

Both arms disclose their retrieval units and budgets. The report also states the experiment's limitations, including the synthetic corpus, the absence of generated-answer grading, and the likelihood that stronger hybrid or GraphRAG baselines narrow the measured gap.

[Back to Quick Agentic Memory](../../README.md)
