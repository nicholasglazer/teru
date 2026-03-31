# teru — Architecture Design Document

**Date:** 2026-03-30
**Status:** Approved
**Language:** Zig (≥0.14)
**Platforms:** Linux (v1), macOS (v1.1), Windows (v2)

## Problem

Current terminal workflow (Alacritty + tmux + xmonad) has three critical pain points:

1. **Pane management friction** — moving panes between tmux windows requires arcane commands
2. **AI integration is bolted on** — when Claude Code spawns agent teams, they create random tmux panes that destroy the workspace layout, and tmux has no concept of "these belong together"
3. **Config fragility** — three layers (tmux.conf + shell scripts + xmonad keybindings) that don't compose
4. **Memory overhead** — tmux duplicates scrollback buffers inside Alacritty's own buffers, contributing to 77% RAM usage (49GB/64GB)

## Solution

teru is a single binary that replaces all three tools for terminal management. It's built around two novel concepts:

1. **Process Graph** — every process is a node in a DAG. The terminal understands parent-child relationships, agent teams, and lifecycle state.
2. **Agent Protocol** — processes can self-declare as AI agents via escape sequences. The terminal auto-organizes them into workspaces.

## Architecture

### Library-First Kernel (libteru)

libteru is a C-ABI compatible static library containing all platform-independent logic. Platform shells (GTK4, AppKit, Win32) are thin wrappers that call into libteru. This follows the Ghostty/libghostty pattern.

Modules:
- **pty** — PTY spawn/read/write/resize. POSIX on Linux/macOS, ConPTY on Windows.
- **graph** — Process DAG. Pool-allocated nodes with O(1) insert/remove.
- **agent** — OSC 9999 parser + Claude Code hook handler + MCP server.
- **core** — VT state machine (xterm-256color), terminal state, grid.
- **tiling** — Layout engine: master-stack, grid, monocle, floating.
- **config** — Lua VM (Ziglua), hot-reloadable config.
- **persist** — Session serialization, LZ4 scrollback compression, WAL.

### Thread Model

```
Shared threads (3):
  Render  — GPU frame composition, font atlas, dirty-flag driven
  Agent   — Hook handler, MCP server, OSC 9999 dispatch
  Persist — WAL flush (1s), scrollback compression, session save

Per-terminal threads (N):
  I/O — PTY read/write, VT parsing, grid updates

Total: N + 3 (not 5N)
```

Sync: I/O threads set dirty flags on grids. Render thread reads only dirty grids per frame under mutex. Lock-free SPSC queues for I/O→Agent event delivery.

### Process Graph

Pool-allocated DAG. Each node has:
- Identity: id, name, kind (shell/process/agent/group)
- Edges: parent, children (slices into pool)
- Terminal: PTY handle, grid, scrollback reference
- Lifecycle: state (running/paused/finished/persisted/interrupted), pid, exit_code, timestamps
- Agent metadata: group, role, task, progress (populated via hooks or OSC)
- Layout: workspace assignment (decoupled from graph topology)

Operations: spawn O(1), remove O(1), reparent O(1), query-by-workspace O(N), query-by-agent-group O(N).

### Agent Protocol

#### Primary: Claude Code Hook Handler

teru registers as a hook handler in `.claude/settings.json` for: SubagentStart, SubagentStop, TaskCreated, TaskCompleted, TeammateIdle. Hook payloads are JSON over stdin. teru-hook-handler binary forwards events to the Agent thread via internal Unix socket.

#### Secondary: OSC 9999 (Third-Party Agents)

Custom escape sequences for any AI tool to self-declare:
```
ESC ] 9999 ; agent:start ; name=X ; group=Y ; role=Z BEL
ESC ] 9999 ; agent:status ; progress=0.6 ; task=Building API BEL
ESC ] 9999 ; agent:stop ; exit=success BEL
```
Informational only — cannot grant elevated privileges.

#### MCP Server

teru exposes itself as an MCP server on `$XDG_RUNTIME_DIR/teru-<session>-<random>.sock` (0700 permissions + session token auth). Tools: create_pane, move_node, get_graph, read_output, send_input, list_workspaces, screenshot.

### Tiling Engine

Layouts (v1): master-stack, grid, monocle, floating.
Layouts (v2): timeline, custom Lua.

Workspace model:
- Numbered 1-9, named optionally
- Auto-created for agent groups (configurable)
- Swap layouts: auto-switch based on node count (1→monocle, 2→master-stack, 5+→grid)
- Scratchpads are floating nodes in a hidden workspace, toggled to overlay

Keybindings (configurable, xmonad-compatible defaults):
- Prefix key: Ctrl+Space (configurable, avoids WM conflicts)
- Navigation: prefix+j/k, prefix+1-9
- Management: prefix+Shift+j/k (swap), prefix+Space (cycle layout)
- Agent: prefix+a (overview), prefix+Shift+a (collapse finished)

### Session Persistence

Daemon mode: `teru detach` (prefix+d) serializes state, PTYs stay alive. `teru attach` reconnects GUI.

Scrollback tiers:
- Hot (visible + 2K lines): uncompressed in RAM
- Cold (everything else): LZ4 compressed on disk at `$XDG_STATE_HOME/teru/scrollback/`
- Global RAM cap: 512MB (configurable). Disk cap: 2GB per session.

Recovery:
- Normal detach/attach: sub-second, full state
- Reboot: layout + scrollback restored, processes marked "interrupted"
- Crash: WAL (binary, checksum-validated, 1s flush interval) ensures graph state recoverable

### GPU Rendering

Linux: OpenGL 4.3 (Ghostty-proven).
macOS: Metal (via Swift bridge).
Windows (v2): OpenGL via WGL.

Pipeline: font atlas (FreeType rasterization → texture), glyph cache (HarfBuzz shaping → positioned glyphs), grid render (dirty rectangles → draw calls). Frame rate: display refresh rate, skip hidden nodes.

Resume recovery: cache last frame as CPU bitmap, rebuild GPU resources on device loss.

### Configuration

`~/.config/teru/init.lua` — optional, zero-config works with compiled-in defaults.

Lua API: keybindings, themes, workspace definitions, spawn commands, event hooks, layout rules. Hot-reloadable on file save. Errors display in status bar, don't crash teru.

### Security

- MCP socket: `$XDG_RUNTIME_DIR`, 0700 permissions, session token in `$XDG_RUNTIME_DIR/teru-<session>.token`
- OSC 9999: informational only, cannot execute commands or read other nodes
- WASM plugins (v2): explicit capability grants, no terminal content access by default
- Agent hook handler: validates JSON schema, rejects malformed payloads

### Cross-Platform Strategy

| Component | Linux | macOS | Windows |
|-----------|-------|-------|---------|
| PTY | posix_openpt/forkpty | Same POSIX APIs | ConPTY (v2) |
| Window | GTK4 via C API | AppKit via Swift/C bridge | Win32 (v2) |
| GPU | OpenGL 4.3 | Metal | OpenGL via WGL (v2) |
| Process observer | eBPF (optional, /proc fallback) | proc_listchildpids | NtQueryInformationProcess (v2) |
| Daemon | fork+setsid | launchd service | Windows service (v2) |
| MCP socket | Unix domain socket | Unix domain socket | Named pipes (v2) |

### VT Compatibility

Target: xterm-256color with modern extensions.
- True color (24-bit SGR)
- Bracketed paste mode
- Focus events
- Synchronized output (BSU/ESU)
- Kitty keyboard protocol
- Kitty graphics protocol
- Custom `teru` terminfo entry (ships with binary, auto-installs)

### Text Rendering

- Rasterization: FreeType
- Shaping: HarfBuzz (ligatures, complex scripts)
- Discovery: fontconfig (Linux), CoreText (macOS)
- Fallback: configurable chain, Noto as default fallback
- Grapheme clusters: ICU-free implementation (UAX #29 subset)
- Double-width: CJK/emoji handled with 2-column cells
- BiDi: out of scope (same pragmatic choice as Ghostty)

## v1 Scope

In: PTY, process graph, VT parser, GPU rendering (Linux), tiling (4 layouts), session persistence, Lua config, Claude Code hook integration, MCP server, OSC 9999, terminfo, SIGWINCH, URL detection.

Out: WASM plugins, Windows, timeline layout, custom Lua layouts, BiDi, network-transparent sessions.

## Non-Goals

- Not a shell (teru runs any shell)
- Not a window manager (xmonad/i3 still manage non-terminal windows)
- Not Claude-specific (agent protocol works with any AI tool)
- Not a framework (libteru is embeddable but teru is the product)
