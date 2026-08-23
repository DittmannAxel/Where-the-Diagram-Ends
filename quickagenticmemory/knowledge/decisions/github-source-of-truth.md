---
type: Architecture Decision
title: GitHub remains the source of truth
description: Fabric stores a rebuildable index, while reviewed Markdown remains authoritative.
status: draft
tags: [decision, github, provenance]
x-qam:
  aliases: [ADR source of truth]
generated: { by: process:qam-fixture, at: 2026-08-22T00:00:00Z }
sources:
  - id: local-github-concept
    resource: ../concepts/github-enterprise-memory.md
    title: GitHub enterprise memory concept
    author: process:qam-fixture
---

# Decision

The [GitHub enterprise memory](/concepts/github-enterprise-memory.md) is authoritative. The [Fabric graph index](/concepts/fabric-graph-index.md) records the exact source commit and can always be regenerated.

# Consequence

Every answer returned through the [Wiki MCP gateway](/concepts/wiki-mcp-gateway.md) can expose its source path and commit, while graph corruption never destroys the underlying knowledge.
