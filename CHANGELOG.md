# Changelog

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
