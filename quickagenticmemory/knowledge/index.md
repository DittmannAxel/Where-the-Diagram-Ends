---
okf_version: "0.2"
---

# Quick Agentic Memory knowledge bundle

This deliberately small linked `.md` knowledge set is the end-to-end test fixture for the proof of concept.

## Architecture

* [GitHub enterprise memory](concepts/github-enterprise-memory.md) - GitHub is the immutable, reviewable source of truth.
* [Fabric graph index](concepts/fabric-graph-index.md) - Microsoft Fabric provides a rebuildable navigation index.
* [Wiki MCP gateway](concepts/wiki-mcp-gateway.md) - Agents get narrow, read-only graph and content tools.

## Decisions

* [GitHub remains the source of truth](decisions/github-source-of-truth.md) - The graph is derived and can be rebuilt from a commit.
