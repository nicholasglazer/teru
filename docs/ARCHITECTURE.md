# Architecture

Two binaries (`teru`, `teruwm`), one source tree, one library (`libteru`).
This doc is the map. For user-facing behavior see
[KEYBINDINGS.md](KEYBINDINGS.md) and [CONFIGURATION.md](CONFIGURATION.md);
for the JSON-RPC surface see [MCP-API.md](MCP-API.md).

```
┌────────────────────────┐        ┌─────────────────────────┐
│  teru  (terminal/mux)  │        │  teruwm  (compositor)   │
│  src/main.zig          │        │  src/compositor/main.zig│
│                        │        │                         │
│  - windowed / --raw    │        │  - wlroots root comp    │
│  - session daemon      │        │  - hosts teru panes     │
│  - MCP 19 tools        │        │    + XDG + XWayland     │
│                        │        │  - MCP 24 tools         │
└──────┬─────────────────┘        └──────┬──────────────────┘
       │                                  │
       │     both link libteru (src/lib.zig)
       │                                  │
       v                                  v
┌──────────────────────────────────────────────────────────┐
│ libteru (static library, Zig-only, no GPU, no libc-uses  │
│ that aren't in compat.zig)                               │
│                                                          │
│  core/      Grid · VtParser · Pane · Multiplexer · …     │
│  render/    SoftwareRenderer · FontAtlas · BarRenderer · │
│             PushWidget · BarWidget                       │
│  tiling/    LayoutEngine · 8 layout algorithms           │
│  agent/     McpServer · OSC 9999 · PaneBackend · hooks   │
│  graph/     ProcessGraph (DAG)                           │
│  persist/   Session · Scrollback compression             │
│  config/    Config · Keybinds · ConfigWatcher · themes   │
│  server/    daemon · IPC · wire protocol                 │
│  pty/       PosixPty · WinPty · RemotePty                │
│  platform/  X11 · Wayland · AppKit · Win32               │
└──────────────────────────────────────────────────────────┘
```

## libteru — the shared core

Pure Zig. No system libs beyond what `compat.zig` wraps (libc file I/O,
clock, fork+exec). Both binaries link this and add their own platform
integrations on top.

| Subsystem | What lives here | Notable constraints |
|---|---|---|
| `core/Grid.zig` | Character grid, cursor, scroll region, alt screen, dirty-row tracking | Cursor is always in bounds. All mutations bump `dirty_row_min/max` so the renderer only repaints what changed. |
| `core/VtParser.zig` | VT100/xterm state machine | Pure function over bytes → Grid mutations. Zero allocations. Zero I/O. CSI params capped at 16; OSC bounded — overflow truncates, never crashes. |
| `core/Pane.zig` | PTY + Grid + VtParser per pane | Backend-polymorphic (`.local` = real PTY; `.remote` = daemon-backed). |
| `core/Multiplexer.zig` | Multi-pane orchestrator for standalone `teru` | Owns pane list, active pane, workspaces, key dispatch. |
| `core/Selection.zig` · `ViMode.zig` · `Clipboard.zig` | Text selection, copy mode, xclip/wl-clipboard/pbcopy/Win32 CF_UNICODETEXT | Selection coords are absolute (scrollback-aware). |
| `render/software.zig` | `@Vector(4, u32)` SIMD alpha-blended renderer | Zero allocations in the hot path. `renderDirty` only touches rows inside `grid.dirty_row_min..=max`. |
| `render/FontAtlas.zig` | stb_truetype rasterization | 607 glyph slots cached at startup. No fontconfig. |
| `render/BarRenderer.zig` | Bar compositor shared by teru and teruwm | Widget dispatch, color thresholds, class → palette resolution. |
| `render/BarWidget.zig` · `PushWidget.zig` | Widget parsing and push-widget storage | Fixed-size arrays; no heap. |
| `tiling/` | Layout engine | 8 pure functions (rect-in → rects-out). Workspace state + layout cycling. |
| `agent/McpServer.zig` · `McpDispatch.zig` | 19-tool MCP server for teru | Line-delimited JSON-RPC over Unix socket (since v0.4.14). Dispatch table + schemas assembled at compile time. |
| `agent/McpBridge.zig` | `--mcp-server` stdio proxy | Line-JSON proxy between stdin/stdout and the Unix socket. |
| `agent/in_band.zig` | OSC 9999 in-band MCP | Agents inside a teru pane call tools over the PTY — zero socket, zero subprocess. |
| `agent/protocol.zig` | OSC 9999 parser | Parses `agent:start` / `status` / `stop` events + `query` (in-band MCP); updates ProcessGraph. |
| `agent/PaneBackend.zig` | Claude Code `CustomPaneBackend` protocol | 7-op JSON-RPC wire format. |
| `graph/ProcessGraph.zig` | DAG of processes/agents | Per-pane + per-agent nodes, lifecycle tracking, MCP-queryable. |
| `persist/Session.zig` | Binary (re)serialization of multiplexer state | Survives across daemon restarts. |
| `persist/Scrollback.zig` | Command-stream compression | Keyframe+delta; ~20–50× vs expanded cell buffers. |
| `config/` | Config parse, hot-reload, keybinds | inotify/kqueue/poll; `include` directive. |
| `server/` | Session daemon, wire protocol, cross-platform IPC | Unix sockets on POSIX, named pipes on Windows. Same framing. |
| `pty/` | `PosixPty` + `WinPty` (ConPTY) + `RemotePty` (daemon client) | `pty.zig` is comptime dispatch to the right backend. |
| `platform/` | Windowing/input for each OS | X11 (pure XCB), Wayland (xdg-shell, hand-declared), AppKit, Win32. |

## `teru` — the terminal / multiplexer

`src/main.zig` entry. Event loop owns the window, reads PTYs, drives
VtParser → Grid, then renders on demand. Four modes:

| Mode | Invocation | What it does |
|---|---|---|
| **windowed** | `teru` | Opens an X11 / Wayland / AppKit / Win32 window. |
| **raw TTY** | `teru --raw` | Uses the host TTY directly; no window. SSH/container use. |
| **named session** | `teru -n NAME` | Auto-starts or attaches to a headless daemon (`src/server/daemon.zig`). PTYs survive window close. |
| **stdio MCP proxy** | `teru --mcp-server` (alias `--mcp-bridge`) | Pipes stdin/stdout JSON-RPC to a running teru's socket; for embedding as an MCP subprocess (Claude Code, agent workflows). |

### Session daemon

A single daemon process per `-n NAME`. Owns all PTY master fds; clients
(windows) connect over a Unix socket (named pipe on Windows) and subscribe
to frame updates. Wire protocol: a 5-byte header per message, then
binary payload. Clients can disconnect and reconnect; PTYs keep running.

### MCP server (19 tools)

`src/agent/McpServer.zig`. See [MCP-API.md](MCP-API.md#teru-terminal-mcp--19-tools)
for the tool list. Socket path: `$XDG_RUNTIME_DIR/teru-mcp-$PID.sock`.

## `teruwm` — the Wayland compositor

`src/compositor/main.zig`. Wraps [wlroots 0.18](https://gitlab.freedesktop.org/wlroots/wlroots).
Not a terminal — it's a display server. You launch it from a TTY and it
owns the keyboard, cursor, and display. Hosts native terminal panes
(libteru `Pane`s rendered into scene buffers) and arbitrary
Wayland/XWayland clients side by side.

```
         TTY / libinput / DRM
                │
                v
    ┌───────────────────────┐
    │   wlroots backend     │
    │   scene graph         │
    └───────┬───────────────┘
            │
            v
┌────────────────────────────────────────────────────────────┐
│  Server                src/compositor/Server.zig           │
│                                                            │
│  ├─ Bar (top + bottom)    compositor/Bar.zig               │
│  ├─ NodeRegistry[256]     compositor/Node.zig              │
│  ├─ TerminalPane[]        compositor/TerminalPane.zig      │
│  │   (libteru Pane in a wlr_scene_buffer)                  │
│  ├─ XdgView / XwaylandView  (wlroots client surfaces)      │
│  ├─ LayoutEngine          (libteru/tiling)                 │
│  ├─ push_widgets[32]      (libteru/render/PushWidget)      │
│  ├─ active_keymap_name                                     │
│  └─ WmMcpServer           compositor/WmMcpServer.zig       │
└────────────────────────────────────────────────────────────┘
```

### XDG and XWayland

`XdgView` creates a `wlr_scene_xdg_surface` and listens for `map` /
`unmap` / `destroy` / `commit`. On the client's first commit we send
`wlr_xdg_toplevel_set_size(0, 0)` to satisfy the protocol's initial-
configure requirement — without this, Chromium/Electron/foot time out
and destroy the surface (was a real bug, fixed in commit 03f8c7e).

XWayland is lazy: `wlr_xwayland_create(display, compositor, true)` reserves
a display socket at startup, spawns the Xwayland process on first
connection. We export `DISPLAY=:N` into the compositor env so child
processes find it.

### Rendering pipeline

```
PTY byte → ptyReadable() → readAndProcess() → grid.dirty = true
                                                (coalesced)
vsync → handleFrame() → renderIfDirty() → SoftwareRenderer.renderDirty()
                     → wlr_scene_buffer_set_buffer_with_damage()
```

Rendering only happens in the frame callback. PTY reads mark the grid
dirty and are coalesced — 100 reads between two vblanks produce one
paint. This is how the compositor keeps event-loop lag below libinput's
threshold even during `yes > /dev/null`.

The terminal pane framebuffer is sized to the **full allocated rect**,
not the integer cell grid, so leftover pixels (less than one cell) fall
outside the grid loop but are bg-filled by `renderRange`. Consequence:
inter-pane gaps are always exactly `wm_config.gap` — no visual
asymmetry from rounding.

### Hot restart

`teruwm_restart` MCP tool → sets `restart_pending = true` → next frame
callback calls `execRestart()`:

1. Serialize to `/tmp/teruwm-restart.bin`: pane count, active workspace,
   per-workspace layouts, per-pane `{workspace, pty_fd, rows, cols, pid}`.
2. Clear `FD_CLOEXEC` on every PTY master so the fds survive `exec()`.
3. `execveat(/proc/self/exe, ["teruwm", "--restore"])`.

New binary's `restoreSession()` reads the file and reconstructs the
`TerminalPane`s via `Pane.attach(fd)`. Shells never notice — their
stdin/stdout are unchanged.

Intentionally NOT persisted through restart:
- Push widgets (daemons re-register on reconnect)
- Scene graph positions (recomputed by `arrangeworkspace`)
- Focus (resets to first terminal)

### Gap arithmetic

Every gap in the compositor is one value, `wm_config.gap` (default 4).
`arrangeworkspace` pre-insets the screen rect by `gap/2`, passes it to
the layout engine, then post-insets each returned rect by `gap/2` again.
Result:

```
edge gap    = pre-inset hg + post-inset hg = gap
between gap = post-inset hg + post-inset hg = gap
bar gap     = pre-inset hg + post-inset hg = gap
```

All identical. See `src/compositor/Server.zig:arrangeworkspace`.

### Mod+drag → floating

`Super+LeftClick` on a tiled pane: `Server.processCursorButton`
detects the modifier, calls `nodeAtPoint(cx, cy)` to find the pane
under the cursor, detaches it from the layout engine, marks
`nodes.floating[slot] = true`, gives it a cursor-anchored rect, then
sets `cursor_mode = .move` and stores the grab offset. Subsequent
motion events translate the pane. Release returns to `.normal`.

The E2E test synthesizes this via `teruwm_test_drag` — the same code
path a real mouse click takes.

### Bar widgets

`BarRenderer` + `BarWidget` are in libteru. The compositor's
`Server.push_widgets[32]` array holds external-daemon-pushed entries
referenced via `{widget:name}` tokens. `BarData.push_widgets` points
into it on every render. Class-based coloring (`warning`, `critical`,
`success`, etc.) resolves to palette indices via `classColor`.

Threshold-based color ramps for numeric widgets (`{cpu}`, `{mem}`,
`{battery}`, `{watts}`, `{cputemp}`, `{perf}`) use `rampColor(value,
warning, critical, inverted)`. Thresholds come from
`~/.config/teruwm/config [bar.thresholds]`.

### MCP server (24 tools)

`src/compositor/WmMcpServer.zig`. Socket
`$XDG_RUNTIME_DIR/teru-wmmcp-$PID.sock`. Protocol mirrors
`teru-mcp-*.sock`. See [MCP-API.md](MCP-API.md#teruwm-compositor-mcp--24-tools).

### E2E test surface

Two MCP tools exist solely to let test scripts script the compositor
without synthesizing keyboard/mouse events at the wayland-protocol
level:

- `teruwm_test_drag` → `Server.processCursorButton(super=true)`
- `teruwm_test_key` → `Server.executeAction(action)`

Both dispatch into the same code paths a real input event takes.

## Data flow — unified view

```
Input          : X/Wayland/AppKit/Win32/libinput → main/Server → Keybinds → PTY write
Output         : PTY read → VtParser → Grid → SoftwareRenderer → framebuffer → display
Agents         : OSC 9999 → VtParser → ProcessGraph
                 Hook events → HookListener → ProcessGraph
                 Claude Code `spawn`/`status` → PaneBackend → Multiplexer
MCP (terminal) : Client → McpServer → Multiplexer/ProcessGraph/Pane
MCP (compos.)  : Client → WmMcpServer → Server (windows, workspaces, bars, widgets)
Push widgets   : External daemon → WmMcpServer.teruwm_set_widget → Server.push_widgets
                                                                   → Bar renders on next vsync
```

## Invariants the code enforces

Mechanically, via tests and assertions:

- **Grid**: cursor always `0 ≤ row < rows`, `0 ≤ col < cols`. Every mutator clamps before returning.
- **Render hot path**: zero allocations. `renderDirty` only touches `dirty_row_min..=max` + the cursor rows.
- **VtParser**: pure computation. No I/O, no allocation. CSI params capped at 16; OSC bounded at 256 — overflow silently truncates, never panics.
- **MCP protocol**: max request 64 KiB, max response 64 KiB, one request per connection (`Connection: close`). No session, no auth beyond socket fs perms.
- **Widget storage**: fixed-size arrays (`PushWidget.max_widgets = 32`, 128-byte text). No heap.
- **Color**: every pixel comes from `ColorScheme` or an ANSI palette entry. Theme swaps take effect on next render.
- **I/O threading**: any function that does file/network/timer I/O takes `io: std.Io`. Threaded top-down from `main(init)`.

## Binary size, at a glance

Run `make size` for current numbers, or see [BENCHMARKS.md](BENCHMARKS.md).

| Build | teru | teruwm |
|---|---:|---:|
| ReleaseFast (default) | 6.6 MB | 5.6 MB |
| ReleaseSmall | ~4 MB | — |
| Debug | 22 MB | 37 MB |

## Dependencies

**Runtime** (system libs, dynamically linked):
- Linux: `libxcb`, `libxkbcommon`, `libwayland-client`. teruwm adds `libwlroots-0.18`, `libwayland-server`.
- macOS: AppKit, CoreGraphics, Carbon (frameworks).
- Windows: user32, gdi32, kernel32, shell32, imm32.

**Runtime** (exec'd as subprocess):
- `xclip` / `wl-clipboard` on Linux; `pbcopy`/`pbpaste` on macOS; Win32 API on Windows.
- `xdg-open` / `open` / `ShellExecuteW` for URL handling.

**Vendored** (static-linked):
- `stb_truetype.h` — font rasterization (195 KB single-header, public domain).
- `xdg-shell-protocol.c` — Wayland shell protocol (generated, 6 KB).
- `miozu-wlr-glue.c` — teruwm's C accessors for wlroots struct fields.

**No** FreeType. **No** fontconfig. **No** OpenGL. **No** EGL. **No** GTK.

Build flags to drop deps:
- `-Dx11=false` — Wayland-only teru (no libxcb).
- `-Dwayland=false` — X11-only teru (no libwayland).
- teruwm is Linux + wlroots only.
