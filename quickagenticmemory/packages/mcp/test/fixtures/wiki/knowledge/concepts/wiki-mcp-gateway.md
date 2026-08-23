---
title: Wiki MCP Gateway
tags: [mcp, foundry, security]
---

# Wiki MCP Gateway

The gateway exposes seven bounded read-only tools. It resolves concepts and traverses the Fabric
projection, then reads original Markdown from GitHub at the graph's full commit SHA. Arbitrary
GQL, branch-name reads, absolute paths, and parent-directory traversal are rejected.
