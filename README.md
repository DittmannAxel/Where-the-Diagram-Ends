# Where the Diagram Ends

> My little corner of the web for turning architectural ideas into working proofs of concept—because seeing is believing.

**Where the Diagram Ends** is my personal collection of small experiments that take architecture beyond diagrams. Each project turns an idea into something tangible, runnable, and testable: a proof that shows whether the idea actually works.

The first proof is now implemented and has passed a complete Azure cloud acceptance run.

## Why the first proof is about manufacturing

Manufacturing knowledge rarely lives in one paragraph. A component change can affect delivered machine variants, I/O mappings, PLC diagnostics, parameter sets, service records, and FAT/SAT specifications. A text-similarity retrieval stage can find content that sounds relevant while still missing part of that controlled chain, mixing a similarly named component into the result, or losing the exact source revision. This PoC tests a lexical BM25 retrieval baseline, not a complete RAG stack or generated-answer quality.

Quick Agentic Memory tests a complementary approach: keep reviewed Markdown in GitHub as the source of truth, project explicit relationships into Fabric Graph, let an agent traverse only bounded read-only paths, and reread the selected source at the same Git commit. The goal is not to replace RAG everywhere; it is to show where identity, relationships, lifecycle state, exclusions, and provenance matter as much as semantic similarity.

## Proofs of concept

- [Quick Agentic Memory](./quickagenticmemory/) — A graph-first memory proof that connects public, commit-pinned Markdown in GitHub with Microsoft Fabric Graph, an Entra-protected MCP gateway, and a Microsoft Foundry Agent Application. See the [redacted cloud evidence](./quickagenticmemory/tests/industrial-component-obsolescence/screens/).

## How to install

The repository is source-only; its npm packages are intentionally private and are not published to a package registry. To run the first proof locally, install Node.js 22 or newer and npm, then:

```bash
git clone https://github.com/DittmannAxel/Where-the-Diagram-Ends.git
cd Where-the-Diagram-Ends/quickagenticmemory
npm ci
npm run verify
npm run demo
```

The local path creates no Azure resources and needs no Docker daemon. For the complete Azure/Fabric/Foundry deployment, follow [How to deploy and test the cloud proof](./quickagenticmemory/README.md#how-to-deploy-and-test-the-complete-azure-proof) and the [step-by-step cloud runbook](./quickagenticmemory/docs/CLOUD_REPRODUCTION.md).
