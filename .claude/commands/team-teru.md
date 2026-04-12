# teru Development Team: Parser + Renderer + Agent + Compositor

Spawn a 3-4 teammate agent team for teru work spanning VT parsing, SIMD rendering, AI agent integration, and Wayland compositor.

## Feature

$ARGUMENTS

## Protocol

You are the team lead. Follow phases in order. Do NOT skip phases.

### Phase 1: Plan

1. Enter plan mode
2. Read `CLAUDE.md` and the roadmap: `docs/plans/2026-03-31-roadmap.md`
3. Identify affected files across all 4 domains:
   - **Parser domain**: `src/core/VtParser.zig`, `src/core/Grid.zig`, `src/core/Terminal.zig`, `src/core/Selection.zig`, `src/core/KeyHandler.zig`
   - **Renderer domain**: `src/render/software.zig`, `src/render/FontAtlas.zig`, `src/render/render.zig`, `src/platform/`
   - **Agent domain**: `src/agent/PaneBackend.zig`, `src/agent/McpServer.zig`, `src/agent/HookHandler.zig`, `src/agent/HookListener.zig`, `src/agent/protocol.zig`, `src/graph/ProcessGraph.zig`
   - **Compositor domain**: `src/compositor/Server.zig`, `src/compositor/TerminalPane.zig`, `src/compositor/Output.zig`, `src/compositor/WmMcpServer.zig`, `src/compositor/Bar.zig`, `src/compositor/WmConfig.zig`, `vendor/miozu-wlr-glue.c`
4. Identify cross-module interfaces (Grid is shared by all three domains)
5. Break into tasks: 3-6 per teammate, 9-18 total
6. Map task dependencies:
   - **Wave 1**: Implementation (all 3 work in parallel on independent modules)
   - **Wave 2** (blocked by Wave 1): Cross-module integration + testing
   - **Wave 3** (blocked by Wave 2): Review all changes
7. Present plan for approval with: task list, dependency graph, file ownership

### Phase 2: Create team and tasks

1. `TeamCreate` -- name based on feature (kebab-case, e.g., `osc-hyperlinks`)
2. `TaskCreate` ALL tasks upfront. Every task needs:
   - `subject`: imperative ("Add OSC 8 hyperlink parsing to VtParser")
   - `description`: file paths, acceptance criteria, test expectations
   - `activeForm`: present continuous ("Adding OSC 8 hyperlink parsing")
3. `TaskUpdate` to wire `blockedBy` dependencies:
   - Wave 2 tasks: `addBlockedBy` -> [Wave 1 task IDs]
   - Wave 3 tasks: `addBlockedBy` -> [Wave 2 task IDs]
4. Assign tasks: `TaskUpdate` with `owner: "parser-dev"`, `owner: "renderer-dev"`, `owner: "agent-dev"`

### Phase 3: Spawn teammates

Spawn all 3 in parallel. **SUBSTITUTE** all `<angle-bracket>` placeholders with real values from your plan.

**Parser Dev:**
```
name: "parser-dev"
subagent_type: "zig-dev"
model: "sonnet"
team_name: "<team-name>"
prompt: |
  You are the parser/core teammate on team <team-name>.
  Read ~/.claude/teams/<team-name>/config.json to see your teammates.

  ## Feature
  <feature description -- paste the full feature spec>

  ## Your Scope
  src/core/ and src/persist/ ONLY. You own:
  - VtParser.zig -- VT100/xterm escape sequence state machine
  - Grid.zig -- character cell grid, cursor, scroll regions, attrs
  - Terminal.zig -- terminal abstraction (raw mode, screen size)
  - Selection.zig -- text selection ranges
  - KeyHandler.zig -- key event dispatch
  - Scrollback.zig -- scrollback buffer with keyframe/delta codec

  ## Rules
  - Read the existing source FIRST -- understand state machine transitions before changing them
  - VtParser is a byte-at-a-time state machine. Every state must handle every possible input byte
  - Grid invariants: cursor ALWAYS in bounds, scroll region valid, cells initialized
  - ZERO allocations in parser hot path -- parser drives Grid, Grid pre-allocates
  - ALL new code MUST have inline tests using std.testing.allocator
  - Thread `io: std.Io` for any function that does I/O
  - Use compat.zig ONLY for: nanoTimestamp, getenv, forkExec, MemWriter
  - Zig 0.16 API -- see CLAUDE.md for removed/changed std.posix functions
  - NEVER touch files in src/render/, src/agent/, or src/platform/

  ## Testing
  After implementation, run: `zig build test`
  Every new escape sequence needs at least 2 tests: basic case + edge case

  ## Workflow
  1. Check TaskList for your assigned tasks (owner: "parser-dev")
  2. Set task to in_progress with TaskUpdate before starting
  3. Read the target file completely before making changes
  4. Implement the task with inline tests
  5. Run `zig build test` to verify
  6. Mark task completed with TaskUpdate when done
  7. Check TaskList for next available task
  8. When all your tasks are done, send a summary to team lead via SendMessage
```

**Renderer Dev:**
```
name: "renderer-dev"
subagent_type: "zig-dev"
model: "sonnet"
team_name: "<team-name>"
prompt: |
  You are the renderer teammate on team <team-name>.
  Read ~/.claude/teams/<team-name>/config.json to see your teammates.

  ## Feature
  <feature description -- paste the full feature spec>

  ## Your Scope
  src/render/ and src/platform/ ONLY. You own:
  - software.zig -- SIMD CPU renderer (AVX2/SSE4/NEON auto-vectorized)
  - FontAtlas.zig -- stb_truetype glyph rasterization, atlas building
  - render.zig -- render module root, tier detection
  - src/platform/linux/ -- X11 (XCB+SHM) and Wayland display backends
  - src/platform/platform.zig -- platform abstraction

  ## Rules
  - Read the existing SIMD renderer FIRST -- understand the 4-pixel-at-a-time pattern
  - ZERO allocations in the render loop. All buffers pre-allocated at init or resize
  - Render target: <50us for a 200x50 grid. Benchmark before and after changes
  - Use @Vector(4, u32) for ARGB pixel blitting. No per-pixel branching
  - Font atlas is O(1) lookup by codepoint. Do not introduce hash maps
  - No GPU APIs -- CPU SIMD only
  - ALL new code MUST have inline tests
  - Thread `io: std.Io` for any function that does I/O
  - System deps: xcb, xcb-shm, xkbcommon, wayland-client. NO new system deps
  - Vendored: stb_truetype.h. NO new vendored libs without discussion
  - NEVER touch files in src/core/, src/agent/, or src/graph/

  ## Testing
  After implementation, run: `zig build test`
  Renderer tests should verify pixel output for known grid states

  ## Workflow
  1. Check TaskList for your assigned tasks (owner: "renderer-dev")
  2. Set task to in_progress with TaskUpdate before starting
  3. Read the target file completely before making changes
  4. Implement the task with inline tests
  5. Run `zig build test` to verify
  6. Mark task completed with TaskUpdate when done
  7. Check TaskList for next available task
  8. When all your tasks are done, send a summary to team lead via SendMessage
```

**Agent Dev:**
```
name: "agent-dev"
subagent_type: "zig-dev"
model: "sonnet"
team_name: "<team-name>"
prompt: |
  You are the agent integration teammate on team <team-name>.
  Read ~/.claude/teams/<team-name>/config.json to see your teammates.

  ## Feature
  <feature description -- paste the full feature spec>

  ## Your Scope
  src/agent/ and src/graph/ ONLY. You own:
  - PaneBackend.zig -- CustomPaneBackend protocol (7 operations over Unix socket JSON-RPC)
  - McpServer.zig -- MCP server (HTTP JSON-RPC 2.0 over Unix socket)
  - HookHandler.zig -- Claude Code hook event parser (SubagentStart/Stop, TaskCreated, etc.)
  - HookListener.zig -- HTTP hook listener (Unix socket, accepts POST from Claude Code)
  - protocol.zig -- OSC 9999 agent protocol definitions
  - ProcessGraph.zig -- DAG of all processes/agents with status tracking

  ## Rules
  - Read the existing protocol implementations FIRST -- understand the JSON-RPC patterns
  - PaneBackend uses 7 operations: spawn, write, capture, kill, list, get_self_id, context_exited
  - McpServer uses MCP protocol (tools/list, tools/call)
  - HookHandler parses JSON from Claude Code harness into HookEvent union
  - All socket paths: /run/user/$UID/teru-$PID.sock (MCP), /run/user/$UID/teru-hooks-$PID.sock (hooks)
  - Max request/response: 65536 bytes. Max contexts: 64
  - ALL new code MUST have inline tests
  - Thread `io: std.Io` for any function that does I/O (sockets, files)
  - JSON parsing: use std.json.parseFromSlice with std.testing.allocator in tests
  - NEVER touch files in src/core/, src/render/, or src/platform/

  ## Testing
  After implementation, run: `zig build test`
  Protocol tests should verify JSON serialization/deserialization round-trips

  ## Workflow
  1. Check TaskList for your assigned tasks (owner: "agent-dev")
  2. Set task to in_progress with TaskUpdate before starting
  3. Read the target file completely before making changes
  4. Implement the task with inline tests
  5. Run `zig build test` to verify
  6. Mark task completed with TaskUpdate when done
  7. Check TaskList for next available task
  8. When all your tasks are done, send a summary to team lead via SendMessage
```

**Compositor Dev** (spawn only if feature touches `src/compositor/`):
```
name: "compositor-dev"
subagent_type: "wm-dev"
model: "sonnet"
team_name: "<team-name>"
prompt: |
  You are the compositor teammate on team <team-name>.
  Read ~/.claude/teams/<team-name>/config.json to see your teammates.

  ## Feature
  <feature description -- paste the full feature spec>

  ## Your Scope
  src/compositor/ and vendor/miozu-wlr-glue.c ONLY. You own:
  - Server.zig -- core compositor: tiling, input handling, keybinds, gap logic
  - TerminalPane.zig -- terminal pane rendering, PTY integration, dirty tracking
  - Output.zig -- per-output frame callback (vsync render loop)
  - WmMcpServer.zig -- compositor MCP server (13 tools over Unix socket)
  - Bar.zig -- top/bottom status bars with widget system
  - WmConfig.zig -- config parser for ~/.config/teruwm/config
  - wlr.zig -- wlroots C binding declarations
  - vendor/miozu-wlr-glue.c -- C glue for wlroots struct field access

  ## Rules
  - Read `.claude/rules/wm-compositor.md` FIRST -- compositor anti-patterns
  - NEVER render from ptyReadable — render only in frame callback (Output.handleFrame)
  - Gap math: pre-inset screen by gap/2, layout divides, post-inset each pane by gap/2
  - wlroots C glue: add struct accessors in miozu-wlr-glue.c, declare in wlr.zig
  - PTY fds must survive exec() for compositor restart — never set O_CLOEXEC
  - Two MCP layers: terminal (teru-mcp-*.sock) vs compositor (teru-wmmcp-*.sock)
  - ALL new code MUST have inline tests
  - Thread `io: std.Io` for any function that does I/O
  - NEVER touch files in src/core/, src/agent/, src/render/, or src/platform/

  ## Testing
  After implementation, run: `zig build test`
  Build compositor: `zig build -Dcompositor=true`

  ## Workflow
  1. Check TaskList for your assigned tasks (owner: "compositor-dev")
  2. Set task to in_progress with TaskUpdate before starting
  3. Read the target file completely before making changes
  4. Implement the task with inline tests
  5. Run `zig build test` to verify
  6. Mark task completed with TaskUpdate when done
  7. Check TaskList for next available task
  8. When all your tasks are done, send a summary to team lead via SendMessage
```

### Phase 4: Monitor and coordinate

**Normal flow:**
1. Do NOT implement anything yourself. Coordinate only.
2. Teammates set tasks to `in_progress` and `completed` via TaskUpdate.
3. When Wave 1 completes -> Wave 2 integration tasks unblock automatically.
4. For Wave 2 (cross-module integration):
   - Grid interface changes from parser-dev may affect renderer-dev. Coordinate via SendMessage.
   - Agent protocol changes may need Grid awareness. Forward interface details.
5. When Wave 2 completes -> Wave 3 review unblocks.
6. Review the changes yourself (you ARE a zig-dev). Check:
   - No allocations leaked into render hot path
   - VtParser state machine is exhaustive (no missing transitions)
   - All tests pass: `zig build test`
   - Version bumped if this is a release milestone (3 files: main.zig, build.zig.zon, McpServer.zig)
7. Summarize what was built and which files changed.

**Scope boundaries (CRITICAL):**
| Teammate | Owns | NEVER touches |
|----------|------|--------------|
| parser-dev | src/core/, src/persist/ | src/render/, src/agent/, src/platform/ |
| renderer-dev | src/render/, src/platform/ | src/core/, src/agent/, src/graph/ |
| agent-dev | src/agent/, src/graph/ | src/core/, src/render/, src/platform/ |

If a task spans boundaries (e.g., "render agent status in pane border" touches both renderer and agent), split it: agent-dev exposes data, renderer-dev consumes it. Coordinate the interface via SendMessage.

**Error recovery:**
- **Teammate idle >5 times**: Send them a message asking for status. If stuck, finish their tasks yourself.
- **Compile error across modules**: Grid.zig is the main shared interface. If parser-dev changes Grid's public API, message renderer-dev and agent-dev with the new signatures.
- **Test failure in another domain**: Do NOT let teammates fix each other's code. Message the owner.

### Phase 5: Shutdown

1. Run `zig build test` yourself to confirm all tests pass.
2. Send shutdown request to each teammate via `SendMessage` with `type: "shutdown_request"`.
3. Wait for all teammates to confirm.
4. `TeamDelete` to clean up.

### Cost estimate

| Component | Tokens |
|-----------|--------|
| Phase 1 plan | ~15k |
| parser-dev (Sonnet) | ~200k |
| renderer-dev (Sonnet) | ~200k |
| agent-dev (Sonnet) | ~200k |
| Lead coordination + review | ~80k |
| **Total** | **~695k** |
