# teru — project notes for Claude Code

Two binaries, one source tree. `teru` is a terminal emulator + multiplexer;
`teruwm` is a wlroots Wayland compositor built on the same libteru library.
Written in Zig 0.16+. Links libc via `src/compat.zig`.

## Build

```sh
zig build                             # debug teru
zig build -Doptimize=ReleaseFast      # release teru   → zig-out/bin/teru
zig build -Dcompositor                # debug teruwm
zig build -Doptimize=ReleaseFast -Dcompositor   # release teruwm → zig-out/bin/teruwm
zig build test                        # 472+ inline tests (library-level)
zig build bench -- tools/bench-payloads   # throughput benchmarks
zig build run                         # run debug teru (windowed)
zig build run -- --raw                # run debug teru (TTY mode)
```

## Architecture

- `src/core/` — VtParser, Grid, Pane, Multiplexer, Selection, KeyHandler, Clipboard, ViMode
- `src/server/` — Session daemon (`daemon.zig`), wire protocol, cross-platform IPC (`ipc.zig`)
- `src/pty/` — `pty.zig` comptime dispatch, `PosixPty.zig`, `WinPty.zig` (ConPTY), `RemotePty.zig`
- `src/graph/` — `ProcessGraph` (DAG of processes/agents, MCP-queryable)
- `src/agent/` — OSC 9999 parser, HookHandler/Listener, `McpServer.zig` + `McpDispatch.zig` (19 tools, line-JSON), `McpBridge.zig` (stdio proxy), `in_band.zig` (in-band MCP over OSC 9999 + DCS), `PaneBackend.zig`
- `src/tiling/` — Layout engine + workspace state; 8 layouts (master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion)
- `src/persist/` — Session serialization, scrollback compression (keyframe + delta)
- `src/config/` — Config parser, `Keybinds.zig` (configurable), `ConfigWatcher.zig` (inotify/kqueue/poll), `themes.zig`
- `src/render/` — `software.zig` (SIMD renderer), `FontAtlas.zig` (stb_truetype), `BarRenderer.zig` (shared), `BarWidget.zig`, `PushWidget.zig`
- `src/platform/` — X11 (XCB) + Wayland (xdg-shell) + AppKit + Win32; keyboard translation per OS
- `src/compositor/` — **teruwm only.** `main.zig`, `Server.zig`, `Bar.zig`, `TerminalPane.zig`, `XdgView.zig`, `XwaylandView.zig`, `WmMcpServer.zig` (24 tools), `WmConfig.zig`, `Node.zig`, wlroots `wlr.zig` bindings, `miozu-wlr-glue.c`
- `src/compat.zig` — `monotonicNow`, `sleepNs`, `getPid`, `getUid`, `posixFork`, `forkExec`, `MemWriter/MemReader`
- `tools/bench.zig` — vtebench payload throughput harness (zig build bench)

Map: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## MCP

Two servers. 43 tools total.

- **teru agent** (`src/agent/McpServer.zig`) — 19 tools, socket `$XDG_RUNTIME_DIR/teru-mcp-$PID.sock`
- **teruwm compositor** (`src/compositor/WmMcpServer.zig`) — 24 tools, socket `$XDG_RUNTIME_DIR/teru-wmmcp-$PID.sock`

Reference: [docs/MCP-API.md](docs/MCP-API.md).

## Key rules

- Thread `io: std.Io` through every function that does file / network / timer I/O.
- Prefer `.claude/skills/zig16.md` and `.claude/rules/zig-terminal.md` over guessing at Zig 0.16 API shapes.
- Zero allocations in the render hot path. `renderDirty` uses `grid.dirty_row_min..=max` — don't break dirty tracking.
- VtParser is pure: no I/O, no allocation. CSI params capped at 16, OSC at 256 — overflow truncates.
- teruwm MCP calls always schedule a frame so state changes paint next vsync.
- No new dependencies without discussion — the binary size and zero-GPU property are load-bearing.

## Testing

```sh
zig build test                        # 472+ inline tests
python3 /tmp/teruwm-full-e2e.py       # E2E covering every MCP tool + Mod+drag (see /tmp for latest)
bash tools/run-bench.sh               # reproduce benchmarks from docs/BENCHMARKS.md
```

## Version

Current: **0.4.14** — see `build.zig` line 10 (`const version`).
Propagated via `build_options.version` to `main.zig`, `McpServer.zig`,
`WmMcpServer.zig`. Bump with `make bump-version V=x.y.z`.

The 0.4.x line is patches leading to the 0.5.0 milestone. v0.4.2..v0.4.12
were retroactively tagged against past feature waves; 0.4.13 (smart
borders + autostart) and 0.4.14 (MCP three-tier refactor) ship today's
work. Remaining 0.4.x → 0.5.0: 0.4.15 Foundation (per-output,
rotate_slaves, spawn chords, sink_all), 0.4.16 AI-Surface (xdg_activation
+ MCP events + DynamicProjects + named scratchpads), 0.4.17 Screen-Capture
(wlr-screencopy + area shot + fade + record). See `git tag` for the full
series.

## User-facing surface

- [README.md](README.md) — what teru and teruwm are; link tree
- [docs/INSTALLING.md](docs/INSTALLING.md) — per-platform install + teruwm TTY caveat
- [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md) — every default keybind for both binaries
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — teru.conf, teruwm/config, widgets, thresholds, rules
- [docs/MCP-API.md](docs/MCP-API.md) — all 43 tools with schemas + examples
- [docs/AI-INTEGRATION.md](docs/AI-INTEGRATION.md) — CustomPaneBackend, push widgets, OSC 9999, .tsess templates
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — module map, rendering pipeline, hot-restart, gap arithmetic
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — methodology + numbers, explicitly-not-measured items

When you change something user-facing, update the relevant doc in the
same PR. Stale docs are worse than no docs.
