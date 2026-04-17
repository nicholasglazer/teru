---
title: "Your AI Agent Can't Read Your Docs — Here's a 60ms Fix"
published: true
description: "gnosis-mcp: an MCP server with 2 dependencies that makes your private docs searchable by AI agents in 60ms."
tags: mcp, ai, python, opensource
canonical_url: https://teru.sh/blog/gnosis-mcp-docs-in-60ms
cover_image: 
---

Your AI coding agent can read every file in your repository. But it can't read your Confluence, Notion, Google Docs, or the tribal knowledge in your head.

[gnosis-mcp](https://github.com/nicholasglazer/gnosis-mcp) fixes this with 2 dependencies and 4 commands.

**Read the full post with benchmarks:** [teru.sh/blog/gnosis-mcp-docs-in-60ms](https://teru.sh/blog/gnosis-mcp-docs-in-60ms)

## Quick start

```bash
pip install gnosis-mcp
gnosis-mcp init-db
gnosis-mcp ingest ./docs/
gnosis-mcp serve
```

Your AI agent (Claude Code, Cursor, Windsurf, any MCP client) can now search your private documentation. SQLite + FTS5 keyword search. No vector database, no API keys, no Docker.

## The killer feature: git history as docs

```bash
gnosis-mcp ingest-git /path/to/repo
```

This indexes your entire commit history as searchable documentation. Every commit message, every file change, every architecture decision buried in `git log` — now queryable in 60ms.

## Benchmarks

Tested on a real codebase (549 chunks, 2.5MB database):

| Operation | Time |
|-----------|------|
| Ingest 8 docs | 133ms |
| Ingest 120-file git history | 1.15s |
| Search (p50, 8 query types) | **63ms** |
| Re-ingest (unchanged) | 71ms |

## Dependency comparison

| Tool | Transitive deps |
|------|----------------|
| LangChain RAG | 50+ |
| MemPalace | ~100 |
| **gnosis-mcp** | **~31** |

Full benchmarks, methodology, and Claude Code integration guide in the [full post](https://teru.sh/blog/gnosis-mcp-docs-in-60ms).

[GitHub](https://github.com/nicholasglazer/gnosis-mcp) | [PyPI](https://pypi.org/project/gnosis-mcp/)
