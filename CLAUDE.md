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
- `src/compositor/` — **teruwm only.** `main.zig`, `Server.zig`, `Bar.zig`, `TerminalPane.zig`, `XdgView.zig`, `XwaylandView.zig`, `WmMcpServer.zig` (28 tools), `WmConfig.zig`, `Node.zig`, wlroots `wlr.zig` bindings, `miozu-wlr-glue.c`
- `src/compat.zig` — `monotonicNow`, `sleepNs`, `getPid`, `getUid`, `posixFork`, `forkExec`, `MemWriter/MemReader`
- `tools/bench.zig` — vtebench payload throughput harness (zig build bench)

Map: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## MCP

Two servers. 48 tools total.

- **teru agent** (`src/agent/McpServer.zig`) — 20 tools + event push channel, sockets `$XDG_RUNTIME_DIR/teru-mcp-$PID.sock` (requests) and `teru-mcp-events-$PID.sock` (events). Since v0.4.19 transparently forwards `teruwm_*` tools to the compositor socket.
- **teruwm compositor** (`src/compositor/WmMcpServer.zig`) — 28 tools + event push channel, sockets `$XDG_RUNTIME_DIR/teru-wmmcp-$PID.sock` (requests) and `teru-wmmcp-events-$PID.sock` (events)

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

Current: **0.5.0** — see `build.zig` line 10 (`const version`).
Propagated via `build_options.version` to `main.zig`, `McpServer.zig`,
`WmMcpServer.zig`. Bump with `make bump-version V=x.y.z`.

The v0.4.x line shipped as 0.4.2..0.4.26, hitting the 0.5.0 milestone
after the chromium/vivaldi fix pack (wp_viewporter + 5 related globals).
See `git tag` for the full series.

## Known crash patterns + invariants (post-v0.4.25 defensive set)

All six coredump-level bugs triaged during the v0.4.19..v0.4.25
hardening pass shared one root shape: **wlroots scene / seat
invariants violated by a stale or foreign surface**. Guards now in
place:

- **Surface liveness**: `vendor/miozu-wlr-glue.c::miozu_surface_is_live`
  checks `surface->resource && surface->mapped` before *any* seat
  notify or cursor-surface call. Scene buffers out-live surfaces
  briefly during unmap→destroy; this guard drops the window.
- **Request-set-cursor filter**: `miozu_set_cursor_event_from_focused`
  — compare `event->seat_client` to `seat->pointer_state.focused_client`
  and reject from anyone else. Matches sway/river. Without this a
  defocused chromium pushing set_cursor after a modifier event (e.g.
  Shift+Alt) left a scene-cursor node with `active_outputs &&
  !primary_output`, crashing the next motion update.
- **Grab-on-close**: every close path (`closeNode` / `closeFocused`
  for terminal + XDG, plus XdgView.handleUnmap + handleDestroy) must
  null `focused_terminal` + `focused_view` + `grab_node_id` BEFORE
  freeing the underlying pane/view. Otherwise `wlr_xdg_toplevel_send_close`
  or `wlr_cursor_set_*` dereferences a dead `wl_resource`.
- **Workspace.removeNode** clears `active_node` and `master_id` when
  they equal the removed id — otherwise `updateFocusedTerminal` looks
  up a heap-freed pane pointer next frame.
- **DCS parser isolation**: an `ESC` inside a DCS body routes through
  the dedicated `.dcs_st_esc` state, never the general `.escape` state.
  Before v0.4.22 an embedded `ESC[` inside a DCS payload leaked into
  the CSI parameter accumulator.

## User-facing surface

- [README.md](README.md) — what teru and teruwm are; link tree
- [docs/INSTALLING.md](docs/INSTALLING.md) — per-platform install + teruwm TTY caveat
- [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md) — every default keybind for both binaries
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — teru.conf, teruwm/config, widgets, thresholds, rules
- [docs/MCP-API.md](docs/MCP-API.md) — all 48 tools with schemas + examples
- [docs/AI-INTEGRATION.md](docs/AI-INTEGRATION.md) — CustomPaneBackend, push widgets, OSC 9999, .tsess templates
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — module map, rendering pipeline, hot-restart, gap arithmetic
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — methodology + numbers, explicitly-not-measured items

When you change something user-facing, update the relevant doc in the
same PR. Stale docs are worse than no docs.
