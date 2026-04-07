<div align="center">

<h1>teru 照</h1>

<p><strong>AI-first terminal emulator, multiplexer, and tiling manager.<br>One binary. No GPU. 1.6MB.</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
  <a href="https://github.com/nicholasglazer/teru/actions"><img src="https://github.com/nicholasglazer/teru/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/zig-0.16-orange" alt="Zig 0.16">
  <img src="https://img.shields.io/badge/tests-445-blue" alt="Tests">
  <img src="https://img.shields.io/badge/binary-1.6MB-brightgreen" alt="Binary Size">
  <a href="https://aur.archlinux.org/packages/teru"><img src="https://img.shields.io/aur/version/teru" alt="AUR"></a>
</p>

<p>
  <a href="#installation">Installation</a> &middot;
  <a href="#features">Features</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="#keybindings">Keybindings</a> &middot;
  <a href="#configuration">Configuration</a> &middot;
  <a href="#ai-integration">AI Integration</a> &middot;
  <a href="#development">Development</a> &middot;
  <a href="#contributing">Contributing</a>
</p>

</div>

---

### Without teru

- tmux panes break when Claude Code spawns agent teams
- 3 config layers (tmux.conf + shell scripts + WM keybindings) that don't compose
- GPU-accelerated terminals waste resources on text rendering
- No terminal understands process relationships or AI agents

### With teru

- Native Claude Code agent team protocol -- agents auto-organize into workspaces
- Single config file, built-in multiplexer, 8 tiling layouts with per-workspace lists
- CPU SIMD rendering at sub-millisecond frame times -- works everywhere, no GPU
- Process graph tracks every process/agent with parent-child relationships

---

## Installation

### Arch Linux (AUR)

```bash
# Install Zig 0.16 (required)
paru -S zig-master-bin

# Install teru
paru -S teru
```

Optional clipboard support:

```bash
# X11
paru -S xclip

# Wayland
paru -S wl-clipboard
```

### Build from source

Requires **Zig 0.16+** and system libraries.

**Dependencies:**

| Package | Arch Linux | Debian/Ubuntu | Fedora |
|---------|------------|---------------|--------|
| Zig 0.16 | `zig-master-bin` (AUR) | [ziglang.org/download](https://ziglang.org/download/) | [ziglang.org/download](https://ziglang.org/download/) |
| libxcb | `libxcb` | `libxcb1-dev` | `libxcb-devel` |
| libxkbcommon | `libxkbcommon` | `libxkbcommon-dev` | `libxkbcommon-devel` |
| wayland | `wayland` | `libwayland-dev` | `wayland-devel` |

```bash
git clone https://github.com/nicholasglazer/teru.git
cd teru

# Release build (recommended)
make release              # 1.6MB binary at zig-out/bin/teru

# Install system-wide
sudo make install         # installs to /usr/local/bin/teru

# Or copy manually
cp zig-out/bin/teru ~/.local/bin/
```

**Minimal builds** (fewer dependencies):

```bash
make release-x11          # X11-only (no wayland-client dep)
make release-wayland      # Wayland-only (no libxcb dep)
```

### Run

```bash
teru                      # windowed mode (X11/Wayland auto-detected)
teru --raw                # TTY mode (over SSH, like tmux)
teru --daemon myproject   # start headless daemon (PTYs persist)
teru --session myproject  # attach to daemon (TTY raw mode)
teru --list               # list active sessions
```

---

## How teru compares

| Feature | teru | Ghostty | Alacritty | WezTerm | Zellij | Warp |
|---------|:----:|:-------:|:---------:|:-------:|:------:|:----:|
| **Binary size** | **1.6MB** | 30MB | 6MB | 25MB | 12MB | 80MB+ |
| **GPU required** | **No** | Yes | Yes | Yes | No | Yes |
| **Built-in multiplexer** | **Yes** | No | No | Yes | Yes | Tabs |
| **Tiling layouts** | **8** | No | No | No | 4 | No |
| **AI agent protocol** | **Yes** | No | No | No | No | Cloud |
| **Process graph** | **Yes** | No | No | No | No | No |
| **Claude Code native** | **Yes** | No | No | No | No | No |
| **MCP server** | **14 tools** | No | No | No | No | No |
| **Session persistence** | **Daemon** | No | No | Yes | Yes | Cloud |
| **Scrollback compression** | **20-50x** | Paged | Ring | Ring | Host | Block |
| **Language** | Zig | Zig | Rust | Rust | Rust | Rust |
| **License** | MIT | MIT | Apache | MIT | MIT | Proprietary |

---

## Features

- **CPU SIMD rendering** -- `@Vector` alpha blending, no GPU, <50us per frame
- **8 tiling layouts** -- master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion
- **Per-workspace layout lists** -- configure which layouts each workspace cycles through (xmonad `|||` pattern)
- **Binary split tree** -- arbitrary horizontal/vertical splits with mouse drag-to-resize
- **9 workspaces** -- switch with prefix + 1-9, each with independent layout and pane list
- **Vi/copy mode** -- prefix + v for vim-like cursor navigation, visual selection, yank to clipboard
- **Session persistence** -- `teru --daemon` starts headless sessions that survive terminal close, `teru --session` reattaches
- **CustomPaneBackend** -- native Claude Code agent team protocol (7 operations)
- **MCP server** -- 14 tools for cross-agent pane control over Unix socket
- **OSC 9999** -- agent self-declaration protocol (start/stop/status/progress)
- **OSC 133** -- shell integration (command blocks, exit code tracking)
- **Process graph** -- DAG of all processes/agents with lifecycle tracking
- **Command-stream scrollback** -- keyframe/delta compression (20-50x vs expanded cells)
- **Unicode fonts** -- ASCII, Latin-1, box-drawing, block elements (351 glyphs via stb_truetype)
- **Keyboard** -- xkbcommon (Linux), IOKit tables (macOS), VK+ToUnicode (Windows); any layout
- **Mouse** -- selection, word double-click, clipboard (X11 via xclip, Wayland via wl-clipboard), drag-to-resize borders
- **Search** -- prefix + / highlights matches in visible grid
- **Themes** -- built-in miozu theme, base16 external theme files, per-color overrides
- **Config file** -- `~/.config/teru/teru.conf`, hot-reload (inotify/kqueue/polling), `include` directive
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
| **Session daemon** | Unix socket | Unix socket (/tmp) | Not yet |
| **MCP server** | Unix socket | Unix socket (/tmp) | Not yet |
| **Hooks listener** | Unix socket | Unix socket | Not yet |
| **Signal handling** | SIGWINCH | SIGWINCH | N/A (message pump) |
| **Build deps** | xcb, xkbcommon, wayland | AppKit, CoreGraphics | user32, gdi32, kernel32 |

**Status:** Linux is production-ready. macOS is feature-complete (needs hardware testing). Windows has all subsystems implemented individually (ConPTY, keyboard, clipboard, window) but the event loop integration is not yet wired — daemon/MCP require named pipes.

---

## Keybindings

Prefix: `Ctrl+Space` (configurable via `prefix_key`). Full reference: [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md)

### Multiplexer

| Key | Action |
|-----|--------|
| prefix + `c` or `\` | Spawn pane (vertical split) |
| prefix + `-` | Spawn pane (horizontal split) |
| prefix + `x` | Close active pane |
| prefix + `n` | Focus next pane |
| prefix + `p` | Focus prev pane |
| prefix + `Space` | Cycle layout |
| prefix + `z` | Toggle zoom (monocle) |
| prefix + `1`-`9` | Switch workspace |
| prefix + `H` / `L` | Shrink / grow master width |
| prefix + `K` / `J` | Shrink / grow master height (dishes) |
| prefix + `v` | Enter vi/copy mode |
| prefix + `/` | Search in terminal output |
| prefix + `d` | Detach (save session, exit) |

### Global Shortcuts (no prefix)

| Key | Action |
|-----|--------|
| `Alt+1`-`9` | Switch workspace |
| `RAlt+1`-`9` | Move active pane to workspace |
| `Alt+J` / `Alt+K` | Focus next / prev pane |
| `RAlt+J` / `RAlt+K` | Swap pane down / up |
| `Alt+C` | New pane (vertical split) |
| `RAlt+C` | New pane (horizontal split) |
| `Alt+X` | Close active pane |
| `Alt+M` | Focus master pane |
| `RAlt+M` | Mark active pane as master |
| `Alt+-` / `Alt+=` | Zoom out / in (font size) |

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

`~/.config/teru/teru.conf` (auto-reloads on change):

```conf
# Appearance
font_size = 16
font_path = /usr/share/fonts/TTF/JetBrainsMono-Regular.ttf
padding = 8
opacity = 0.95
theme = miozu

# Terminal
scrollback_lines = 10000
shell = /usr/bin/fish
cursor_shape = block
cursor_blink = false

# Keybindings
prefix_key = ctrl+space
prefix_timeout_ms = 500

# Window
initial_width = 960
initial_height = 640

# Workspaces with per-workspace layout lists
[workspace.1]
layouts = master-stack, grid, monocle
master_ratio = 0.6
name = code

[workspace.2]
layouts = three-col, columns, spiral
master_ratio = 0.5
name = wide

[workspace.3]
layout = monocle
name = focus

# Hooks
hook_on_spawn = notify-send "teru" "New pane"
hook_on_agent_start = ~/.config/teru/hooks/agent.sh
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

teru exposes 14 tools over Unix socket for agent-to-agent pane control:

```json
{
  "mcpServers": {
    "teru": {
      "command": "socat",
      "args": ["UNIX-CONNECT:/run/user/1000/teru-PID.sock", "STDIO"]
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
├── lib.zig                 libteru C-ABI public API
├── core/
│   ├── Grid.zig            Character grid (cells, cursor, scroll regions, alt-screen)
│   ├── VtParser.zig        VT100/xterm state machine (SIMD fast-path)
│   ├── Pane.zig            PTY+Grid+VtParser per pane
│   ├── Multiplexer.zig     Multi-pane orchestrator + rendering
│   ├── KeyHandler.zig      Prefix key dispatch
│   ├── Selection.zig       Text selection (absolute coords, scrollback-aware)
│   ├── ViMode.zig          Vi/copy mode (cursor navigation, visual selection)
│   ├── Clipboard.zig       Cross-platform clipboard (xclip, pbcopy, Win32 API)
│   ├── Terminal.zig        Raw TTY mode, poll-based I/O
│   └── UrlDetector.zig     URL detection (regex-free)
├── agent/
│   ├── PaneBackend.zig     CustomPaneBackend protocol (Claude Code)
│   ├── McpServer.zig       MCP server (14 tools, Unix socket)
│   ├── HookHandler.zig     Claude Code hook JSON parser
│   ├── HookListener.zig    HTTP hook listener (Unix socket)
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
│   ├── FontAtlas.zig       stb_truetype glyph rasterization (351 glyphs)
│   ├── Compositor.zig      Pane/border/glyph compositing into framebuffer
│   ├── Ui.zig              Status bar, scroll overlay, search overlay
│   └── tier.zig            Two-tier detection (CPU/TTY)
├── config/
│   ├── Config.zig          Config parser + ColorScheme + hot-reload
│   ├── Hooks.zig           External command hooks (fork+exec)
│   └── themes.zig          Built-in theme definitions
├── server/
│   ├── daemon.zig          Headless session daemon (PTY persistence)
│   └── protocol.zig        Wire protocol (5-byte header, Unix socket)
├── pty/
│   ├── Pty.zig              POSIX PTY (posix_openpt, fork, exec)
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
- `stb_truetype.h` -- font rasterization (5KB, public domain)
- `xdg-shell-protocol.c` -- Wayland shell protocol (7KB, generated)

No FreeType. No fontconfig. No OpenGL. No EGL. No GTK.

Build with `-Dwayland=false` for X11-only (drops wayland-client dep).
Build with `-Dx11=false` for Wayland-only (drops xcb dep).

---

## Development

```bash
git clone https://github.com/nicholasglazer/teru.git
cd teru

zig build test            # 445+ tests
zig build                 # debug build
zig build run             # run windowed
zig build run -- --raw    # run TTY mode
make release              # release build (1.6MB)
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
- **Windows daemon**: Named pipes IPC to replace Unix sockets for session persistence
- **macOS keyboard**: UCKeyTranslate for international layouts (currently US ANSI only)

### Reporting issues

- Include your OS, display server (X11/Wayland), Zig version, and shell
- For rendering bugs, a screenshot helps
- For crashes, stack trace from debug build (`zig build run`)

---

## License

[MIT](LICENSE)
