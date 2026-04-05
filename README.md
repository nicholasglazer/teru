<div align="center">

<h1>teru 照</h1>

<p><strong>AI-first terminal emulator, multiplexer, and tiling manager.<br>One binary. No GPU. 1.3MB.</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
  <a href="https://github.com/nicholasglazer/teru/actions"><img src="https://github.com/nicholasglazer/teru/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/zig-0.16-orange" alt="Zig 0.16">
  <img src="https://img.shields.io/badge/tests-370-blue" alt="Tests">
  <img src="https://img.shields.io/badge/binary-1.3MB-brightgreen" alt="Binary Size">
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

- Native Claude Code agent team protocol — agents auto-organize into workspaces
- Single config file, built-in multiplexer, tiling layouts
- CPU SIMD rendering at sub-millisecond frame times — works everywhere, no GPU
- Process graph tracks every process/agent with parent-child relationships

---

## Installation

### Arch Linux (AUR)

```bash
# Install Zig 0.16 (required — teru uses Zig 0.16 APIs)
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
make release              # 1.3MB binary at zig-out/bin/teru

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
teru --attach             # restore saved session layout
```

---

## How teru compares

| Feature | teru | Ghostty | Alacritty | WezTerm | Zellij | Warp |
|---------|:----:|:-------:|:---------:|:-------:|:------:|:----:|
| **Binary size** | **1.3MB** | 30MB | 6MB | 25MB | 12MB | 80MB+ |
| **GPU required** | **No** | Yes | Yes | Yes | No | Yes |
| **Built-in multiplexer** | **Yes** | No | No | Yes | Yes | Tabs |
| **AI agent protocol** | **Yes** | No | No | No | No | Cloud |
| **Process graph** | **Yes** | No | No | No | No | No |
| **Claude Code native** | **Yes** | No | No | No | No | No |
| **Cross-agent messaging** | **Yes** | No | No | No | No | No |
| **Scrollback compression** | **20-50x** | Paged | Ring | Ring | Host | Block |
| **Language** | Zig | Zig | Rust | Rust | Rust | Rust |
| **License** | MIT | MIT | Apache | MIT | MIT | Proprietary |

---

## Features

- **CPU SIMD rendering** — `@Vector` alpha blending, no GPU, <50μs per frame
- **Multiplexer** — multi-pane, master-stack/grid/monocle/floating layouts, 9 workspaces
- **CustomPaneBackend** — native Claude Code agent team protocol (7 operations)
- **MCP server** — 10 tools for cross-agent communication over Unix socket
- **OSC 9999** — agent self-declaration protocol (start/stop/status/progress)
- **OSC 133** — shell integration (command blocks, exit code tracking)
- **Process graph** — DAG of all processes/agents with lifecycle tracking
- **Command-stream scrollback** — keyframe/delta compression (20-50x vs expanded cells)
- **Session save/restore** — binary serialization, resume layout with `--attach`
- **Unicode fonts** — ASCII, Latin-1, box-drawing, block elements (351 glyphs via stb_truetype)
- **Keyboard** — xkbcommon, any layout (dvorak, colemak, etc.), reads live X11 keymap
- **Mouse** — selection, clipboard (X11 via xclip, Wayland via wl-clipboard), Ctrl+click opens URLs
- **Search** — `Ctrl+Space, /` highlights matches in visible grid
- **Scrollback browsing** — `Shift+PageUp/Down`, visual indicator
- **Config file** — `~/.config/teru/teru.conf`, 14 keys, hex colors
- **Hook system** — external commands on spawn/close/agent/save events
- **Alt-screen** — vim, htop, less work correctly (dual cell buffers)
- **VT compatibility** — CSI, SGR (256 + truecolor), DCS passthrough, DECSCUSR cursor styles
- **Cross-platform** — X11 (XCB), Wayland (xdg-shell), macOS (AppKit stub), Windows (Win32 stub)

---

## Keybindings

Prefix: `Ctrl+Space`

| Key | Action |
|-----|--------|
| `c` | Spawn new pane |
| `x` | Close active pane |
| `n` | Focus next pane |
| `p` | Focus prev pane |
| `Space` | Cycle layout (master-stack → grid → monocle → floating) |
| `1`-`9` | Switch workspace |
| `/` | Search in terminal output |
| `d` | Detach (save session, exit) |

| Key | Action |
|-----|--------|
| `Shift+PageUp` | Scroll up one page |
| `Shift+PageDown` | Scroll down one page |
| Any key | Exit scroll mode |
| `Ctrl+Click` | Open URL under cursor |

---

## Configuration

`~/.config/teru/teru.conf`:

```conf
# Appearance
font_size = 14
font_path = /usr/share/fonts/TTF/Hack-Regular.ttf
bg = #1D1D23
fg = #FAF8FB
cursor_color = #FF9922

# Terminal
scrollback_lines = 50000
shell = /usr/bin/fish

# Window
initial_width = 1200
initial_height = 800

# Hooks (external commands on events)
hook_on_spawn = notify-send "teru" "New pane"
hook_on_agent_start = ~/.config/teru/hooks/agent.sh
```

Default theme: [miozu](https://miozu.com) base16 color scheme.

---

## AI Integration

### Claude Code Agent Teams

teru implements the CustomPaneBackend protocol (Claude Code issue #26572). When Claude Code spawns agent teams, teru manages the panes natively — no tmux.

```bash
# Set automatically by teru:
export CLAUDE_PANE_BACKEND_SOCKET=/run/user/1000/teru-pane-backend.sock

# Claude Code sends JSON-RPC:
{"method":"spawn","params":{"argv":["claude","--agent","backend-dev"],"metadata":{"group":"team-temporal"}}}

# teru creates a pane, adds to ProcessGraph, auto-assigns workspace
```

### MCP Server

teru exposes itself as an MCP server. Multiple Claude Code instances can query each other:

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

**Tools:**

| Tool | Description |
|------|-------------|
| `teru_list_panes` | List all panes with id, workspace, status |
| `teru_read_output` | Get recent N lines from any pane |
| `teru_get_graph` | Full process graph as JSON |
| `teru_send_input` | Type into any pane's PTY |
| `teru_create_pane` | Spawn a new pane |
| `teru_broadcast` | Send text to all panes in a workspace |

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
├── main.zig                Entry point, event loop, prefix keys
├── compat.zig              Zig 0.16 compatibility (time, fork helpers)
├── lib.zig                 libteru C-ABI public API
├── core/
│   ├── Grid.zig            Character grid (cells, cursor, scroll regions, alt-screen)
│   ├── VtParser.zig        VT100/xterm state machine (SIMD fast-path)
│   ├── Pane.zig            PTY+Grid+VtParser per pane
│   ├── Multiplexer.zig     Multi-pane orchestrator + rendering
│   ├── KeyHandler.zig      Prefix key dispatch
│   ├── Selection.zig       Text selection state machine
│   ├── Clipboard.zig       Display-aware clipboard (xclip / wl-clipboard)
│   ├── Terminal.zig        Raw TTY mode, poll-based I/O
│   └── UrlDetector.zig     URL detection (regex-free)
├── agent/
│   ├── PaneBackend.zig     CustomPaneBackend protocol (Claude Code)
│   ├── McpServer.zig       MCP server (10 tools, Unix socket)
│   ├── HookHandler.zig     Claude Code hook JSON parser
│   └── protocol.zig        OSC 9999 agent protocol parser
├── graph/
│   └── ProcessGraph.zig    Process DAG (nodes, edges, agent metadata)
├── tiling/
│   └── LayoutEngine.zig    4 layouts, 9 workspaces, swap layouts
├── persist/
│   ├── Session.zig         Binary serialization (save/restore)
│   └── Scrollback.zig      Command-stream compression (keyframe/delta)
├── render/
│   ├── software.zig        CPU SIMD renderer (@Vector alpha blending)
│   ├── FontAtlas.zig       stb_truetype glyph rasterization (351 glyphs)
│   ├── tier.zig            Two-tier detection (CPU/TTY)
│   └── render.zig          Module index
├── config/
│   ├── Config.zig          ~/.config/teru/teru.conf parser
│   └── Hooks.zig           External command hooks (fork+exec)
└── platform/
    ├── types.zig            Shared Event/KeyEvent/Size/MouseEvent
    ├── platform.zig         Comptime platform selector
    └── linux/
        ├── platform.zig     Dual X11/Wayland dispatch
        ├── x11.zig          Pure XCB windowing (hand-declared externs)
        ├── wayland.zig      xdg-shell + wl_shm (hand-declared externs)
        └── keyboard.zig     xkbcommon (live X11 keymap query)
```

### Dependencies

**Runtime** (system libraries):
- `libxcb` — X11 protocol
- `libxkbcommon` — keyboard translation (X11 + Wayland)
- `libwayland-client` — Wayland protocol

**Clipboard** (optional, exec'd at runtime):
- `xclip` — X11 clipboard
- `wl-clipboard` — Wayland clipboard (`wl-copy` / `wl-paste`)

**Vendored** (compiled into binary):
- `stb_truetype.h` — font rasterization (5KB, public domain)
- `xdg-shell-protocol.c` — Wayland shell protocol (7KB, generated)

No FreeType. No fontconfig. No OpenGL. No EGL. No GTK.

Build with `-Dwayland=false` for X11-only (drops wayland-client dep).
Build with `-Dx11=false` for Wayland-only (drops xcb dep).

---

## Development

```bash
git clone https://github.com/nicholasglazer/teru.git
cd teru

# Requires Zig 0.16-dev
make dev                  # debug build (~4MB, full safety + debug symbols)
make test                 # 370 tests
make run                  # build and run
make release              # release build (1.3MB)
make deps                 # check runtime dependencies
make size                 # compare build profiles
make help                 # list all targets
```

Or use `zig build` directly:

```bash
zig build test                           # run tests
zig build                                # debug build
zig build run                            # run windowed
zig build run -- --raw                   # run TTY mode
zig build -Doptimize=ReleaseSafe         # release build
zig build -Doptimize=ReleaseSafe -Dwayland=false  # X11-only release
```

250 tests covering: VT parser, grid, tiling engine, scrollback compression, session serialization, agent protocol, process graph, URL detection, font atlas, software renderer.

---

## Contributing

Contributions are welcome. teru is written in Zig 0.16-dev — make sure you have the right version installed.

### Getting started

1. Fork and clone the repo
2. Install Zig 0.16-dev ([ziglang.org/download](https://ziglang.org/download/) or `paru -S zig-master-bin` on Arch)
3. Install system deps: `libxcb`, `libxkbcommon`, `wayland` (dev packages)
4. Run `make test` to verify your setup
5. Make your changes and ensure all tests pass

### Guidelines

- Run `make test` before submitting
- Keep new code covered by inline tests where practical
- Follow existing code style (4-space indent, Zig conventions)
- One concern per commit, clear commit messages

### Areas looking for help

- **Full Unicode**: CJK characters, emoji (COLR/CPAL), font fallback chains
- **Shell integration**: bash/zsh/fish scripts for OSC 133 command blocks
- **Detach/attach**: daemon mode for persistent sessions across terminal restarts
- **Wayland keyboard**: proper xkbcommon keymap from compositor FD (currently raw passthrough)
- **macOS**: fix AppKit backend for Zig 0.16, PTY via forkpty, keyboard via Carbon
- **Windows**: ConPTY implementation, Win32 keyboard translation
- **Testing**: integration tests for platform backends

### Reporting issues

- Include your OS, display server (X11/Wayland), Zig version, and shell
- For rendering bugs, a screenshot or terminal recording helps
- For crashes, the stack trace from a debug build (`make dev && zig-out/bin/teru`)

---

## License

[MIT](LICENSE)
