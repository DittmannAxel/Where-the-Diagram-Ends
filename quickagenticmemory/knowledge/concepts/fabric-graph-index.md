---
type: Derived Knowledge Index
title: Fabric graph index
description: A commit-pinned graph projection makes Markdown relationships navigable.
status: draft
tags: [fabric, graph, derived-index]
x-qam:
  aliases: [knowledge graph, navigation index]
generated: { by: process:qam-fixture, at: 2026-08-22T00:00:00Z }
sources:
  - id: fabric-graph-docs
    resource: https://learn.microsoft.com/fabric/graph/overview
    title: Microsoft Fabric Graph overview
    author: process:microsoft-learn
---

# Purpose

The projector turns OKF concepts, links, tags, aliases, and provenance into a deterministic graph snapshot.[^fabric-graph-docs]

It reads the [GitHub enterprise memory](/concepts/github-enterprise-memory.md) and is queried only through the [Wiki MCP gateway](/concepts/wiki-mcp-gateway.md). Because it is derived, it can be deleted and rebuilt without losing knowledge.

[^fabric-graph-docs]: Microsoft Fabric Graph overview
