# Changelog

## Unreleased

### Breaking

- **Socket rename** — `teru-wmmcp-$PID.sock` is now `teruwm-mcp-$PID.sock`
  (and the events channel `teru-wmmcp-events-` → `teruwm-mcp-events-`).
  The `teruwm-` prefix matches the binary name; the family namespace
  stays glob-addressable. Env vars renamed to match:
  `TERU_WMMCP_SOCKET` → `TERUWM_MCP_SOCKET`,
  `TERU_WMMCP_EVENTS_SOCKET` → `TERUWM_MCP_EVENTS_SOCKET`.
  No compat fallback — update any scripts / `.mcp.json` entries that
  reference the old paths. teru terminal's `teru-mcp-*` sockets are
  unchanged.

### Features

- **`teru --mcp-server --target teruwm`** — the existing MCP stdio
  bridge now routes to the compositor when invoked with
  `--target teruwm` (default stays `teru`). `--mcp-stdio` alias added
  alongside `--mcp-server` / `--mcp-bridge`. Fronts teruwm's HTTP
  MCP socket via the existing `agent/forward.zig` client. Register
  with Claude Code / Cursor:
  ```json
  {"mcpServers": {"teruwm": {
    "command": "teru",
    "args": ["--mcp-server", "--target", "teruwm"]
  }}}
  ```
  No new binary; `teruwmctl` was scoped down to a `--target` flag on
  the existing bridge (see `docs/.internal/teruwmctl-plan.md`).
- **`ipc.buildPathFamily(family, prefix, name)`** — new helper so
  binaries can own their own socket family (`teruwm-*` vs `teru-*`)
  instead of sharing the single hardcoded `teru-` prefix.

## 0.6.3 (2026-04-18)

Patch release — windowed-mode power draw + Wayland-client crash + drag-select efficiency.

### Fixes

- **windowed mode** — event-driven main loop. windowed.zig used to
  sleep on a fixed 8/16 ms timer, waking the CPU ~60 Hz even with
  nothing to do. New `waitForInput` uses `posix.poll()` on the
  Wayland/X11 display fd, every PTY master, the daemon/hook-listener/
  config-watcher fds, with a timeout equal to the nearest scheduled
  deadline (cursor-blink flip, 60 fps frame cap, persist debounce,
  500 ms hard cap). Measured: teru idle CPU 0.144% → 0.022% (−85%),
  system power 20.765 W → 20.699 W (−66 mW) across 3 × 30 s trials.
- **windowed mode** — cursor blink is now focus-gated. When the
  window isn't focused, blink doesn't fire at all (no wakeups every
  530 ms for a caret the user isn't watching). When focused, blink
  marks only the cursor row dirty via `markRowDirty` instead of
  setting `grid.dirty = true`, which used to force a full SIMD
  repaint of the entire framebuffer (~16 MB at 2560×1600) every
  530 ms. One-row per blink now.
- **platform/wayland** — WaylandWindow.init allocated `state` on the
  stack and passed `&state` as the listener data pointer to every
  `wl_*_add_listener` call. The state was copied-by-value into
  WaylandWindow on return; the listeners kept pointing at the
  since-freed stack slot and panicked with an index-out-of-bounds
  inside `pushEvent` the first time any Wayland event dispatched.
  Heap-allocate via `std.heap.c_allocator` so the pointer stays stable.
  Visible effect: teru now launches successfully as an xdg_toplevel
  against an outer Wayland compositor.
- **compositor** — narrow drag-select invalidation. Previously every
  pointer motion during a drag called `grid.markAllDirty()`, so each
  motion tick re-rendered every cell. Measured 4.46% teruwm CPU +
  300 mW system power during sustained drag. Motion now marks only
  the union of {previous-end, new-end, start} screen rows dirty —
  exactly the cells whose selection-bg state can flip between ticks.
  Typical drag spans 1-5 rows per tick; on an 80×50 grid that's ~50×
  less work per motion.

## 0.6.2 (2026-04-18)

Patch release — teruwm-native terminal panes now support mouse text
selection, and hover no longer flickers near the cursor. The previously
published 0.6.2 shipped an unrelated Wayland-client queue fix that
didn't address either user-reported symptom — that tag has been replaced
with this commit.

### Fixes

- **teruwm** — text selection inside native terminal panes now works.
  Panes created by `teruwm_spawn_terminal` are `wlr_scene_buffer` nodes
  backed by libteru with no wl_surface, so `wlr_seat_pointer_notify_*`
  had nowhere to deliver pointer events. New teruwm-internal path feeds
  cursor coords into the pane's own `Selection` / `MouseState` and the
  `SoftwareRenderer` now applies a `selection_bg` overlay per-cell.
- **teruwm** — hover no longer flickers near the mouse cursor. Cache
  the last xcursor image name server-side; skip `wlr_cursor_set_xcursor`
  when the shape matches what's already set. Without this, hovering
  over a surface-less terminal scene_buffer re-set the cursor on every
  motion packet, which re-damaged the cursor plane at mouse rate and
  visibly rippled the pixels under the cursor.
- **teruwm_type / teruwm_press** (MCP) now route to the focused
  terminal pane's PTY via `tp.writeInput`, mirroring the real-keyboard
  special-case in `ServerInput.handleKeyEvent`. Previously these tools
  called `wlr_seat_keyboard_notify_key` which has no destination for
  native panes, so MCP-driven testing of terminal keyboard was a no-op.
  xdg / xwayland fallback path preserved.

### Internals

- `SoftwareRenderer` gains `renderWithSelection` + `renderDirtyWithSelection`;
  `renderRange` is now a thin wrapper over `renderRangeSel` that
  threads an optional `Selection` + scroll/sb params.
- `TerminalPane` carries `selection: Selection` and `mouse: MouseState`;
  `Server` tracks `drag_terminal: ?*TerminalPane` so drags that leave
  the pane rect still pin the far end at the cursor.
- `.claude/rules/compositor-mcp-testing.md` — new playbook for
  driving teruwm from MCP and verifying changes via pane screenshots.
  Codifies: MCP routing quirks, DRM contention handling, what
  screenshots can and cannot capture.

## 0.6.1 (2026-04-17)

Patch release — one bug.

### Fixes

- **teruwm**: TerminalPane honours DEC private mode 2026 (synchronized
  output). Regressed during the Server.zig module split that shipped in
  0.6.0's refactor batch — apps that batch their paints between
  `ESC[?2026h` / `ESC[?2026l` (Claude Code, Ink, fzf, ratatui) no
  longer flicker as the compositor painted every intermediate write.
  Adds a 150 ms fall-through timeout so a buggy client that never
  closes the batch can't freeze the pane (matches Alacritty).

## 0.6.0 (2026-04-17)

The protocol-completion milestone. 80+ commits since v0.5.0 land a fully
functional desktop-grade compositor experience: every protocol Chromium,
Vivaldi, Emacs, GIMP, and figma-linux need is now implemented, all
live-hardware crash clusters from the v0.5.0 era are resolved, and the MCP
surface gains physical-input primitives for AI-driven GUI automation.

### Features — teruwm compositor protocols

- **foreign_toplevel_management_v1** — waybar taskbar MVP; toplevels published and closeable from external clients.
- **wlr_output_management_v1** — full kanshi, wlr-randr, and wdisplays support.
- **virtual_keyboard_v1 + virtual_pointer_v1** — synthetic keyboard and pointer input.
- **output_power_management_v1** — DPMS on/off/standby via wlopm and swayidle.
- **cursor_shape_v1** — correct pointer/text/grab/resize cursors over browsers and Electron apps.
- **presentation-time frame callbacks** — fixes Chromium/Vivaldi "stuck on splash screen".
- **wp_viewporter + 5 chromium/vivaldi protocols (pack #1 + #2)** — completes the set required for GPU-composited clients to render correctly.
- **data_control_v1 clipboard, tearing protocol, idle_inhibit (pack #2)**.
- **zxdg_output_manager_v1** — enables grim and wlr-screencopy to work correctly.
- **[keyboard] config section + 3 protocol globals** — tap-to-click, natural-scroll, disable-while-typing, clickfinger defaults applied per libinput device.

### Features — teruwm UX

- **Scene-rect borders on all windows** — xdg + xwayland (not just teru terminals); `border_color_focused`, `border_color_unfocused`, `border_width` config knobs; `border_width = 0` disables; ARGB alpha supported for translucent borders.
- **Key repeat for held keybinds** — resize, focus/swap cycle, master count, zoom; 40 ms rate / 400 ms delay (sway-style).
- **Touchpad defaults** — tap-to-click, drag, natural-scroll, disable-while-typing, clickfinger applied automatically per libinput device.
- **Floating window focus** — `Mod+J/K` now cycles through floating windows in addition to tiled ones.
- **Shifted digit keybinds** — `Mod+Shift+1..0` works on number-row shifted symbols (`!@#$%^&*()`); un-shifted back to digit before keybind lookup.
- **Emacs/Steam/X11 close** — `Mod+Shift+C` now closes any X11 client via `wlr_xwayland_surface_close`.
- **Float/tile semantics clarified** — `Mod+S` is unfloat-only; tile→float is `Mod+drag` (xmonad/bspwm semantics).
- **Menu keybind** — moved from `Mod+D` to `Mod+M`.
- **Launcher repaint fix** — Esc-from-launcher now correctly repaints the bar (forced dirty flag past signature dedupe).
- **Close-last-terminal** — no longer leaves a ghost image on the output.

### Features — AI-first MCP

- **Unified McpFramework** — comptime-generic over `Impl` type; single codebase shared by teru agent server and teruwm compositor server.
- **teruwm_mouse_path** — humanised cursor trajectory tool for browser/GUI automation.
- **teruwm_click / teruwm_type / teruwm_press / teruwm_scroll** — physical input primitives for AI-driven GUI control.

### Bug fixes

- **Chromium/Vivaldi clicks land** — input-region filter + distinct button timestamps prevent duplicate events.
- **Vivaldi loading splash** — `wlr_scene_output_send_frame_done` call added; no more freeze on splash.
- **Emacs/Steam/GIMP XWayland keyboard focus** — `wlr_seat_keyboard_notify_enter` on the xwayland `wlr_surface` (not the parent).
- **Emacs maps at correct size** — `Node.applyRect` dispatches to `wlr_xwayland_surface_configure` for xwayland slots; no more 1×1 square.
- **4 shutdown crashes** — defer order, `wl_display_destroy_clients` before `wl_display_destroy`, `shutting_down` guard in `Output.handleDestroy`, gentler scene-buffer teardown.
- **figma-linux + Electron clicks** — fallback pointer to toplevel root when every subsurface rejects the input region.
- **Scroll offset wrap** — `u32→i32` cast guarded against silent overflow.
- **8 silent `catch {}` sites** — now log real failures instead of swallowing them.
- **XdgView handleDestroy** — no longer pre-removes FTL links before the toplevel is fully torn down.
- **Server.deinit** — properly unregisters all listeners and frees collections.
- **execRestart** — buffer sizing corrected; `FD_CLOEXEC` restored on exec failure.
- **scheduleRender** — iterates all outputs, not just primary.

### Refactors (non-breaking)

- **Server.zig split** — decomposed into 8 focused modules: `ServerListeners`, `ServerInput`, `ServerCursor`, `ServerFocus`, `ServerLayout`, `ServerScratchpad`, `ServerRestart`, `ServerScreenshot`.
- **main.zig split** — decomposed into `modes/` subdirectory: `common`, `raw`, `tui`, `windowed`, `daemon`.
- **McpFramework** — comptime-generic unification; one codebase, two server instantiations.
- **FontSynth** — box-drawing synthesis extracted from `FontAtlas`.
- **Retire `miozu_output_layout_first_*`** — replaced by `activeOutputDims`.
- **stbtt externs** — hand-declared; `@cImport` dropped.

### Performance

- **O(1) `Node.findById` + `terminalPaneById`** — `AutoHashMap` indices replace linear scans.
- **Bar render dedupe** — signature-based short-circuit skips SIMD blit on unchanged frames.
- **FBA arrange scratch** — zero heap allocation per vsync in layout engine.
- **pixman damage regions** — scene buffer commits carry precise damage, reducing GPU blit cost.
- **`barSignature`** — reads `urgent_count` and push counter in O(1).
- **Border-only focus repaint** — saves N×300 µs per focus flip by repainting only border rects.

No breaking config changes. No breaking MCP API changes. All additions are purely additive — upgrade is drop-in.

## 0.5.0 (2026-04-13)

The xmonad-parity milestone. 25 patches since 0.4.1 landed a tiling Wayland
compositor (`teruwm`), a 48-tool two-server MCP surface, multi-output support,
session save/restore, and a defensive crash-hardening pass driven by live
chromium/tty testing.

### Features — teruwm (wlroots Wayland compositor)
- **xmonad master workflow** — `$mod+M` focus-master, `$mod+Shift+M` swap-master, `$mod+,/.` adjust master count, `$mod+Ctrl+J/K` rotate slaves.
- **Named scratchpads** — xmonad `NamedScratchpad` model with `HIDDEN_WS` sentinel; toggles park/unpark a tagged pane on any workspace.
- **DynamicProjects** — per-workspace startup hooks via `[workspace.N]` config.
- **Multi-output (3-rule architecture)** — Node.workspace is identity, Output.workspace is a viewport, visibility derives. `$mod+O` cycle output, `$mod+Shift+O` move across outputs.
- **Float toggle + sink all** — `$mod+S` toggles floating; `$mod+Ctrl+S` sinks every floater back into tiling.
- **Zoom / fullscreen** — `$mod+Z` monocle on focused pane, `$mod+F` true fullscreen (bars hidden).
- **Session save/restore** — `.tsess` snapshots; hot-restart preserves PTY fds across `exec`.
- **Screen capture** — `wlr-screencopy` native compositor screenshots, area select, fade-unfocused, record presets.
- **Smart borders** — drawn only when there are peers; sole pane renders borderless.
- **`[autostart]` section** — compositor launches user programs on ready.
- **xdg_activation_v1 urgency** — hidden clients flash an urgency pill in the bar.
- **XWayland lazy-start** — spawned on first X11 client connect; absent at runtime without penalty.
- **Spawn chords** — 32 user-defined `spawn_0..31` keybind slots.
- **Default close chord: `$mod+Shift+C`** — matches xmonad `mod-shift-c`; `$mod+X` is no longer bound.

### Features — MCP surface
- **Two-server architecture** — 20-tool agent MCP (`teru-mcp-*.sock`) + 28-tool compositor MCP (`teru-wmmcp-*.sock`); 48 tools total.
- **Cross-server forwarding** — `teruwm_*` calls on the agent socket transparently forward to the compositor socket.
- **Event push channel** — `teru-*mcp-events-*.sock` with `subscribe_events` tool, JSON-line stream (`window_mapped`, `focus_changed`, `workspace_switched`, `urgent`, `window_closed`).
- **In-band MCP** — OSC 9999 query + DCS 9999 reply lets headless agents drive teru without a socket.
- **Line-JSON dispatch** — comptime tool table, no per-call allocation.

### Features — teru (terminal)
- **DECLRMM left/right scroll margins** — IL/DL/ICH/DCH margin-aware.
- **Native PNG screenshots**, Braille + geometric glyphs (352 new), DECTCEM cursor visibility.

### Fixes — defensive crash-hardening (v0.4.19..v0.4.27)
Six coredump-grade bugs triaged during live chromium/tty testing; all shared one root shape — wlroots scene/seat invariants violated by a stale or foreign surface.
- **Surface liveness guard** — `miozu_surface_is_live` checks `resource && mapped` before any seat-notify or cursor-surface call.
- **Cursor-request filter** — `request_set_cursor` rejected from any client other than the focused pointer client (matches sway/river).
- **Scene node type check** — `wlr_scene_node_at` returns rect/tree/buffer; pre-filter buffer nodes before `wlr_scene_buffer_from_node`.
- **Grab-on-close invariant** — every close path nulls `focused_terminal`, `focused_view`, and `grab_node_id` before freeing the backing pane/view.
- **Workspace.removeNode** clears `active_node` and `master_id` when they equal the removed id.
- **DCS parser isolation** — `ESC` inside a DCS body routes through a dedicated sub-state, never the general `.escape` state.
- **XDG click-to-focus** — sets `server.focused_view` via `focusView()`; prior to this, `$mod+Shift+C` / `$mod+S` on a Wayland client no-op'd or targeted the wrong window.
- **XDG view unmap/destroy UAF** — clears focused_view and grab state before surface destruction.

### Build / CI
- Version single source of truth: `build.zig` line 10; propagated via `build_options.version`.
- 488 inline tests.

### Documentation
- Full rewrite of `docs/ARCHITECTURE.md`, `docs/MCP-API.md` (48 tools), `docs/KEYBINDINGS.md`, `docs/INSTALLING.md`, `docs/BENCHMARKS.md`.
- `CLAUDE.md` crash catalogue with symptom → trigger → root cause → fix mapping.

## 0.4.1 (2026-04-10)

### Features
- **DECLRMM left/right scroll margins** — full DECSLRM support: IL/DL/ICH/DCH respect margins, cursor constraining, wrap/newline/erase margin-aware. Fixes tmux vertical split rendering.
- **Homebrew tap** — `brew install nicholasglazer/teru/teru` for macOS distribution.
- **Scoop manifest** — `scoop install teru` for Windows distribution.
- **New shortcuts** — `Alt+B` toggle status bar, `Alt+Enter` new pane, `Alt+\` zoom reset.
- **`-e` exec flag** — `teru -e htop` runs a command instead of shell.
- **`--no-bar` flag** — start with status bar hidden.
- **Nesting detection** — refuses to open a teru window inside an existing teru session.

### Fixes
- Mouse selection off by one row (padding not subtracted from coordinates).
- Selection no longer blinks or disappears during/after drag.
- Windows IME properly disabled — fixes CJK character input.
- Windows keyboard layout change handling.
- LF no longer resets cursor column — fixes tmux vertical splits.
- DECLRMM margin compliance: eraseChars unbounded, DECSLRM homes cursor, CR respects left margin, alt screen clears margins, wrap/newline margin-aware.
- Mouse cursor properly restored on click and motion (3 fixes).
- Wayland cursor hide/show safety — no-op without cursor surface.
- `Alt+D` no longer kills local mode — shows notification instead.

### Documentation
- Added `mouse_hide_when_typing`, `word_delimiters`, `bar_left`/`bar_center`/`bar_right` to CONFIGURATION.md.
- Fixed workspace range 0-8 → 0-9 in AI-INTEGRATION.md.
- Added `input/` module to architecture docs.
- Removed stale macOS Intel binary from install docs (CI only builds aarch64).

## 0.4.0 (2026-04-10)

### Architecture
- **Daemon-backed windowed mode** — `teru -n NAME` auto-starts a background daemon, connects full windowed UI. Close window → daemon survives. Reopen → reconnects with same panes + content. Cross-platform IPC (Unix sockets / named pipes).
- **Pane backend abstraction** — `RemotePty` enables panes backed by daemon IPC instead of local PTYs. Unified accessors: `pane.ptyWrite()`, `pane.ptyRead()`, `pane.childPid()`.
- **State sync protocol** — daemon sends full workspace/pane state on client connect: layout, master ratio, zoom, active pane, pane positions. Under 50ms reconnect.

### Features
- **Template system** — `teru -n prod -t claude-power` starts from `.tsess` template. Templates define workspaces, layouts, panes, commands, CWDs. Searched in `~/.config/teru/templates/`.
- **Clean CLI** — `teru` (fresh scratchpad), `teru -n NAME` (persistent), `teru -l` (list), `-t`/`-f`/`-v`/`-h` short flags.
- **10 workspaces** — Alt+0 = workspace 10. Matches tmux `M-0 → window 10`.
- **Clickable status bar** — click workspace indicators to switch.
- **Native PNG screenshots** — `teru_screenshot` MCP tool, pure Zig encoder, zero deps.
- **Copy/paste keybind actions** — `copy:selection` and `paste:clipboard` wired to config.
- **`restore_layout` / `persist_session` split** — lightweight layout restore vs full daemon persistence.
- **MCP bridge auto-discovery** — scans for teru socket when `$TERU_MCP_SOCKET` not set.
- **MCP read-only mode** — `TERU_MCP_READONLY=1` filters write tools.
- **Braille + geometric glyphs** — 352 new glyphs (⠋⠙⠹⠸ spinners, ◇◆●○ task lists).
- **DECTCEM cursor visibility** — cursor hidden when apps use ESC[?25l (fixes spinner artifacts).
- **Example session** — `examples/claude-power.tsess` (10 workspaces, 34 panes, production tmux replacement).
- **Systemd service** — `pkg/teru.service` for daemon auto-start on login.

### Security
- **JSON injection fixed** — MCP tool responses escape all user-controlled strings.
- **Protocol bounds checks** — payload overflow, workspace index validation, grid bounds.
- **Path safety** — macOS uses `$TMPDIR`, Linux uses `$XDG_RUNTIME_DIR`.
- **Scrollback OOM cap** — `scrollback_lines` capped at 1M.

### Refactoring
- Mouse handling extracted to `src/input/mouse.zig` (−370 lines from main.zig).
- MCP helpers extracted to `src/agent/McpTools.zig` (−157 lines from McpServer).
- XKB keysym constants extracted to `src/input/keysyms.zig`.
- Layout parsing deduplicated into `Layout.parse`/`Layout.name`.
- Named constants replace 11 magic numbers.
- Global `g_wm_class` replaced with parameter threading.
- Silent `catch {}` blocks annotated, session save logged.
- `auto_start=false` fixed — spawns shell, types command without Enter.
- Selection cleared when PTY output changes grid content.
- Consistent `grid_rows` calculation across init, resize, and render.
- Protocol fuzz tests (8) + braille/geometric tests (16).

### Stats
- 526 inline tests (up from 451)
- 19 MCP tools
- 60 source files, 32K lines
- Cross-platform: Linux (X11+Wayland), macOS, Windows

## 0.3.10 (2026-04-10)

### Features
- **Clean CLI** — simplified interface: `teru` starts a fresh scratchpad, `teru -n NAME` creates/attaches a persistent named session (daemon auto-started), `teru -n NAME -t TEMPLATE` starts from a .tsess template, `teru -l` lists sessions.
- **Template system** — `.tsess` files define multi-workspace sessions (workspaces, layouts, panes, commands, CWDs). Searched in `~/.config/teru/templates/` then `./examples/`. Export current session via `teru_session_save` MCP tool.
- **Pane backend abstraction** — `RemotePty` in `src/pty/` enables daemon-backed windowed mode where panes connect to a running daemon instead of owning PTYs directly.
- **Full state sync** — workspace position, focus, master ratio, and zoom state preserved across daemon attach/detach cycles.
- **`restore_layout` config option** — save layout on exit, restore on launch (fresh shells, no daemon). Separate from `persist_session` which keeps processes alive.
- **`persist_session` config option** — keep processes alive between window closes via auto-daemon.

### Fixes
- **JSON injection in MCP tools** — all MCP tool responses properly escape user-controlled strings.
- **Scrollback OOM protection** — bounded scrollback allocation prevents runaway memory growth.
- **Audit critical fixes** — bounds checks on CSI params, path traversal protection in session names, input validation on MCP tool arguments.
- **State sync active_pane_id** — uses full u64, matches `?u64` Workspace.active_node type.
- **pane.pty to pane.backend** — fixed missed migration in `spawnPaneWithCommand` + platform dispatch.
- **Stale selection cleared** — selection highlight no longer persists when PTY output changes grid content.

### Refactoring
- Deduplicated layout parsing into `Layout.parse`/`Layout.name` (types.zig).
- Extracted hardcoded magic numbers into named constants.
- Annotated safe `catch {}` blocks, log session save failures instead of silently dropping.

### Testing
- 8 protocol robustness fuzz tests for malformed wire messages.
- 499+ inline tests (up from 480).

## 0.3.9 (2026-04-09)

### Features
- **10 workspaces** — Alt+0 switches to workspace 10 (was zoom_reset). Matches tmux `M-0 → window 10` pattern. All arrays expanded from [9] to [10] across LayoutEngine, Config, Session, Keybinds, platform keycodes (Linux/macOS/Windows).
- **Example session: `claude-power.tsess`** — 10-workspace 34-pane session config replicating a production tmux setup with Claude Code instances, monitoring scripts, and dev servers.

### Fixes
- **Selection drift** — mouse selection highlight no longer drifts upward when new terminal output pushes lines to scrollback. Selection rows now track scrollback growth.
- **macOS TIOCSWINSZ/TIOCSCTTY** — ioctl constants missing from Zig's std.posix.T added to compat.zig with correct c_int type for libc ioctl signature.
- **macOS objc_msgSend_stret** — does not exist on arm64; use regular objc_msgSend on Apple Silicon.
- **macOS builtin import** — missing in platform.zig, broke Windows cross-compile.
- **IPC buildPath test** — works on macOS (path format differs per OS).

## 0.3.8 (2026-04-09)

### Features
- **Event-driven session persistence** — `persist_session = true` auto-saves session state on every meaningful change (pane spawn/close, layout cycle, workspace switch, focus, resize, zoom, swap, move). No polling — dirty flag with 100ms debounce.
- **Workspace-aware restore** — on startup, restores pane count per workspace with correct layouts and master ratios (session format v2, backwards-compatible with v1).
- **Auto-attach to daemon** — if a daemon session named "default" is running, teru auto-attaches instead of starting fresh.
- **`ensureDirC()`** — recursive directory creation helper for session storage path.

### Files
- Session files stored at `$XDG_STATE_HOME/teru/sessions/{name}.bin`
- 14 `markDirty()` call sites across all Multiplexer mutation methods
- Debounced save in both windowed and daemon event loops
- Final save on clean exit

## 0.3.7 (2026-04-09)

### Features
- **Native PNG screenshots** (`src/png.zig`) — pure Zig PNG encoder (stored deflate, CRC32, Adler-32). Zero external dependencies. Captures ARGB framebuffer directly.
- **`teru_screenshot` MCP tool** — agents capture the terminal framebuffer as PNG via MCP. Returns file path and dimensions. Windowed mode only (X11/Wayland).
- **19 MCP tools** — added `teru_session_save`, `teru_session_restore`, `teru_screenshot`
- **SECURITY.md** — vulnerability reporting policy and scope documentation
- **CONTRIBUTING.md** — contributor guide with setup, workflow, and help-wanted areas

### Build system
- **Single version source of truth** — `build.zig` line 10 defines version, propagated via `build_options.version` to main.zig, McpServer.zig, and PosixPty.zig at compile time. No more manual multi-file version syncing.
- **`make bump-version V=x.y.z`** — updates build.zig + build.zig.zon in one command
- **`zig build check`** — semantic analysis without linking, for cross-platform CI

### Fixes
- **MCP JSON escaping** — 6 tool responses had broken JSON from raw string `\\"` semantics; all fixed
- **VI mode crash** — replaced `unreachable` with null guard when active pane closes during keypress
- **Windows cross-compile** — SignalManager tests use `i32` instead of `posix.fd_t` (which is `*anyopaque` on Windows)
- **`TERM_PROGRAM_VERSION`** — now set from `build_options.version` instead of hardcoded string

### Documentation
- **README rewrite** — etymology, comparison table, quick start, AI integration guide, accurate feature counts
- **docs/AI-INTEGRATION.md** — complete MCP tool reference (19 tools), socket paths per platform, OSC 9999 protocol
- **docs/ARCHITECTURE.md** — rewritten to match current codebase
- **docs/INSTALLING.md** — removed stale Homebrew/Nix references
- **site/index.html** — landing page for teru.sh with structured data

### Stats
- 480+ inline tests (up from 451)
- 19 MCP tools (up from 16)

## 0.3.5 (2026-04-07)

### Cross-platform
- **PTY comptime dispatch** (`src/pty/pty.zig`) — single import point selects POSIX Pty or WinPty per OS; all 6 consumers migrated
- **Non-blocking WinPty read** — PeekNamedPipe + ReadFile replaces blocking ReadFile; returns `error.WouldBlock` matching POSIX O_NONBLOCK pattern; no threads needed
- **IPC abstraction** (`src/server/ipc.zig`) — cross-platform listen/accept/connect/buildPath: Unix sockets (POSIX) / named pipes (Windows)
- **All IPC consumers migrated** — daemon, McpServer, PaneBackend, HookListener, McpBridge use `ipc.zig` instead of raw socket calls
- **Windows raw mode** (`Terminal.zig`) — SetConsoleMode + WaitForMultipleObjects event loop for `teru --raw`
- **Windows ConPTY** (`src/pty/WinPty.zig`) — CreatePseudoConsole, pipe pairs, STARTUPINFOEX, ResizePseudoConsole
- **Windows clipboard** — Win32 OpenClipboard/SetClipboardData/GetClipboardData with UTF-8/UTF-16 conversion
- **Windows URL opener** — ShellExecuteW
- **macOS PTY** — `posix_openpt()` replaces `/dev/ptmx` (works on both Linux and macOS)
- **macOS HookListener fix** — replaced Linux-only `accept4` with portable `ipc.accept`
- **Portable O_NONBLOCK** — `compat.O_NONBLOCK` (0x800 Linux, 0x0004 macOS) replaces all hardcoded values
- **Portable IPC paths** — `ipc.buildPath`: `/run/user/{uid}/teru-*` (Linux), `/tmp/teru-{uid}-*` (macOS), `\\.\pipe\teru-*` (Windows)
- **Portable readlink** — McpServer uses `std.c.readlink` instead of `linux.readlinkat`
- **Pane.readAndProcess** — uses `self.pty.read()` instead of `posix.read(pty.master)`
- **Clipboard paste** — uses `pty.write()` instead of `std.c.write(pty.master)`
- **Zero raw socket calls** outside `ipc.zig` (all migrated)

### Fixes
- **Stale version env** — `TERM_PROGRAM_VERSION` in Pty.zig updated to match current version
- **macOS listSessions** — prefix matching now accounts for `teru-{uid}-session-*` format

## 0.3.4 (2026-04-07)

### Cross-platform
- **macOS keyboard translation** — IOKit keycode → UTF-8 via static lookup tables (no Carbon dependency), XKB-compatible keysyms, full modifier tracking (Shift, Ctrl, Option, Cmd, Caps Lock)
- **Windows keyboard translation** — VK code → UTF-8 via ToUnicode Win32 API, dead key support, full modifier tracking, XKB-compatible keysyms
- **Cross-platform config watcher** — Linux (inotify), macOS (kqueue EVFILT_VNODE), Windows (stat polling fallback)
- **Cross-platform build.zig** — conditional library linking per OS: AppKit+CoreGraphics+Carbon (macOS), user32+gdi32+kernel32 (Windows), xcb+xkbcommon+wayland (Linux)
- **Keyboard imports enabled** — main.zig comptime-selects Keyboard module per OS (Linux/macOS/Windows)

## 0.3.3 (2026-04-07)

### Cross-platform
- **Cross-platform clipboard** — macOS uses `pbcopy`/`pbpaste`, Windows stub for Win32 clipboard API
- **Cross-platform font discovery** — macOS searches `/System/Library/Fonts` (SF Mono, Menlo, Monaco), Windows searches `C:\Windows\Fonts` (Consolas, Cascadia)
- **Cross-platform URL opener** — macOS uses `/usr/bin/open`, Linux uses `xdg-open`, Windows stub for `ShellExecuteW`
- **Portable PTY** — replaced `linux.fork()`/`linux.exit()` with `compat.posixFork()`/`posixExit()` in Pty.zig (works on macOS)
- **macOS platform** — added mouse events, focus tracking, cursor hide/show (pending agent)
- **Windows platform** — Win32 window stub with full event handling (pending agent)

## 0.3.2 (2026-04-07)

### Cross-platform
- **Portable time abstraction** — `compat.monotonicNow()` replaces all `std.os.linux.clock_gettime` calls across main.zig, Multiplexer, Ui, Hooks, McpServer (supports Linux, macOS, Windows)
- **Portable process helpers** — `compat.getPid()`, `compat.getUid()`, `compat.sleepNs()` replace direct `linux.getpid/getuid/nanosleep` in daemon, McpServer, PaneBackend, HookListener
- **Portable fork/exec** — `compat.forkExec*()` uses POSIX `fork()`/`_exit()` on macOS, with Windows `CreateProcessW` stubs
- Zero `std.os.linux.*` references outside of `compat.zig` and `src/platform/linux/`

## 0.3.1 (2026-04-07)

### Features
- **`include` directive** — split config across files: `include keybindings.conf` (relative to `~/.config/teru/`, absolute paths supported, max depth 4)

### Fixes
- **Viewport height** — reverted cell-aligned snapping that wasted up to cell_height-1 pixels at the bottom; panes now use full available space

## 0.3.0 (2026-04-07)

### Features
- **Global shortcuts** — Alt+key actions without prefix key, Right Alt for pane manipulation
  - `Alt+1-9` switch workspace, `RAlt+1-9` move pane to workspace
  - `Alt+J/K` focus next/prev pane, `RAlt+J/K` swap pane down/up
  - `Alt+C` vertical split, `RAlt+C` horizontal split, `Alt+X` close pane
  - `Alt+M` focus master pane, `RAlt+M` mark pane as master
  - `Alt+-` / `Alt+=` font size zoom out/in
- **Master pane** — mark any pane as master per workspace, jump back from anywhere
- **Font size zoom** — re-rasterizes from memory (no file I/O), deferred SIGWINCH (150ms debounce)
- **Workspace attention colors** — non-active workspaces with output highlighted in red
- **Cell-aligned layout rects** — pane grids fill available space exactly, no gaps
- **Cross-platform keycode abstraction** — Linux (evdev), macOS (IOKit), Windows (VK) keycode tables

### Config
- `alt_workspace_switch = true` — enable/disable all Alt+key shortcuts
- `attention_color = #EB3137` — workspace attention indicator color

### Internal
- `FontAtlas.rasterizeAtSize()` — re-rasterize from in-memory font data
- `KeyHandler.handleGlobalKey()` — centralized global shortcut dispatch
- Platform `keycodes` struct with `digitToWorkspace()` function per platform
- `Workspace.master_id` and `Workspace.attention` fields
- `Multiplexer.movePaneToWorkspace()`, `swapPaneNext/Prev()`, `setMaster()`, `focusMaster()`

## 0.2.8 (2026-04-06)

### Features
- **Per-workspace layout lists**: `layouts = master-stack, grid, monocle` in workspace config (xmonad `|||` pattern)
- **8 tiling layouts**: master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion
- **`teru_set_layout` MCP tool**: agents can switch layouts programmatically (14 MCP tools total)
- **Dishes layout**: horizontal master-stack (master on top, columns below)
- **Accordion layout**: focused pane tall, others compressed to thin strips
- **Spiral layout**: Fibonacci alternating vertical/horizontal splits
- **Three-column layout**: master center, stacks on sides (ThreeColMid)
- **Columns layout**: equal-width vertical columns

### Fixes
- **Keyboard layout switching**: Cyrillic/Ukrainian and multi-layout support via xkb_state_update_key
- **Selection absolute coordinates**: selections stable across scrollback scrolling, work in both grid and scrollback
- **Selection in scrollback overlay**: highlight renders correctly in scrolled-back content
- **Vi mode selection color**: removed duplicate overlay that was painting solid color over text glyphs
- **Mouse drag-to-resize**: works for flat layouts (master-stack/three-col/dishes) with any number of panes
- **Layout switch reactive**: prefix+Space immediately resizes PTYs and redraws (no mouse click needed)
- **Status bar height**: PTY resize accounts for status bar, fixing bottom content cutoff
- **Resize both directions**: H/L for horizontal master, K/J for vertical master (dishes)
- **Auto-select respects config**: addNode/removeNode skip auto-layout when workspace has a layout list
- **Wayland modifier group**: keyboardModifiers callback captures layout group for proper layout switching

### Refactoring
- **Split LayoutEngine.zig** (2,077 lines) into 4 modules: types.zig, layouts.zig, Workspace.zig, facade
- **Extract scrollback helper**: Multiplexer.getScrollbackLineCount() replaces 17+ inline duplicates
- **Remove floating layout**: non-functional stub replaced by dishes

### Removed
- **Floating layout**: removed non-functional cascading window stub

## 0.2.7 (2026-04-06)

### Features
- **Per-workspace layout lists**: configure layout cycling per workspace with `layouts = master-stack, grid, monocle` in `[workspace.N]` config sections. Prefix+Space cycles within the workspace's list (xmonad `|||` pattern)
- **8 tiling layouts**: master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion
- **Spiral layout**: Fibonacci/golden ratio spiral that alternates vertical and horizontal splits
- **Three-column layout**: master pane in center with stacks on left and right sides (ThreeColMid)
- **Columns layout**: equal-width vertical columns
- **Dishes layout**: horizontal master-stack — master on top (full width), stack in columns below
- **Accordion layout**: focused pane gets most height, others compressed to thin strips
- **`teru_set_layout` MCP tool**: agents can switch layouts programmatically
- **Layout list hot-reload**: changing `layouts` in teru.conf applies immediately without restart

### Fixes
- **Resize in three-col/dishes layout**: `resizeActive` now adjusts master_ratio for three_col and dishes
- **Auto-select respects config**: `addNode`/`removeNode` no longer override the layout when a per-workspace layout list is configured
- **Split tree cleared on layout switch**: `cycleLayout`, `toggleZoom`, and `teru_set_layout` now clear the split tree so flat layouts take effect

### Removed
- **Floating layout**: removed non-functional stub (cascading windows with no user interaction)

## 0.2.6 (2026-04-06)

### Features
- **Session persistence (daemon mode)**: `teru --daemon <name>` starts a headless session where PTYs survive terminal close. `teru --session <name>` reattaches in TTY raw mode. `teru --list` shows active sessions. Ctrl+\ detaches.
- **Wire protocol**: 5-byte header (tag:u8 + len:u32) over Unix domain socket for daemon↔client communication. Message types: input, output, resize, detach, grid_sync.
- **Session socket**: `/run/user/{uid}/teru-session-{name}.sock` with permission 0660.

### Architecture
- `src/server/daemon.zig` — daemon event loop with poll() over PTY fds + client socket
- `src/server/protocol.zig` — message framing, encode/decode helpers
- One daemon per session (zmx/abduco pattern) for crash isolation

## 0.2.5 (2026-04-06)

### Features
- **Binary split tree layout**: horizontal and vertical splits with arbitrary nesting, replacing the flat pane list. Keyboard: `prefix + \` (vertical), `prefix + -` (horizontal)
- **Mouse drag-to-resize pane borders**: click and drag any split border to adjust the ratio
- **MCP pane creation with direction/command/cwd**: `teru_create_pane` supports `direction`, `command`, and `cwd` parameters. New panes inherit the active pane's working directory by default
- **Grid resize on pane layout change**: grid dimensions now match pane rect, so apps render at full pane width
- **teru-mcp skill**: `.claude/skills/teru-mcp.md` teaches agents how to use teru's MCP tools

### Fixes
- **Crash on pane creation**: dangling pointers after ArrayList reallocation — all pane VtParser/Grid/Scrollback pointers re-linked after append
- **Pane borders respect status bar**: layout calculation subtracts status bar height
- **JSON unescape in teru_send_input**: `\n`, `\r`, `\t` now sent as actual control characters
- **Ctrl+letter normalization in mux commands**: holding Ctrl after prefix no longer fails (e.g., Ctrl+Space then Ctrl+V = vi mode)
- **Mouse_down tracked during mouse tracking**: fixes tmux pane border drag-to-resize (mode 1002)
- **Selection release skipped during mouse tracking**: prevents selection finalization conflicts with app mouse handling

## 0.2.4 (2026-04-05)

### Features
- **Vi/copy mode**: keyboard-driven scrollback navigation and text selection (prefix + v)
  - hjkl / arrow keys for cursor movement, w/b/e for word motion
  - g/G for top/bottom of scrollback, Ctrl+U/D for half-page, H/M/L for viewport
  - v for character selection, V for line selection, o to swap endpoint
  - y to yank to clipboard, / to search, q or ESC to exit
  - Status bar shows -- VI -- / -- VISUAL -- / -- VISUAL LINE --
  - Vi cursor rendered as inverted block overlay

## 0.2.3 (2026-04-04)

### Features
- **DEC Special Graphics charset (ACS)**: ESC(0 / ESC(B for line-drawing character set — fixes garbled tmux borders

### Fixes
- **Alt+key sends ESC prefix**: Alt+1..9 for tmux windows, Alt+b/f for word movement now work
- **Scroll suppressed in alt screen**: tmux/vim handle scrolling themselves, teru no longer scrolls its own scrollback on top
- **Mouse tracking isolation**: drag events go to app (tmux border resize) instead of starting text selection when mouse tracking is active
- **Auto-scroll during drag selection**: dragging near viewport edges scrolls into scrollback
- **Deduplicated UTF-8 encoding**: Selection.getText uses shared appendUtf8 helper

## 0.2.2 (2026-04-04)

### Features
- **Programmatic box-drawing**: U+2500-U+257F and block elements U+2580-U+259F rendered pixel-perfect edge-to-edge, replacing font glyphs — fixes gaps in separator lines
- **Scrollback preserves colors and attributes**: bg color, bold/dim/italic/inverse encoded in scrollback lines, full UTF-8 (was ASCII-only, fg-only)
- **Scrollback selection**: text selection works in scrollback region, reads from scrollback buffer for rows above viewport

### Fixes
- Removed unconditional dimColor() that dimmed all scrollback text — colors now match active viewport
- Scrollback renderer parses bg color SGR codes and attributes, renders via atlas for non-ASCII

### CI
- Fixed release workflow (removed broken aarch64 cross-compilation)
- Replaced AUR publish action with direct script (KSXGitHub action had bash bug)

## 0.2.1 (2026-04-03)

### Features
- **Live config reload**: inotify watches ~/.config/teru/ directory for teru.conf changes
- **Mouse reporting**: modes 1000/1002/1003/1006 for app mouse support (vim, tmux)

## 0.2.0 (2026-04-03)

### Features
- **Config system**: `[section]` headers, `[workspace.N]` per-workspace config, external theme files
- **30+ config options**: opacity, cursor_blink, cursor_shape, tab_width, scroll_speed, bell, copy_on_select, padding, prefix_timeout_ms, bold_is_bright, term, font_bold/italic/bold_italic, show_status_bar, bar_left/center/right, mouse_hide_when_typing, word_delimiters, dynamic_title, notification_duration_ms
- **Base16 themes**: `theme = miozu` built-in, external files at `~/.config/teru/themes/<name>.conf` with base00-base0F keys
- **Workspace tabs status bar**: shows all active workspaces, layout indicator [M/G/#/F], pane title from OSC, configurable sections
- **Bold/italic font rendering**: separate font files per style (font_bold, font_italic), atlas-per-variant with fallback
- **bold_is_bright**: shift ANSI 0-7 to bright 8-15 when cell is bold
- **Double-click word select**: 300ms detection, configurable word_delimiters
- **Mouse hide when typing**: X11 invisible cursor, Wayland wl_pointer_set_cursor(null)
- **Bracketed paste**: wraps paste with `\e[200~`/`\e[201~` when mode 2004 is active
- **Focus events**: sends `\e[I`/`\e[O` to PTY on window focus change
- **CLI flags**: --config, --theme, --class, improved --help with keybinding reference
- **Window opacity**: `_NET_WM_WINDOW_OPACITY` (X11), `setAlphaValue` (macOS)
- **Cursor blink**: 530ms timer, resets to solid on keypress
- **Wayland mouse**: full `wl_pointer` listener — click, motion, scroll wheel
- **macOS compilation fix**: replaced `@Type`-based `MsgSendType` with concrete function pointer types (Zig 0.16 compat)
- **Platform parity**: X11, Wayland, macOS share matching API surface

### Performance
- **XCB-SHM zero-copy framebuffer**: ~10x faster X11 rendering vs socket transfer
- **Pixel-smooth scrolling**: sub-cell offset accumulator, configurable scroll_speed
- **Scroll position pinning**: viewport stays in place while output arrives
- **Key repeat debounce removed**: typing at native compositor rate

### Fixes
- Scroll overlay clipped to active pane rect (no bleed across panes or status bar)
- Color-preserving scrollback: SGR colors retained, dimmed to 75%
- Smart scroll exit: modifier keys, F-keys, arrows don't reset scroll position
- PageUp/PageDown work without Shift modifier
- All config fields wired to subsystems (shell, scrollback_lines, term, padding, etc.)
- Code review cleanup: shmat error check, dead code removal, redundant checks

## 0.1.20 (2026-04-03)

### Features
- Window opacity (`opacity` config option, X11 `_NET_WM_WINDOW_OPACITY`)
- Cursor blink (530ms timer, `cursor_blink` config option)
- External theme file loading (`~/.config/teru/themes/<name>.conf`)
- Base16 key mapping (`base00`-`base0F` mapped to ANSI palette + semantic colors)
- Configurable bell (`visual` or `none`), copy-on-select, cursor shape, tab width

## 0.1.19 (2026-04-03)

### Features
- Config wired to all subsystems: padding, ColorScheme, shell, scrollback, term, prefix timeout, notification duration, scroll speed
- Per-workspace layout, master ratio, and name applied at startup

## 0.1.18 (2026-04-03)

### Features
- Pixel-smooth scrolling with sub-cell offset (kitty/ghostty-style)
- Scroll position pinning: viewport stays put while output is generated
- PageUp/PageDown work without Shift modifier

### Fixes
- Smart scroll exit: modifier keys (Ctrl, Super, Alt, Shift) no longer reset scroll position
- Escape sequences (F-keys, arrows) no longer exit scroll mode
- Removed key repeat debounce that throttled typing to 30fps

## 0.1.17 (2026-04-03)

### Performance
- XCB-SHM zero-copy framebuffer: ~10x faster X11 rendering vs xcb_put_image socket transfer
- Link xcb-shm library for X11 builds

## 0.1.16 (2026-04-03)

### Features
- Color-preserving scrollback: SGR colors (red, green, etc.) retained in scroll history
- Scrollback capture encodes cell foreground colors as SGR sequences
- SGR parser in scroll overlay handles indexed (256) and RGB colors

### Fixes
- dimColor now 75% brightness (was 50%, too dim on dark themes)

## 0.1.15 (2026-04-03)

### Features
- Ctrl+Shift+C/V copy/paste keyboard shortcuts
- Status bar notifications with auto-clear (copy feedback, etc.)
- Per-pane independent scrollback
- Scroll overlay clipped to pane rect boundaries

### Fixes
- Pane content clipping to prevent rendering outside pane bounds
- Click-to-focus for multi-pane layouts
- Keyboard architecture overhaul: Cyrillic/non-Latin input, modifier sync, layout switching
- Reset keyboard state on focus-in to prevent stuck modifiers

## 0.1.4 (2026-04-02)

### Features
- OSC 8 hyperlinks: clickable links from CLI tools
- Base16 ColorScheme: fully configurable ANSI palette (color0-color15 in teru.conf)
- MCP stdio bridge (--mcp-bridge) + 7 new tools for terminal control
- Non-destructive scrollback browsing with synchronized output (DEC 2026)

### Refactoring
- Extracted Compositor, Ui, SignalManager into separate modules

### Fixes
- PTY echo race condition
- VT parser ESC\ (ST) handling
- Glyph clipping at cell boundaries

## 0.1.3 (2026-04-01)

### Features
- Configurable prefix key: `prefix_key = ctrl+b` in teru.conf (accepts ctrl+a through ctrl+z, ctrl+space, raw integers)
- Pane zoom: `Ctrl+Space, z` toggles between current layout and monocle, restores on second press
- Pane resize: `Ctrl+Space, H/L` adjusts master ratio in master-stack layout (15%-85%)

## 0.1.2 (2026-04-01)

### Features
- Claude Code hook listener: Unix socket HTTP server accepts lifecycle events (16 event types)
- Three-layer AI integration fully wired: PaneBackend + HookListener + MCP Server
- HookHandler expanded from 5 to 16 event types (PreToolUse, PostToolUse, SessionStart/End, Stop, Notification, PreCompact/PostCompact)
- processHookEvent dispatches to ProcessGraph (agent spawn/stop/pause, tool activity)
- Full project roadmap added (docs/plans/2026-03-31-roadmap.md)

## 0.1.1 (2026-03-31)

### Fixes
- Clipboard: auto-detect display server — use `wl-copy`/`wl-paste` on Wayland, `xclip` on X11
- Build: link `libxkbcommon` for Wayland-only builds (keyboard was broken with `-Dx11=false`)
- Keyboard: enable xkbcommon translation for both X11 and Wayland backends

### Packaging
- AUR package live: `paru -S teru`
- Added Makefile with build profiles (`make dev`, `make release`, `make install`)
- Added `optdepends` for clipboard tools in PKGBUILD

## 0.1.0 (2026-03-31)

Initial release.

### Terminal
- VT100/xterm state machine (CSI, SGR 256+truecolor, OSC, DCS passthrough)
- UTF-8 multi-byte decoding
- Alt-screen buffer (vim, htop, less work correctly)
- CPU SIMD rendering (no GPU required, <50μs per frame)
- Unicode fonts: ASCII, Latin-1, box-drawing, block elements (351 glyphs)
- Cursor styles: block, underline, bar (DECSCUSR)
- Visual bell (framebuffer flash)
- xkbcommon keyboard (any layout — dvorak, colemak, etc.)
- Mouse selection + clipboard (via xclip)
- Scrollback browsing (Shift+PageUp/Down)
- URL detection + Ctrl+click (xdg-open)
- Search (Ctrl+Space, /)
- Content padding (4px)
- Config file (~/.config/teru/teru.conf)

### Multiplexer
- Multi-pane with 4 tiling layouts (master-stack, grid, monocle, floating)
- 9 workspaces (Ctrl+Space, 1-9)
- Prefix keybindings (Ctrl+Space)
- Session save/restore (--attach)
- Command-stream scrollback compression (20-50x)

### AI-First
- CustomPaneBackend protocol for Claude Code agent teams (7 operations)
- MCP server (6 tools: list_panes, read_output, get_graph, send_input, create_pane, broadcast)
- OSC 9999 agent protocol (start/stop/status/progress)
- OSC 133 shell integration (command blocks, exit codes)
- Process graph (DAG with agent metadata)
- Hook system (spawn/close/agent_start/session_save)

### Platform
- X11 via pure XCB (hand-declared externs, no Xlib)
- Wayland via xdg-shell + wl_shm
- macOS AppKit shell (compiles, untested)
- Windows Win32 shell (compiles, untested)
- TTY raw passthrough mode (--raw, for SSH)
- Build options: -Dx11=false, -Dwayland=false
