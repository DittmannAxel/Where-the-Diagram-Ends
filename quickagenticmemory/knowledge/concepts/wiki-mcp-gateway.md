---
type: Agent Interface
title: Wiki MCP gateway
description: A narrow MCP interface exposes graph navigation and commit-pinned source reads.
status: draft
tags: [mcp, agents, least-privilege]
x-qam:
  aliases: [agent memory gateway, wiki connector]
generated: { by: process:qam-fixture, at: 2026-08-22T00:00:00Z }
sources:
  - id: foundry-mcp-docs
    resource: https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol
    title: Use Model Context Protocol tools with Microsoft Foundry agents
    author: process:microsoft-learn
---

# Purpose

Agents browse the [Fabric graph index](/concepts/fabric-graph-index.md), then read only the selected Markdown concepts from [GitHub enterprise memory](/concepts/github-enterprise-memory.md).[^foundry-mcp-docs]

The default interface is read-only. Any future proposal workflow must produce a reviewable change instead of mutating the protected branch directly.

[^foundry-mcp-docs]: Microsoft Foundry MCP tools documentation
