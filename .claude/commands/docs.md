# teru Documentation Update

Audit and update all docs to match the current codebase. Designed to run before each release.

## Scope

$ARGUMENTS

If no arguments: full audit of all docs. If argument given (e.g., "persist_session", "workspaces"), focus on that feature.

## Doc Style

- **Concise and direct** — no filler, no marketing speak, no "simply" or "just"
- **Code-first** — show config examples, CLI commands, code snippets before prose
- **Complete** — every config option, every keybind, every CLI flag must be documented
- **SSG-ready** — docs will become a static site. Use proper markdown structure: front-matter friendly headings, relative links between docs, consistent formatting
- **Scannable** — tables for options, code blocks for examples, short paragraphs

## Protocol

### Phase 1: Audit

For each doc file, check if the content matches the current code:

1. **`docs/CONFIGURATION.md`** — Cross-reference against `src/config/Config.zig` fields (lines 114-195) and `applyField()` parsing. Every config field must have a row in a table with type, default, and description. Check: are any new fields missing from docs?
   ```bash
   # Extract all config field names from code
   grep -E '^\w+:' src/config/Config.zig | grep -v '//' | head -40
   ```

2. **`docs/KEYBINDINGS.md`** — Cross-reference against `src/core/KeyHandler.zig` action enum and `src/config/Keybinds.zig`. Every bindable action must be listed.
   ```bash
   grep -E 'pub const Action' src/core/KeyHandler.zig
   grep '^\.' src/core/KeyHandler.zig | head -40
   ```

3. **`docs/AI-INTEGRATION.md`** — Cross-reference against `src/agent/McpServer.zig` tool list. Every MCP tool must be documented.
   ```bash
   grep 'tool_name\|"name"' src/agent/McpServer.zig | head -30
   ```

4. **`docs/ARCHITECTURE.md`** — Check module list against `src/` directory tree. Are new modules missing?
   ```bash
   ls -d src/*/
   ```

5. **`docs/INSTALLING.md`** — Check build commands match `Makefile` and `build.zig`. Check binary targets match release workflow.

6. **`README.md`** — Check feature list, comparison table, version references, quick start examples.

### Phase 2: Fix

For each doc with gaps found in Phase 1:

1. **Add missing entries** — new config options, new keybinds, new MCP tools, new CLI flags
2. **Remove stale entries** — options/features that were removed or renamed
3. **Update examples** — make sure code examples actually work with current code
4. **Fix version references** — update any hardcoded version strings
5. **Keep it short** — if a section is getting long, use tables instead of prose

### Phase 3: Cross-link

Ensure docs reference each other properly:
- CONFIGURATION.md links to KEYBINDINGS.md for keybind config
- KEYBINDINGS.md links to CONFIGURATION.md for prefix_key
- AI-INTEGRATION.md links to ARCHITECTURE.md for data flow
- README.md links to all docs in a "Documentation" section
- All relative links work (no broken `../` paths)

### Phase 4: Commit

Stage and commit doc changes:
```
git add docs/ README.md
git commit -m "docs: update for v<version>"
```

## Doc Files Reference

| File | Covers | Source of truth |
|------|--------|-----------------|
| `docs/CONFIGURATION.md` | All config options, themes, hooks | `src/config/Config.zig` |
| `docs/KEYBINDINGS.md` | All key bindings, prefix commands, vi mode | `src/core/KeyHandler.zig`, `src/config/Keybinds.zig` |
| `docs/AI-INTEGRATION.md` | MCP tools, OSC 9999, agent protocol | `src/agent/McpServer.zig`, `src/agent/protocol.zig` |
| `docs/ARCHITECTURE.md` | Module layout, data flow, invariants | `src/` directory |
| `docs/INSTALLING.md` | Build from source, pre-built binaries, deps | `Makefile`, `build.zig`, `.github/workflows/release.yml` |
| `README.md` | Quick start, feature overview, comparison | All of the above |
