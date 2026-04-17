---
title: "Your AI Agent Can't Read Your Docs — Here's a 60ms Fix"
date: "2026-04-11"
description: "gnosis-mcp: an MCP server with 2 dependencies that makes your private docs searchable by AI agents in 60ms. SQLite, FTS5, git history indexing."
author: "Nicholas Glazer"
tags: ["gnosis-mcp", "mcp", "ai-tools", "documentation", "sqlite"]
published: true
---

Your AI coding agent can read every file in your repository. It can grep through thousands of lines, understand complex codebases, and write code that fits your patterns.

But it can't read your documentation.

Not the docs in your repo — it reads those fine. The *other* documentation. The architecture decisions you wrote in Confluence. The integration guides scattered across Notion. The onboarding runbooks in Google Docs. The tribal knowledge that lives in your head and comes out as "we don't call that API without rate limiting because last March..."

Every time you start a new session, you re-explain the same context. Every time.

## The standard answer costs 100 dependencies

The default solution in 2026 is "set up a RAG pipeline." LangChain, LlamaIndex, and their ecosystem solve this problem. They solve it like this:

```bash
pip install langchain langchain-community langchain-openai chromadb tiktoken
```

That's 50+ transitive dependencies. Then you write 100+ lines of Python to configure a retriever, manage chunking, set up embeddings, and wire it into your agent. You maintain a separate service. You debug pydantic v1 vs v2 conflicts.

MemPalace — the viral AI memory system with 40K GitHub stars — takes a different approach. It uses ChromaDB for vector storage and claims 96.6% recall on LongMemEval. But install it and count what lands in your `site-packages`:

| Tool | Direct deps | Transitive deps | Requires |
|------|------------|-----------------|----------|
| LangChain RAG | 5+ | 50+ | OpenAI API key |
| MemPalace | 2 | **~100** | Python 3.9-3.12 only |
| Context7 | npm package | cloud service | Upstash API key |
| **gnosis-mcp** | **2** | **~31** | nothing |

MemPalace pulls numpy, onnxruntime, grpcio, kubernetes, fastapi, and tokenizers — for a documentation search tool. I tried to benchmark it against gnosis-mcp on Python 3.14. It crashed with a pydantic v1 compatibility error in ChromaDB before indexing a single document.

Context7 solves a different problem entirely: it indexes *public* library docs (React, Next.js). Your private architecture decisions aren't in their database.

## 4 commands, 2 dependencies

[gnosis-mcp](https://github.com/nicholasglazer/gnosis-mcp) is an MCP server that makes your documentation searchable by any AI agent. It has two required dependencies: `mcp` and `aiosqlite`.

```bash
pip install gnosis-mcp
gnosis-mcp init-db
gnosis-mcp ingest ./docs/
gnosis-mcp serve
```

That's it. Your agent can now search your docs.

`init-db` creates a SQLite database with FTS5 full-text search indexes. `ingest` reads your markdown files, chunks them intelligently (respecting heading boundaries), computes SHA-256 content hashes for deduplication, and stores them with full-text indexing. `serve` starts an MCP server over stdio that any MCP client can connect to.

No vector database. No embedding model download. No API keys. No Docker.

You can verify it works before connecting an agent:

```bash
$ gnosis-mcp search "authentication middleware"

  architecture.md  (score: 12.4)
  We use JWT tokens with refresh rotation. The middleware
  validates tokens on every request and handles...

  decisions/2024-auth-rewrite.md  (score: 8.7)
  The old session-based auth stored tokens in cookies.
  We switched to JWT because...
```

Search results include highlighted snippets with matched terms, scored by FTS5 relevance. About 600 tokens per search result — compared to 3,000-8,000 tokens if your agent reads the full files.

## The git history trick

Here's the feature nobody else has: `ingest-git` turns your entire commit history into searchable documentation.

```bash
gnosis-mcp ingest-git /path/to/repo
```

I ran this against [teru](https://github.com/nicholasglazer/teru) (my terminal emulator, 60 source files, 200+ commits). Results:

- **120 files indexed**, 461 chunks, 4,780 cross-file links
- **1.15 seconds** total ingest time
- Every commit message, every file touched, every change — searchable

Now my AI agent can answer "why did we add left/right scroll margins?" by searching git history:

```
$ gnosis-mcp search "DECLRMM left right margins" --category git-history

  git-history/src/core/Grid.zig  (score: 29.0)
  left/right scroll margins (DECLRMM/DECSLRM) — fixes tmux vertical splits
  Author: ng

  Implement ECMA-48 left/right scroll margins:
  - Grid: left_margin, right_margin, margins_enabled fields...
```

Score 29.0. Found the exact commit, the author, and the implementation summary. In 60 milliseconds.

This is the context that lives in `git log` but never makes it into documentation. Architecture decisions. Bug fixes with reasoning. Refactoring motivations. It's all there — nobody indexes it.

## Benchmark: 549 chunks in 63ms

I benchmarked gnosis-mcp on the teru codebase (8 documentation files + 120 git history files = 549 total chunks, 2.5MB database). Eight different query types, ten runs each, measuring wall-clock time including process startup:

| Query Type | p50 | p99 | Description |
|------------|-----|-----|-------------|
| Exact term | 64ms | 68ms | `DECLRMM` |
| Multi-keyword | 65ms | 73ms | `SIMD rendering performance frame` |
| Natural question | 64ms | 69ms | `how does the daemon persist sessions` |
| Code symbol | 64ms | 69ms | `posix_openpt fork exec` |
| Broad topic | 64ms | 71ms | `keyboard layout handling` |
| Git history | 64ms | 84ms | `selection bug fix` |
| Config lookup | 63ms | 69ms | `scrollback_lines opacity font_size` |
| Feature search | 63ms | 69ms | `MCP tools teru_list_panes` |

**p50 across all queries: 63ms.** Consistent regardless of query type. FTS5 doesn't care whether you're searching docs or git history — it's the same index.

The honest comparison: MemPalace uses vector embeddings, which are better for fuzzy semantic queries ("things related to authentication"). gnosis-mcp uses keyword search, which is better for exact technical terms ("DECLRMM", "posix_openpt"). If you need semantic search, gnosis-mcp supports it too — `pip install gnosis-mcp[embeddings]` adds a local ONNX model (~23MB) for hybrid keyword+vector search. No API key needed.

But for the question "what does our codebase say about X" — keyword search at 63ms beats a 500MB ChromaDB instance every time.

### Ingest benchmarks

| Operation | Time | Output |
|-----------|------|--------|
| `init-db` | 67ms | Empty SQLite + FTS5 indexes |
| Ingest 8 markdown files | 133ms | 88 chunks |
| Ingest 120-file git history | 1.15s | 461 chunks, 4,780 links |
| Re-ingest (unchanged files) | 71ms | SHA-256 hash skip |
| Database size | — | 2.5MB |

Re-ingest is near-instant because gnosis-mcp hashes every chunk. If the content hasn't changed, it skips. This means you can run `ingest` in a pre-commit hook or CI step without penalty.

## Wire it into Claude Code

Add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "gnosis": {
      "command": "gnosis-mcp",
      "args": ["serve"]
    }
  }
}
```

Claude Code now has access to 9 tools and 3 resources:

**Search & retrieve:** `search_docs`, `get_doc`, `get_related`, `search_git_history`, `get_context`, `get_graph_stats`

**Write (opt-in):** `upsert_doc`, `delete_doc`, `update_metadata`

**Resources:** `gnosis://docs`, `gnosis://docs/{path}`, `gnosis://categories`

The read tools are available by default. Write tools require `GNOSIS_MCP_WRITABLE=true` — your agent can't accidentally modify your knowledge base.

If you're using [teru](https://teru.sh) as your terminal, the two MCP servers complement each other: teru controls panes and processes, gnosis-mcp searches documentation. Different socket, different concern, same agent.

## What to feed it

The docs that matter most are the ones your agent asks about repeatedly:

- **Architecture decisions** — why you chose PostgreSQL over MongoDB, why the API is structured this way
- **Integration guides** — how to talk to the payment provider, what the webhook format looks like
- **Runbooks** — incident response, deployment procedures, database migration steps
- **Onboarding docs** — the things you explain to every new developer (and every new Claude session)

Export from Confluence/Notion as markdown. Drop them in a directory. Run `ingest`. Done.

```bash
pip install gnosis-mcp
gnosis-mcp init-db
gnosis-mcp ingest ./docs/
gnosis-mcp ingest-git .
```

Four commands. Two dependencies. Sixty milliseconds.

[GitHub](https://github.com/nicholasglazer/gnosis-mcp) | [PyPI](https://pypi.org/project/gnosis-mcp/) | [AUR](https://aur.archlinux.org/packages/python-gnosis-mcp)
