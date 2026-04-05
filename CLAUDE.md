# teru -- AI-first terminal emulator

Written in Zig 0.16+. Uses libc.

## Build
zig build          # build
zig build test     # test
zig build run      # run (windowed)
zig build run -- --raw  # run (TTY mode)

## Architecture
- src/core/ -- VtParser, Grid, Pane, Multiplexer, Selection, KeyHandler, Clipboard, ViMode
- src/pty/ -- PTY management (Linux: posix_openpt/forkpty)
- src/graph/ -- ProcessGraph (DAG of all processes/agents)
- src/agent/ -- OSC 9999 protocol, HookHandler, HookListener, McpServer, PaneBackend
- src/tiling/ -- Layout engine (master-stack, grid, monocle, floating)
- src/persist/ -- Session serialization, binary format
- src/config/ -- Config file parser (key=value format)
- src/render/ -- CPU SIMD renderer, stb_truetype FontAtlas
- src/compat.zig -- Zig 0.16 compat: MemWriter/MemReader, nanoTimestamp, getenv, forkExec
- src/platform/ -- Platform shells: X11+Wayland/Linux, AppKit/macOS, Win32/Windows (planned)

## Key Rules
- Thread `io: std.Io` through every function that does I/O
- See `.claude/skills/zig16.md` for complete Zig 0.16 API reference
- See `.claude/rules/zig-terminal.md` for dev rules, anti-patterns, and perf targets

## Version
Current: 0.2.5. Update in 3 files: `src/main.zig`, `build.zig.zon`, `src/agent/McpServer.zig`

## Testing
All modules have inline tests (370 test blocks). Run with `zig build test`.
