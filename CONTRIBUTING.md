# Contributing to teru

Contributions welcome. teru is written in Zig 0.16.

## Setup

```bash
# 1. Install Zig 0.16
#    https://ziglang.org/download/
#    Arch: paru -S zig-master-bin

# 2. Install system deps (Linux)
#    Arch: pacman -S libxcb libxkbcommon wayland
#    Debian: apt install libxcb1-dev libxkbcommon-dev libwayland-dev

# 3. Clone and verify
git clone https://github.com/nicholasglazer/teru.git
cd teru
zig build test            # 480+ tests must pass
zig build run             # windowed mode
zig build run -- --raw    # TTY mode
```

## Development workflow

```bash
zig build test            # run all inline tests (fast, ~2s)
zig build                 # debug build
zig build run             # run windowed (X11/Wayland auto-detected)
make release              # release build (1.4MB stripped)
```

Every `.zig` module has inline `test` blocks. No separate test files. When adding code, add tests in the same file.

## Guidelines

- **Tests first**: `zig build test` must pass before submitting
- **Inline tests**: add `test "descriptive name" { ... }` blocks in the same module
- **One concern per commit**: clear, concise messages
- **No new dependencies**: no Zig packages, no new system libs without discussion
- **Thread `io: std.Io`**: every function that does I/O takes an `io` parameter
- **No allocations in render**: the render hot path is pre-allocated

## Code style

- Follow existing patterns in the codebase
- Use `std.testing.allocator` in tests (catches leaks automatically)
- Prefer hand-declared C externs over `@cImport`
- See `.claude/rules/zig-terminal.md` for Zig 0.16 API reference

## Areas looking for help

### Full Unicode
CJK characters, emoji (COLR/CPAL), font fallback chains. Currently ASCII, Latin-1, Cyrillic, box-drawing, block elements (607 glyphs). Requires extending FontAtlas.zig with multi-font support.

### Shell integration
bash/zsh/fish scripts for OSC 133 command blocks (prompt marking, exit code tracking). See `src/agent/protocol.zig` for the OSC parser.

### macOS testing
AppKit backend and keyboard are implemented (`src/platform/macos/`) but need testing on real hardware. Currently uses IOKit static tables (US ANSI only) -- needs UCKeyTranslate for international layouts.

### Windows testing
ConPTY, Win32 window, named pipes IPC -- all coded (`src/platform/windows/`, `src/pty/WinPty.zig`), need testing on real hardware. Session listing (`teru --list`) needs FindFirstFileW for pipe enumeration.

### Benchmarks
Measuring and publishing frame render times, scrollback memory usage, startup time, and input latency vs other terminals.

### Documentation
Writing getting-started guides, MCP integration docs, layout visual showcase.

## Reporting issues

Include:
- OS, display server (X11/Wayland), Zig version, shell
- For rendering bugs: screenshot
- For crashes: stack trace from debug build (`zig build run`)

## License

By contributing, you agree your contributions are licensed under [MIT](LICENSE).
