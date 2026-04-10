<div align="center">

<h1>teru 照</h1>

<p><em>teru (照) -- to shine, to illuminate</em></p>

<p><strong>AI-first terminal emulator, multiplexer, and tiling manager.<br>A tmux replacement that speaks the same protocols as your AI agents.<br>One binary. No GPU. 1.4MB.</strong></p>

<p>
  <a href="https://teru.sh"><img src="https://img.shields.io/badge/web-teru.sh-blue" alt="Website"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
  <a href="https://github.com/nicholasglazer/teru/actions"><img src="https://github.com/nicholasglazer/teru/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/zig-0.16-orange" alt="Zig 0.16">
  <img src="https://img.shields.io/badge/tests-526-blue" alt="Tests">
  <img src="https://img.shields.io/badge/binary-1.4MB-brightgreen" alt="Binary Size">
  <a href="https://aur.archlinux.org/packages/teru"><img src="https://img.shields.io/aur/version/teru" alt="AUR"></a>
</p>

<p>
  <a href="https://teru.sh">Website</a> &middot;
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#installation">Installation</a> &middot;
  <a href="#features">Features</a> &middot;
  <a href="#keybindings">Keybindings</a> &middot;
  <a href="#configuration">Configuration</a> &middot;
  <a href="#ai-integration">AI Integration</a> &middot;
  <a href="#contributing">Contributing</a>
</p>

<!-- TODO: Add hero screenshot showing multi-pane layout with miozu theme -->
<!-- <img src="docs/assets/hero.png" alt="teru terminal emulator" width="800"> -->

</div>

---

### What is "AI-first"?

teru speaks the same protocols as Claude Code. When AI agents spawn subprocesses, teru manages them as first-class panes -- auto-assigning workspaces, tracking status in a process graph, and letting any agent read another agent's terminal output via MCP. No configuration needed. No tmux. It just works.

### Why not tmux + Ghostty/Alacritty/WezTerm?

| Problem | tmux + terminal | teru |
|---------|----------------|------|
| Claude Code agent teams | Spawns break layouts, no process awareness | Native protocol -- agents auto-organize |
| Configuration | 3 layers (tmux.conf + shell + WM bindings) | Single config file, everything built-in |
| GPU dependency | GPU-accelerated rendering idles 99.9% of the time on text | CPU SIMD -- works over SSH, VMs, containers, headless |
| Process relationships | No terminal knows what's running or why | Process graph tracks parent-child + agent metadata |
| Binary size | 30-80MB terminal + 4MB tmux | **1.4MB total** |

teru is a **tmux alternative** that replaces your multiplexer, tiling manager, and terminal in one binary. If you use Claude Code, Cursor, or any AI coding tool that spawns agents, teru is built for you.

---

## Quick Start

```bash
# Install (Arch Linux)
paru -S teru

# Launch
teru

# Essential keys
Alt+Enter                 # new pane (vertical split)
Alt+C                     # split vertical
RAlt+C                    # split horizontal
Alt+J / Alt+K             # focus next / prev pane
Alt+1-9                   # switch workspace
Alt+Space                 # cycle layout (8 layouts)
Alt+Z                     # zoom pane (maximize)
Alt+X                     # close pane
Alt+V                     # vi/copy mode
Alt+/                     # search scrollback
```

Session persistence:

```bash
teru                              # fresh scratchpad (no persistence)
teru -n myproject                 # persistent named session (daemon auto-started)
teru -n myproject -t claude-power # start from template
teru -l                           # list active sessions
# Alt+D to detach, re-run same command to reattach
```

---

## Installation

### Pre-built binaries

Download from [GitHub Releases](https://github.com/nicholasglazer/teru/releases):

| Platform | File | Notes |
|----------|------|-------|
| Linux x86_64 | `teru-linux-x86_64.tar.gz` | X11 + Wayland |
| Linux x86_64 (X11 only) | `teru-linux-x86_64-x11.tar.gz` | No wayland dep |
| Linux x86_64 (Wayland only) | `teru-linux-x86_64-wayland.tar.gz` | No xcb dep |
| Windows x86_64 | `teru-windows-x86_64.zip` | Win10+ (ConPTY) |
| macOS x86_64 | `teru-macos-x86_64.tar.gz` | Intel Mac |
| macOS aarch64 | `teru-macos-aarch64.tar.gz` | Apple Silicon |

### Arch Linux (AUR)

```bash
paru -S teru
```

Optional clipboard support: `paru -S xclip` (X11) or `paru -S wl-clipboard` (Wayland).

### macOS

```bash
# Download and install
curl -L https://github.com/nicholasglazer/teru/releases/latest/download/teru-macos-aarch64.tar.gz | tar xz
sudo mv teru /usr/local/bin/
```

### Windows

Download `teru-windows-x86_64.zip` from [Releases](https://github.com/nicholasglazer/teru/releases), extract, and run `teru.exe`. Requires Windows 10 1809+ (ConPTY support).

### Build from source

Requires **Zig 0.16+**. Linux builds need system libraries.

**Linux dependencies:**

| Package | Arch Linux | Debian/Ubuntu | Fedora |
|---------|------------|---------------|--------|
| libxcb | `libxcb` | `libxcb1-dev` | `libxcb-devel` |
| libxkbcommon | `libxkbcommon` | `libxkbcommon-dev` | `libxkbcommon-devel` |
| wayland | `wayland` | `libwayland-dev` | `wayland-devel` |

```bash
git clone https://github.com/nicholasglazer/teru.git
cd teru

# Linux
make release              # 1.4MB binary at zig-out/bin/teru
sudo make install         # /usr/local/bin/teru

# macOS (no system deps needed — links AppKit/CoreGraphics)
zig build -Doptimize=ReleaseSafe

# Windows (cross-compile from Linux, or native on Windows)
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu
```

**Minimal Linux builds** (fewer dependencies):

```bash
make release-x11          # X11-only (no wayland-client dep)
make release-wayland      # Wayland-only (no libxcb dep)
```

### Run

```bash
teru                              # fresh terminal (windowed, X11/Wayland auto-detected)
teru -e htop                      # run a command instead of shell
teru -e ~/.miozu/bin/script.sh    # run a script (window closes on exit)
teru --no-bar                     # start with status bar hidden (scratchpad mode)
teru -n myproject                 # persistent named session (daemon auto-started)
teru -n myproject -t claude-power # start from template
teru -l                           # list active sessions
teru --raw                        # TTY mode (over SSH, like tmux)
teru --daemon myproject           # start headless daemon (server use)
```

---

## How teru compares

| Feature | teru | Ghostty | Alacritty | WezTerm | Zellij | Warp |
|---------|:----:|:-------:|:---------:|:-------:|:------:|:----:|
| **Binary size** | **1.4MB** | 30MB | 6MB | 25MB | 12MB | 80MB+ |
| **GPU required** | **No** | Yes | Yes | Yes | No | Yes |
| **Built-in multiplexer** | **Yes** | No | No | Yes | Yes | Tabs |
| **Tiling layouts** | **8** | No | No | No | 4 | No |
| **AI agent protocol** | **Agent orchestration** | No | No | No | No | Command suggestions* |
| **Process graph** | **Yes** | No | No | No | No | No |
| **Claude Code native** | **Yes** | No | No | No | No | No |
| **MCP server** | **19 tools + prompts** | No | No | No | No | No |
| **Session persistence** | **Auto + Daemon** | No | No | Yes | Yes | Cloud |
| **Scrollback compression** | **20-50x** | Paged | Ring | Ring | Host | Block |
| **Language** | Zig | Zig | Rust | Rust | Rust | Rust |
| **License** | MIT | MIT | Apache | MIT | MIT | Proprietary |

*Warp's AI provides command suggestions and shell completions (cloud-based). teru's AI integration is agent orchestration -- managing multi-agent panes, process graphs, and cross-agent MCP communication (local, no cloud).

---

## Features

- **CPU SIMD rendering** -- `@Vector` alpha blending, no GPU, <50us per frame
- **8 tiling layouts** -- master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion
- **Per-workspace layout lists** -- configure which layouts each workspace cycles through (xmonad `|||` pattern)
- **Binary split tree** -- arbitrary horizontal/vertical splits with mouse drag-to-resize
- **10 workspaces** -- switch with Alt+1-9,0, each with independent layout and pane list
- **Vi/copy mode** -- prefix + v for vim-like cursor navigation, visual selection, yank to clipboard
- **Session persistence** -- `teru -n NAME` for named sessions with auto-daemon; `restore_layout = true` for lightweight layout restore; `persist_session = true` for auto-daemon; `.tsess` templates for reproducible workspaces
- **CustomPaneBackend** -- native Claude Code agent team protocol (7 operations)
- **MCP server** -- 19 tools for cross-agent pane control over IPC (including live config)
- **OSC 9999** -- agent self-declaration protocol (start/stop/status/progress)
- **OSC 133** -- shell integration (command blocks, exit code tracking)
- **Process graph** -- DAG of all processes/agents with lifecycle tracking
- **Command-stream scrollback** -- keyframe/delta compression (20-50x vs expanded cells)
- **Unicode fonts** -- ASCII, Latin-1, Cyrillic, box-drawing, block elements (607 glyphs via stb_truetype)
- **Keyboard** -- xkbcommon (Linux), IOKit tables (macOS), VK+ToUnicode (Windows); any layout
- **Mouse** -- selection, word double-click, clipboard (X11 via xclip, Wayland via wl-clipboard), drag-to-resize borders
- **Search** -- prefix + / highlights matches in visible grid
- **Themes** -- built-in miozu theme, base16 external theme files, per-color overrides
- **Configurable keybindings** -- per-mode binding tables (`[keybinds.normal]`, `[keybinds.prefix]`, `[keybinds.scroll]`), shared bindings, unbind, namespaced actions
- **Config file** -- `~/.config/teru/teru.conf`, hot-reload (inotify/kqueue/polling), `include` directive
- **MCP prompts** -- `workspace_setup` prompt teaches AI clients how to compose tools for workspace configuration
- **Hook system** -- external commands on spawn/close/agent/save events
- **Alt-screen** -- vim, htop, less work correctly (dual cell buffers)
- **VT compatibility** -- CSI, SGR (256 + truecolor), DCS passthrough, DECSCUSR cursor styles, DEC Special Graphics
- **Cross-platform** -- Linux (X11+Wayland), macOS (AppKit), Windows (Win32+ConPTY)

### Platform Support

| Feature | Linux | macOS | Windows |
|---------|:-----:|:-----:|:-------:|
| **Window/Display** | X11 + Wayland | AppKit (Cocoa) | Win32 (GDI) |
| **PTY/Shell** | posix_openpt + fork | posix_openpt + fork | ConPTY (CreatePseudoConsole) |
| **Keyboard** | xkbcommon (any layout) | IOKit static tables (US) | Win32 ToUnicode (any layout) |
| **Clipboard** | xclip / wl-clipboard | pbcopy / pbpaste | Win32 API (CF_UNICODETEXT) |
| **URL opener** | xdg-open | /usr/bin/open | ShellExecuteW |
| **Font discovery** | /usr/share/fonts | /System/Library/Fonts | C:\Windows\Fonts |
| **Config watcher** | inotify (real-time) | kqueue (real-time) | stat polling |
| **Session daemon** | Unix socket | Unix socket (/tmp) | Named pipes |
| **MCP server** | Unix socket | Unix socket (/tmp) | Named pipes |
| **Hooks listener** | Unix socket | Unix socket | Named pipes |
| **Signal handling** | SIGWINCH | SIGWINCH | N/A (message pump) |
| **Build deps** | xcb, xkbcommon, wayland | AppKit, CoreGraphics | user32, gdi32, kernel32 |

**Status:** Linux is production-ready. macOS is feature-complete (needs hardware testing). Windows has all subsystems wired end-to-end (ConPTY, keyboard, clipboard, window, raw mode, IPC via named pipes) — needs hardware testing. Session listing on Windows requires explicit names.

---

## Keybindings

All keybindings are **configurable** via `~/.config/teru/keybinds.conf`. Alt is the primary modifier -- no prefix key needed. Legacy prefix mode (`Ctrl+Space`) still works as fallback.

### Alt Shortcuts (primary)

| Key | Action |
|-----|--------|
| `Alt+J` / `Alt+K` | Focus next / prev pane |
| `Alt+1`-`9` | Switch workspace |
| `Alt+Enter` | New pane (vertical split) |
| `Alt+C` | Split vertical |
| `RAlt+Enter` / `RAlt+C` | Split horizontal |
| `Alt+X` | Close pane |
| `Alt+Z` | Toggle pane zoom (maximize) |
| `Alt+Space` | Cycle layout |
| `Alt+/` | Search scrollback |
| `Alt+V` | Vi/scroll mode |
| `Alt+D` | Detach session |
| `Alt+M` | Focus master pane |
| `Alt+B` | Toggle status bar |
| `Alt+=` / `Alt+-` | Zoom in / out |
| `Alt+\` | Reset zoom |
| `RAlt+J` / `RAlt+K` | Swap pane next / prev |
| `RAlt+H` / `RAlt+L` | Resize pane width |
| `RAlt+1`-`9` | Move pane to workspace |
| `RAlt+M` | Set active pane as master |

### Scrolling

| Key | Action |
|-----|--------|
| `Shift+PageUp` / `PageUp` | Scroll up |
| `Shift+PageDown` / `PageDown` | Scroll down |
| Mouse wheel | Smooth scroll |
| Any key | Exit scroll mode |

### Vi/Copy Mode (prefix + v)

| Key | Action |
|-----|--------|
| `h` `j` `k` `l` / arrows | Move cursor |
| `w` `b` `e` | Word motion |
| `g` / `G` | Top / bottom of scrollback |
| `Ctrl+U` / `Ctrl+D` | Half-page up / down |
| `H` `M` `L` | Viewport top / middle / bottom |
| `v` | Start character selection |
| `V` | Start line selection |
| `o` | Swap selection endpoint |
| `y` | Yank to clipboard |
| `q` / `ESC` | Exit vi mode |

### Mouse

| Action | Effect |
|--------|--------|
| Click | Focus pane |
| Drag | Select text |
| Double-click | Select word |
| Drag past edge | Auto-scroll + extend selection |
| Drag pane border | Resize split |
| `Ctrl+Shift+C` | Copy selection |
| `Ctrl+Shift+V` | Paste from clipboard |

---

## Configuration

Two config files, both auto-reload on change:

- `~/.config/teru/teru.conf` -- appearance, behavior, workspaces
- `~/.config/teru/keybinds.conf` -- all keybindings (included via `include keybinds.conf`)

```conf
# teru.conf — main config
include keybinds.conf

font_size = 16
font_path = /usr/share/fonts/TTF/JetBrainsMono-Regular.ttf
padding = 8
opacity = 0.95
theme = miozu
copy_on_select = true

[workspace.1]
layouts = master-stack, grid, monocle
master_ratio = 0.6
name = code
```

```conf
# keybinds.conf — per-mode keybinding config
#
# Format: [keybinds.MODE] then trigger = action
# Modes: normal, prefix, scroll, search, locked, shared
# Triggers: alt+j, ctrl+shift+c, ralt+1, esc, space
# Actions: pane:focus_next, workspace:3, zoom:in, mode:prefix, etc.
# Unbind: trigger =  (empty RHS)

[keybinds.normal]
alt+j           = pane:focus_next
alt+k           = pane:focus_prev
alt+c           = split:vertical
ralt+c          = split:horizontal
alt+x           = pane:close
alt+z           = zoom:toggle
alt+space       = layout:cycle
alt+1           = workspace:1
ctrl+space      = mode:prefix

[keybinds.prefix]
c               = split:vertical
x               = pane:close
esc             = mode:normal

[keybinds.scroll]
j               = scroll:down:1
k               = scroll:up:1
q               = mode:normal

[keybinds.shared]
ctrl+shift+c    = copy:selection
ctrl+shift+v    = paste:clipboard
```

### Layout Types

| Layout | Description | Key |
|--------|-------------|-----|
| `master-stack` | One master left, vertical stack right | `[M]` |
| `grid` | Equal-sized grid | `[G]` |
| `monocle` | Fullscreen active pane | `[#]` |
| `dishes` | Master on top, columns below | `[D]` |
| `spiral` | Fibonacci alternating splits | `[S]` |
| `three-col` | Master center, stacks on sides | `[3]` |
| `columns` | Equal-width vertical columns | `[|]` |
| `accordion` | Focused pane tall, others compressed | `[A]` |

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full reference.

---

## Session Persistence

teru has three levels of session persistence:

| Mode | Command | What persists | Daemon? |
|------|---------|---------------|---------|
| **Fresh** | `teru` | Nothing -- scratchpad | No |
| **Layout restore** | Set `restore_layout = true` | Pane count, layouts, workspaces | No |
| **Named session** | `teru -n myproject` | Everything -- processes, scrollback, state | Yes (auto) |

### Named sessions

```bash
teru -n myproject                 # create or reattach to "myproject"
# work, split panes, run servers...
# Alt+D to detach (or close the window)
teru -n myproject                 # reattach — everything is exactly where you left it
teru -l                           # list active sessions
```

Named sessions auto-start a daemon. PTY processes survive window close. Full state (workspace position, focus, master ratio, zoom) is synced between daemon and window.

### Templates

Templates are `.tsess` files that define multi-workspace session layouts:

```conf
# ~/.config/teru/templates/dev.tsess
[session]
name = dev
description = Development environment

[workspace.1]
name = code
layout = master-stack
master_ratio = 0.6

[workspace.1.pane.1]
command = nvim .

[workspace.1.pane.2]
command = fish

[workspace.2]
name = servers
layout = columns

[workspace.2.pane.1]
command = make dev-server

[workspace.2.pane.2]
command = tail -f /var/log/app.log
```

Use templates with `-t`:

```bash
teru -n myproject -t dev          # first run: applies template. subsequent runs: reattaches.
```

Templates are searched in `~/.config/teru/templates/` then `./examples/`. Export your current session via the `teru_session_save` MCP tool.

See `examples/claude-power.tsess` for a full 10-workspace, 34-pane example.

---

## CLI Reference

| Flag | Long | Description |
|------|------|-------------|
| `-n NAME` | `--name NAME` | Connect to (or start) named session |
| `-t NAME` | `--template NAME` | Apply template (.tsess) on first start |
| `-l` | `--list` | List active sessions |
| `-v` | `--version` | Show version |
| `-h` | `--help` | Show help |
| | `--raw` | Raw TTY mode (no window, for SSH) |
| | `--daemon NAME` | Start headless daemon (server use) |
| | `--mcp-bridge` | MCP stdio bridge |
| | `--class NAME` | Set WM_CLASS |

---

## AI Integration

### Claude Code Agent Teams

teru implements the CustomPaneBackend protocol. When Claude Code spawns agent teams, teru manages the panes natively -- no tmux.

```bash
# Set automatically by teru:
export CLAUDE_PANE_BACKEND_SOCKET=/run/user/1000/teru-pane-backend.sock

# Claude Code sends JSON-RPC:
{"method":"spawn","params":{"argv":["claude","--agent","backend-dev"],"metadata":{"group":"team-temporal"}}}

# teru creates a pane, adds to ProcessGraph, auto-assigns workspace
```

### MCP Server

teru exposes 19 tools over IPC (Unix socket / named pipe) for agent-to-agent pane control:

```json
{
  "mcpServers": {
    "teru": {
      "command": "socat",
      "args": ["UNIX-CONNECT:/run/user/1000/teru-mcp-PID.sock", "STDIO"]
    }
  }
}
```

| Tool | Description |
|------|-------------|
| `teru_list_panes` | List all panes with id, workspace, status |
| `teru_read_output` | Get recent N lines from any pane |
| `teru_get_graph` | Full process graph as JSON |
| `teru_send_input` | Type into any pane's PTY |
| `teru_send_keys` | Send keystrokes (enter, ctrl+c, arrows, etc.) |
| `teru_create_pane` | Spawn pane with direction, command, and cwd |
| `teru_close_pane` | Close a pane by ID |
| `teru_focus_pane` | Switch focus to a pane |
| `teru_switch_workspace` | Switch active workspace |
| `teru_set_layout` | Set layout (master-stack, spiral, etc.) |
| `teru_broadcast` | Send text to all panes in a workspace |
| `teru_get_state` | Query terminal state (cursor, size, modes) |
| `teru_scroll` | Scroll pane scrollback (up/down/bottom) |
| `teru_wait_for` | Check if text pattern exists in pane output |
| `teru_set_config` | Set a config value (writes to teru.conf, triggers hot-reload) |
| `teru_get_config` | Get current live config values as JSON |
| `teru_session_save` | Save session state to .tsess file |
| `teru_session_restore` | Restore session from .tsess file |
| `teru_screenshot` | Capture framebuffer as PNG file |

### Agent Protocol (OSC 9999)

Any process can self-declare as an AI agent:

```bash
printf '\e]9999;agent:start;name=backend-dev;group=team-temporal\a'
printf '\e]9999;agent:status;progress=0.6;task=Building API\a'
printf '\e]9999;agent:stop;exit=success\a'
```

teru tracks agents in the ProcessGraph, colors pane borders by status (cyan=running, green=done, red=failed), and shows counts in the status bar.

---

## Architecture

```
src/
├── main.zig                Entry point, event loop, input handling
├── compat.zig              Cross-platform primitives (time, process, fork, O_NONBLOCK)
├── lib.zig                 Library root, C-ABI API, test runner (526+ tests)
├── core/
│   ├── Grid.zig            Character grid (cells, cursor, scroll regions, alt-screen)
│   ├── VtParser.zig        VT100/xterm state machine (SIMD fast-path)
│   ├── Pane.zig            PTY+Grid+VtParser per pane
│   ├── Multiplexer.zig     Multi-pane orchestrator + rendering
│   ├── KeyHandler.zig      Config-driven keybind dispatch
│   ├── Selection.zig       Text selection (absolute coords, scrollback-aware)
│   ├── ViMode.zig          Vi/copy mode (cursor navigation, visual selection)
│   ├── Clipboard.zig       Cross-platform clipboard (xclip, pbcopy, Win32 API)
│   ├── Terminal.zig        Raw mode (POSIX termios / Win32 console)
│   └── UrlDetector.zig     URL detection (regex-free)
├── agent/
│   ├── PaneBackend.zig     CustomPaneBackend protocol (Claude Code)
│   ├── McpServer.zig       MCP server (19 tools, IPC)
│   ├── HookHandler.zig     Claude Code hook JSON parser
│   ├── HookListener.zig    HTTP hook listener (IPC)
│   └── protocol.zig        OSC 9999 agent protocol parser
├── graph/
│   └── ProcessGraph.zig    Process DAG (nodes, edges, agent metadata)
├── tiling/
│   ├── LayoutEngine.zig    Layout dispatch facade + workspace management
│   ├── Workspace.zig       Workspace state (flat list + split tree + layout cycling)
│   ├── layouts.zig         8 layout calculation algorithms
│   └── types.zig           Rect, Layout, SplitDirection, SplitNode
├── persist/
│   ├── Session.zig         Binary serialization (save/restore)
│   └── Scrollback.zig      Command-stream compression (keyframe/delta)
├── render/
│   ├── software.zig        CPU SIMD renderer (@Vector alpha blending)
│   ├── FontAtlas.zig       stb_truetype glyph rasterization (607 glyphs)
│   ├── Compositor.zig      Pane/border/glyph compositing into framebuffer
│   ├── Ui.zig              Status bar, scroll overlay, search overlay
│   └── tier.zig            Two-tier detection (CPU/TTY)
├── config/
│   ├── Config.zig          Config parser + ColorScheme + hot-reload + include
│   ├── Keybinds.zig        Configurable keybinding engine (modes, actions, lookup)
│   ├── ConfigWatcher.zig   File watcher (inotify/kqueue/polling)
│   ├── Hooks.zig           External command hooks (fork+exec)
│   └── themes.zig          Built-in theme definitions
├── server/
│   ├── daemon.zig          Headless session daemon (PTY persistence)
│   ├── protocol.zig        Wire protocol (5-byte header)
│   └── ipc.zig             Cross-platform IPC (Unix sockets / named pipes)
├── png.zig                 Pure Zig PNG encoder (stored deflate, CRC32, Adler-32)
├── pty/
│   ├── pty.zig              Comptime dispatch (POSIX or ConPTY per OS)
│   ├── PosixPty.zig         POSIX PTY (posix_openpt, fork, exec)
│   ├── RemotePty.zig        Daemon-backed PTY (connects to running daemon)
│   └── WinPty.zig           Windows ConPTY (CreatePseudoConsole)
└── platform/
    ├── types.zig            Shared Event/KeyEvent/Size/MouseEvent + keycodes
    ├── platform.zig         Comptime platform selector
    ├── linux/
    │   ├── platform.zig     Dual X11/Wayland dispatch
    │   ├── x11.zig          Pure XCB windowing (hand-declared externs)
    │   ├── wayland.zig      xdg-shell + wl_shm (hand-declared externs)
    │   └── keyboard.zig     xkbcommon (live layout switching)
    ├── macos/
    │   ├── platform.zig     AppKit/NSWindow via objc_msgSend
    │   └── keyboard.zig     IOKit keycode tables
    └── windows/
        ├── platform.zig     Win32 window (CreateWindowExW, GDI blit)
        └── keyboard.zig     VK code translation (ToUnicode)
```

### Dependencies

**Runtime** (system libraries):
- `libxcb` -- X11 protocol
- `libxkbcommon` -- keyboard translation (X11 + Wayland)
- `libwayland-client` -- Wayland protocol

**Clipboard** (optional, exec'd at runtime):
- `xclip` -- X11 clipboard
- `wl-clipboard` -- Wayland clipboard (`wl-copy` / `wl-paste`)

**Vendored** (compiled into binary):
- `stb_truetype.h` -- font rasterization (195KB single-header, public domain)
- `xdg-shell-protocol.c` -- Wayland shell protocol (6KB, generated)

No FreeType. No fontconfig. No OpenGL. No EGL. No GTK.

Build with `-Dwayland=false` for X11-only (drops wayland-client dep).
Build with `-Dx11=false` for Wayland-only (drops xcb dep).

---

## Development

```bash
git clone https://github.com/nicholasglazer/teru.git
cd teru

zig build test            # 526+ tests
zig build                 # debug build
zig build run             # run windowed
zig build run -- --raw    # run TTY mode
make release              # release build (1.4MB)
make deps                 # check runtime dependencies
make size                 # compare build profiles
make help                 # list all targets
```

---

## Contributing

Contributions welcome. Requires Zig 0.16.

1. Fork and clone
2. Install Zig 0.16 ([ziglang.org/download](https://ziglang.org/download/) or `paru -S zig-master-bin` on Arch)
3. Install system deps: `libxcb`, `libxkbcommon`, `wayland` (dev packages)
4. `zig build test` to verify setup
5. Make changes, ensure tests pass

### Guidelines

- Run `zig build test` before submitting
- Keep new code covered by inline tests
- One concern per commit, clear messages

### Areas looking for help

- **Full Unicode**: CJK characters, emoji (COLR/CPAL), font fallback chains
- **Shell integration**: bash/zsh/fish scripts for OSC 133 command blocks
- **macOS testing**: AppKit backend and keyboard are implemented but need hardware testing
- **Windows testing**: ConPTY, Win32 window, named pipes IPC — all coded, need hardware testing
- **macOS keyboard**: UCKeyTranslate for international layouts (currently US ANSI only)
- **Windows session listing**: `teru --list` needs FindFirstFileW for pipe enumeration

### Reporting issues

- Include your OS, display server (X11/Wayland), Zig version, and shell
- For rendering bugs, a screenshot helps
- For crashes, stack trace from debug build (`zig build run`)

---

## License

[MIT](LICENSE)
