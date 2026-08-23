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
| [`data/`](data/) | Synthetic OKF knowledge, evaluation questions, and human-authored gold truth. |
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

From this directory:

```bash
cd code
npm test
./run.sh --require-clean-commit
```

The strict run refuses to present a clean evidence receipt unless `data/knowledge/` is tracked and unchanged at the selected Git commit. It writes the report, results, and projected graph artifacts below `screens/evidence/latest/`.

## Deploy the cloud proof in another tenant

The repository contains the complete tenant-neutral automation. Tenant identities, resource IDs, names, model quota, and the approved Git commit remain runtime inputs and are never checked into parameter files.

After creating the foundation and the two distinct managed identities described in the [infrastructure guide](../../infra/README.md), an authorized operator can deploy or reconcile the paid platform, Fabric items, reviewed Preview workspace roles, and a real Foundry inference in one command:

```bash
quickagenticmemory/scripts/deploy-industrial-platform.sh \
  --resource-group '<isolated-resource-group>' \
  --location '<supported-azure-region>' \
  --environment test \
  --fabric-admin-member '<fabric-capacity-admin-upn>' \
  --operator-principal-id '<foundry-operator-user-object-id>' \
  --runtime-principal-id '<mcp-runtime-managed-identity-object-id>' \
  --deployment-principal-id '<github-environment-oidc-object-id>' \
  --fabric-sku F64
```

This command intentionally has no mandatory `what-if` step. It uses Bicep for the F capacity and Foundry account/project/model, then the public Fabric APIs for the isolated Workspace, Lakehouse, Graph Model, and checked-in Notebook. A repeated run must reuse the exact-name resources and roles. It explicitly enables the documented infrastructure guide's runtime Contributor compatibility workaround because this scenario's managed-identity Graph Preview acceptance failed under Viewer. The deployment principal is also Contributor during definition publication; an operator must downgrade that separate smoke identity to Viewer after the publication and final acceptance window.

Once the synthetic knowledge is part of an approved clean commit, build and project it:

```bash
npm --prefix quickagenticmemory run build --workspace @quick-agentic-memory/core

node quickagenticmemory/packages/core/dist/cli.js project \
  quickagenticmemory/tests/industrial-component-obsolescence/data/knowledge \
  --output quickagenticmemory/.artifacts/industrial-projection
```

Then publish that immutable projection and require the Notebook, generated public Graph definition, official on-demand `RefreshGraph` job, and live bounded GQL query to agree on the manifest's repository, projection ID, commit, and node/edge counts:

```bash
quickagenticmemory/scripts/publish-industrial-fabric.sh \
  --workspace-id '<fabric-workspace-id>' \
  --lakehouse-id '<fabric-lakehouse-id>' \
  --notebook-id '<fabric-notebook-id>' \
  --graph-model-id '<fabric-graph-model-id>' \
  --projection-dir quickagenticmemory/.artifacts/industrial-projection \
  --acceptance-cleanup \
  --definition-updater-principal-id '<deployment-service-principal-object-id>'
```

The optional cleanup is explicit and runs only after the manifest-bound live GQL succeeds. It requires a workspace Admin, fails instead of touching ambiguous or broader Member/Admin assignments, and adds the verified Viewer cleanup receipt to the publication receipt. It can also be rerun separately with `finalize-fabric-definition-updater.sh` if the publication succeeded but the Admin activation was unavailable. The cloud commands print receipts to the operator terminal. Do not commit tenant, subscription, principal, workspace, or item IDs into `screens/`; only a deliberately redacted result belongs in public evidence. GitHub source-read validation can run against `--auth-mode none` only after the approved scenario commit is actually public.

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
