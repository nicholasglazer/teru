<div align="center">

# teru

**A terminal emulator and a Wayland compositor, written in Zig. No GPU, no FreeType, no fontconfig.
Designed around an MCP control plane so AI agents and shell scripts can drive both as easily as a user can.**

<a href="https://teru.sh">teru.sh</a>
 · <a href="#install">install</a>
 · <a href="#quickstart">quickstart</a>
 · <a href="docs/BENCHMARKS.md">benchmarks</a>
 · <a href="docs/ARCHITECTURE.md">architecture</a>
 · <a href="docs/MCP-API.md">mcp api</a>

<sub>Zig 0.16 · Linux · macOS · Windows · MIT · <a href="docs/AI-INTEGRATION.md">AI integration</a></sub>

</div>

---

## What's in the box

| Binary | What it is | Size (ReleaseFast) |
|---|---|---:|
| `teru` | Terminal emulator, multiplexer, tiling manager, session daemon | **6.6 MB** |
| `teruwm` | Wayland compositor (wlroots) built on libteru | **5.6 MB** |

One source tree (`src/`), two artifacts. Both share the libteru library: VT parser, grid, SIMD software renderer,
layout engine, 43-tool MCP control plane.

## Why

Most terminals, multiplexers, and tiling WMs are three programs glued with config files. Every layer
— tmux for panes, alacritty for pixels, sway for windows — speaks its own API, and none of them
let an external process reliably script "open a new pane running X on workspace 3, focus it, read
its output". teru bundles the three concerns into one codebase that exposes every capability over
a JSON-RPC socket, so a Python script or an AI agent can do things you'd otherwise need a
human with a keyboard for.

**Concrete differentiators** (things no other terminal or compositor has):

- **MCP control plane.** 19 tools for the terminal, 24 tools for the compositor. Every feature
  that has a keybind also has a tool. [docs/MCP-API.md](docs/MCP-API.md).
- **Push widgets.** External daemons register `{widget:name}` entries in the bar and push updates
  via MCP — event-driven, no polling. [docs/AI-INTEGRATION.md](docs/AI-INTEGRATION.md#push-widgets).
- **Hot restart.** `Mod+Ctrl+Shift+R` exec()s a freshly compiled teruwm; PTY fds survive the
  exec so your shells don't blink. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#hot-restart).
- **CPU-only SIMD renderer.** `@Vector(4, u32)` alpha blending. Works over SSH, in VMs, in
  containers, on machines with no GPU driver loaded. [docs/BENCHMARKS.md](docs/BENCHMARKS.md).
- **Process graph.** Every pane, every agent, every child process is a node in a DAG the MCP
  can query. OSC 9999 lets any process self-declare as an AI agent.
- **Single statically-linked binary per platform.** No Python, no Node, no Electron.

## Install

```bash
# Arch Linux (AUR)
paru -S teru                         # builds teru; teruwm is a separate -git package

# macOS
brew install nicholasglazer/teru/teru

# Windows
scoop bucket add teru https://github.com/nicholasglazer/scoop-teru
scoop install teru

# From source (any platform)
git clone https://github.com/nicholasglazer/teru.git && cd teru
zig build -Doptimize=ReleaseFast                     # → zig-out/bin/teru
zig build -Doptimize=ReleaseFast -Dcompositor        # → zig-out/bin/teruwm   (Linux only)
```

Details for every platform: [docs/INSTALLING.md](docs/INSTALLING.md).

## Quickstart

### Running the terminal

```bash
teru                                 # windowed, X11/Wayland auto-detected
teru -n work                         # named persistent session (auto-starts daemon)
teru --raw                           # over SSH — no windowing, full VT support
teru -e htop                         # run a specific command instead of the shell
teru --mcp-server                    # stdio MCP proxy (alias: --mcp-bridge)
```

Keybinds (Alt is the mod): `Alt+Enter` new pane, `Alt+J/K` focus, `Alt+1..9` workspace,
`Alt+Space` cycle layout, `Alt+X` close. Full list: [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md).

### Running the compositor

`teruwm` replaces `sway`/`hyprland`/`river`. It's a full Wayland compositor — you launch it from a
TTY, not from inside another session. It ships `teru` as its native terminal but also runs any
Wayland or XWayland client (Chromium, Emacs, Figma, etc. — all verified).

```bash
# From a TTY:
teruwm
# Inside teruwm, Mod defaults to Super (the Windows/Command key):
#   Mod+Enter     new terminal pane
#   Mod+1..9      workspace
#   Mod+B         toggle top bar
#   Mod+Shift+B   toggle bottom bar
#   Mod+Drag      grab a tiled pane with the cursor → it becomes floating
#   Mod+X         close pane or client window
#   Mod+Shift+R         reload config
#   Mod+Ctrl+Shift+R    hot-restart compositor (PTYs survive)
```

Keybinds: [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md). Config: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Performance

Numbers measured on a Core Ultra 9 185H with ReleaseFast. Full methodology, distribution
(p50/p95/p99), and peer comparisons in [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

| Metric | Value |
|---|---:|
| `teru` binary size | 6.6 MB |
| `teruwm` binary size | 5.6 MB |
| `teru --help` startup (p50) | 0.73 ms |
| VtParser throughput, `dense_cells` | 401 MB/s |
| Full pipeline (parse + render), `dense_cells` | 391 MB/s |

Single-number marketing claims are explicitly avoided — see the BENCHMARKS doc for why and
what's not measured.

## Docs

Everything user-facing lives in `docs/`. Concept-by-concept:

- [docs/INSTALLING.md](docs/INSTALLING.md) — platform-specific build + package manager install
- [docs/KEYBINDINGS.md](docs/KEYBINDINGS.md) — every default keybind for teru and teruwm, prefix/scroll/vi modes, mouse
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — `teru.conf`, `teruwm/config`, bar widgets, thresholds, window rules
- [docs/AI-INTEGRATION.md](docs/AI-INTEGRATION.md) — MCP protocol, CustomPaneBackend, OSC 9999, push widgets, session templates
- [docs/MCP-API.md](docs/MCP-API.md) — 43-tool reference: both servers, every tool's schema and example
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — source tree, wlroots integration, scene graph, hot restart
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — methodology, results, planned follow-ups

## Status

| Area | Status |
|---|---|
| teru terminal, Linux (X11 + Wayland) | production; 472 inline tests |
| teru terminal, macOS (AppKit) | feature-complete, needs hardware testing; US ANSI keyboard only |
| teru terminal, Windows (Win32 + ConPTY) | all subsystems wired; needs hardware testing |
| teruwm compositor, Linux (wlroots) | usable; XDG + XWayland verified with Chromium / Emacs / Figma |
| Session persistence (`-n NAME`) | production |
| MCP (43 tools) | production; E2E suite covers every tool |
| Hot restart | production; shells survive exec |
| Push widgets | production |
| Keypress-to-photon latency numbers | waiting on phototransistor rig — deliberately not published until measured in hardware |

## Contributing

```bash
git clone https://github.com/nicholasglazer/teru.git && cd teru
zig build test                        # 472+ inline tests
zig build -Dcompositor                # compositor build (Linux)
bash tools/run-bench.sh               # regression benchmarks
```

One concern per commit; inline tests for new behavior; keep the benchmark numbers in
[BENCHMARKS.md](docs/BENCHMARKS.md) current if you change the hot path. Areas where help is most
useful: full Unicode (CJK + emoji + font fallback), macOS/Windows hardware testing,
wp_presentation_time export for compositor frame jitter metrics.

## License

MIT.
