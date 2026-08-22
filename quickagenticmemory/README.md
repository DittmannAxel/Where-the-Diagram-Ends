# Quick Agentic Memory

> 🚧 **Coming soon:** This proof of concept is currently in the design and prototyping phase.

## Purpose

Quick Agentic Memory is a proof of concept for turning Markdown knowledge in GitHub into a navigable, agent-ready memory system.

The experiment explores a graph-first architecture in which:

- GitHub remains the source of truth for versioned Markdown knowledge.
- A compiler turns metadata and links into nodes and edges.
- Microsoft Fabric Graph provides the navigable knowledge index.
- An MCP connector gives Microsoft Foundry agents controlled access to the graph and its source documents.

The goal is to test whether this approach can give agents reliable, traceable context without hiding the knowledge behind a diagram. It turns the architecture into something that can be built, inspected, and proven—because seeing is believing.

[Back to Where the Diagram Ends](../README.md)
