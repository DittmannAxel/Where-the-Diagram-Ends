---
title: No Raw Graph Queries
tags: [security, graph, decision]
status: accepted
---

# No Raw Graph Queries

Decision: agents receive fixed, validated traversal operations rather than arbitrary GQL or SQL.
The maximum neighborhood depth is two hops and shortest-path searches are capped at six hops.
This keeps authorization, resource use, and response size predictable.
