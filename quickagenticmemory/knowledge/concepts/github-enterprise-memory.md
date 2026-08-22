---
type: Storage Architecture
title: GitHub enterprise memory
description: Versioned Markdown in GitHub is the authoritative knowledge record.
status: draft
tags: [github, knowledge, source-of-truth]
x-qam:
  aliases: [enterprise memory, canonical wiki]
generated: { by: process:qam-fixture, at: 2026-08-22T00:00:00Z }
sources:
  - id: github-docs
    resource: https://docs.github.com/en/repositories
    title: GitHub repositories documentation
    author: process:github-docs
---

# Purpose

Knowledge stays as human-readable Markdown, pinned to a Git commit and protected by the repository's review and security controls.[^github-docs]

The [Fabric graph index](/concepts/fabric-graph-index.md) is generated from this record. The governing decision is [GitHub remains the source of truth](/decisions/github-source-of-truth.md).

[^github-docs]: GitHub repositories documentation
