# Show HN: Teru – AI-first terminal emulator in Zig, no GPU, 1.3MB

**Link:** https://github.com/nicholasglazer/teru

---

**Top comment:**

I built teru because I was running Claude Code with agent teams (multiple AI agents working in parallel), and they kept destroying my tmux layouts. Every time an agent spawned 4-5 subprocesses, tmux would split into unusable fragments. I was managing 3 config layers (tmux.conf + shell scripts + xmonad keybindings) just to keep terminal panes organized.

teru is a terminal emulator, multiplexer, and tiling manager in a single 1.3MB binary. Written in Zig 0.16, CPU SIMD rendering via @Vector, no GPU/OpenGL/EGL required. Frame times under 50μs.

What makes it different from Ghostty/Alacritty/WezTerm:

**AI-native architecture.** teru implements Claude Code's CustomPaneBackend protocol — when Claude spawns agent teams, teru manages the panes natively instead of shelling out to tmux. There's also an MCP server (6 tools over Unix socket) so multiple Claude instances can query each other's terminal output, and an OSC 9999 protocol where any process can self-declare as an AI agent with progress tracking.

**Process graph.** Every process gets tracked in a DAG with parent-child relationships and agent metadata. You can query "which agents are running, what's their status" programmatically. Pane borders color-code by agent status (cyan=running, green=done, red=failed).

**Command-stream scrollback.** Instead of storing expanded character cells in a ring buffer, teru stores VT byte streams with keyframe/delta compression. 20-50x compression ratio vs traditional scrollback. A 50,000-line scrollback that would cost ~150MB in a traditional terminal costs ~3-7MB.

**Built-in multiplexer.** 4 tiling layouts (master-stack, grid, monocle, floating), 9 workspaces, Ctrl+Space prefix keys. Replaces tmux for my workflow.

**No GPU by design.** I benchmarked the GPU path early on — for terminal rendering (text on a grid), the GPU is idle 99.9% of the time. SIMD @Vector blitting on CPU is faster for this workload and works everywhere: SSH sessions, VMs, containers, cheap VPS with no GPU.

Technical details:

- ~16K lines of Zig, 250 tests
- Pure XCB for X11 (hand-declared externs, no Xlib), Wayland via xdg-shell
- stb_truetype for fonts (vendored, no FreeType/fontconfig)
- Only 3 runtime deps: libxcb, libxkbcommon, wayland-client
- VT100/xterm state machine with SIMD fast-path for plain text
- macOS (AppKit) and Windows (Win32) platform stubs exist but aren't functional yet

This is v0.1.1 — it works as my daily driver on X11. Wayland works but keyboard handling is still raw passthrough (proper xkbcommon integration from compositor keymap FD is pending). Missing: full Unicode (emoji/CJK), shell integration scripts, detach/attach daemon mode, plugin system.

Available on AUR: `paru -S teru` (requires Zig 0.16-dev to build).

I'd love feedback on the architecture, especially the agent protocol design. The AI-terminal integration space is wide open and I think there are better primitives than what we have today.
