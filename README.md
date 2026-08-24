# Where the Diagram Ends

> **Architecture is not proven by a diagram. It is proven when the idea runs, the evidence is visible, and somebody else can reproduce it.**

[Explore the Quick Agentic Memory architecture](./quickagenticmemory/docs/ARCHITECTURE.md)

**Where the Diagram Ends** is my personal collection of small experiments that take architecture beyond diagrams. Each project turns an idea into something tangible, runnable, and testable: a proof that shows whether the idea actually works.

I work in manufacturing across several customer environments, and that experience shapes the questions I explore here. I do not reproduce or name those environments. Instead, I turn recurring patterns into independent proofs using synthetic data, so an idea can be challenged in public without exposing customer information.

> [!IMPORTANT]
> **Independent project and responsibility notice:** This is my personal, unofficial repository. It is not an official repository of any employer, customer, or vendor, and it is not endorsed or supported by them. Review the code, permissions, security settings, and resource lifecycle before use. Deploying the examples can create billable cloud resources. You are responsible for your own deployment, usage, charges, and results; use this repository at your own risk.

## The first proof: manufacturing knowledge that compounds

> **Your existing enterprise data is the gold. The next competitive advantage is a governed knowledge dimension that connects it across systems, preserves why things are related, and makes that context usable by people and agents.**

PLC, PLM, MES, and engineering systems already contain the valuable operational and engineering data. They continue to run the business and remain authoritative in their domains. The wiki neither replaces nor copies that responsibility; it adds the cross-system identities, decisions, explanations, relationships, and source references that are difficult to preserve inside any one system.

The path is combination, not rip-and-replace. GitHub provides the versioned knowledge and review surface; Azure supplies identity and a secure runtime; Microsoft Fabric derives the relationship index; and Microsoft Foundry gives agents bounded ways to use it. This is how I use Azure in these proofs: add new capabilities to the data landscape that already works, make every boundary explicit, and test whether the combination creates a measurable result.

Enterprise AI therefore needs a conversation that starts before model selection: **how can the value already stored across enterprise systems gain durable, connected context without becoming another duplicated data store?** Making scattered documents searchable is useful, but it does not automatically create institutional memory.

[Andrej Karpathy's persistent, compounding wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) suggests a compelling direction: let agents help maintain an interlinked body of ordinary `.md` files, so useful synthesis and cross-references accumulate instead of disappearing into chats. GitHub should remain the approval engine: proposed changes belong on branches and pull requests, automated checks validate them, and repository rules and reviewers decide what can merge. This repository already includes the validation workflow; branch protection, CODEOWNERS, and an agent service that creates pull requests are separate operator configuration or future work. The published agent remains strictly read-only.

The operational records stay where they belong. The `.md` files add the human-readable knowledge dimension that connects them.

Manufacturing knowledge rarely lives in one paragraph. A component change can affect delivered machine variants, I/O mappings, PLC diagnostics, parameter sets, service records, and FAT/SAT specifications. A text-similarity retrieval stage can find content that sounds relevant while still missing part of that controlled chain, mixing a similarly named component into the result, or losing the exact source revision. This PoC tests a lexical BM25 retrieval baseline, not a complete RAG stack or generated-answer quality.

Quick Agentic Memory tests a complementary approach: keep the added knowledge dimension in version-controlled `.md` files in GitHub, generate a relationship index in Fabric Graph, let an agent traverse only bounded read-only paths, and reread the selected source at the same Git commit. There is no second editable copy of the wiki: **the operational systems hold the data; Markdown adds the cross-system knowledge; the graph holds only the routes through it.** The goal is not to replace RAG everywhere, but to show where identity, relationships, lifecycle state, exclusions, and provenance matter as much as semantic similarity.

The first proof is implemented and has passed a complete Azure cloud acceptance run.

## Proofs of concept

- [Quick Agentic Memory](./quickagenticmemory/) — A governed-memory proof that connects public, commit-pinned `.md` files in GitHub with a rebuildable Microsoft Fabric Graph index, an Entra-protected MCP gateway, and a Microsoft Foundry Agent Application. See [why the proof exists](./quickagenticmemory/#why-this-proof-exists) and the [redacted cloud evidence](./quickagenticmemory/tests/industrial-component-obsolescence/screens/).

## How to install

The repository is source-only; its npm packages are intentionally private and are not published to a package registry. To run the first proof locally, install Node.js 22 or newer and npm, then:

```bash
git clone https://github.com/DittmannAxel/Where-the-Diagram-Ends.git
cd Where-the-Diagram-Ends/quickagenticmemory
npm ci
npm run verify
npm run demo
```

The local path creates no Azure resources and needs no Docker daemon. See the guided [demo walkthrough](./quickagenticmemory/README.md#demo-walkthrough-what-you-will-see) to present the manufacturing comparison and its recorded cloud evidence. For the complete Azure/Fabric/Foundry deployment, follow [How to deploy and test the cloud proof](./quickagenticmemory/README.md#how-to-deploy-and-test-the-complete-azure-proof) and the [step-by-step cloud runbook](./quickagenticmemory/docs/CLOUD_REPRODUCTION.md).
