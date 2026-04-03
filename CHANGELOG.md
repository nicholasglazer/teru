# Changelog

## 0.2.0 (2026-04-03)

### Features
- Config system upgrade: `[section]` headers, `[workspace.N]` sections, external theme files
- Base16 theme support: `theme = miozu` built-in, or load from `~/.config/teru/themes/<name>.conf`
- External theme files support base16 keys (`base00`-`base0F`) and direct color keys
- 25+ new config options: `opacity`, `cursor_blink`, `cursor_shape`, `tab_width`, `scroll_speed`, `bell`, `copy_on_select`, `padding`, `prefix_timeout_ms`, `bold_is_bright`, `term`, `font_bold`, `font_italic`, `font_bold_italic`, `dynamic_title`, `notification_duration_ms`
- Per-workspace config: `[workspace.1]` with `layout`, `master_ratio`, `name`
- Window opacity via `_NET_WM_WINDOW_OPACITY` (X11) and `setAlphaValue` (macOS)
- Cursor blink: 530ms on/off timer, configurable via `cursor_blink = true`
- Wayland mouse support: `wl_pointer` listener with click, motion, scroll
- macOS backend compilation fix: replaced `@Type`-based `MsgSendType` (removed in Zig 0.16) with concrete function pointer types
- Platform parity: X11, Wayland, and macOS now share matching API surface (`setOpacity`, `setTitle`, `getX11Info`)

### Fixes
- Config fields `bell`, `copy_on_select`, `cursor_shape`, `tab_width` wired to subsystems (were dead code)
- `padding`, `scroll_speed`, `prefix_timeout_ms`, `notification_duration_ms` wired to runtime
- Full `ColorScheme` applied to renderer (was cursor_color only)
- `shell`, `scrollback_lines`, `term` threaded through to PTY spawn

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
