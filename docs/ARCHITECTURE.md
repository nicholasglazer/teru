# Architecture

teru is structured as a single-binary terminal emulator, multiplexer, and tiling manager.

## Module Map

```
src/
  main.zig              Event loop, window management, input dispatch
  compat.zig            Minimal Zig 0.16 compatibility (4 things only)
  lib.zig               Library root (imports all modules for testing)

  core/
    VtParser.zig         VT100/xterm byte-at-a-time state machine
    Grid.zig             Character cell grid (rows x cols flat array)
    Pane.zig             PTY + Grid + VtParser bundle
    Multiplexer.zig      Multi-pane management, rendering dispatch
    Selection.zig        Text selection (mouse drag, copy)
    KeyHandler.zig       Prefix key commands (split, close, navigate)
    Clipboard.zig        System clipboard (xclip/wl-copy integration)

  render/
    software.zig         CPU SIMD renderer (@Vector(4, u32) pixel blitting)
    Compositor.zig       Pane rendering, borders, glyph blitting
    Ui.zig               Search bar, status bar, scroll overlay
    FontAtlas.zig        stb_truetype glyph rasterization

  pty/
    Pty.zig              PTY lifecycle (posix_openpt, fork, exec)

  agent/
    protocol.zig         OSC 9999 agent protocol definitions
    HookHandler.zig      Claude Code hook event JSON parser
    HookListener.zig     Unix socket HTTP listener for hook events
    McpServer.zig        MCP server (JSON-RPC over Unix socket)
    PaneBackend.zig      Custom pane backend protocol (7 operations)

  graph/
    ProcessGraph.zig     DAG of processes/agents with state tracking

  tiling/
    LayoutEngine.zig     Layout algorithms (master-stack, grid, monocle, floating)

  persist/
    Session.zig          Binary session serialization
    Scrollback.zig       Keyframe + delta scrollback compression

  config/
    Config.zig           Config parser + ColorScheme (base16)

  platform/
    linux/
      platform.zig       Dual backend selector (X11 or Wayland)
      x11.zig            X11 via XCB + SHM
      wayland.zig         Wayland via xdg-shell
      keyboard.zig       xkbcommon keyboard translation
    macos/               macOS AppKit (planned)
    windows/             Win32 (planned)
```

## Data Flow

```
Input:  X11/Wayland events -> main.zig -> KeyHandler -> PTY write
Output: PTY read -> VtParser -> Grid -> SoftwareRenderer -> framebuffer -> X11/Wayland
Agent:  Hook events -> HookListener -> ProcessGraph
        MCP requests -> McpServer -> Multiplexer
        OSC 9999 -> VtParser -> ProcessGraph
```

## Key Invariants

- Grid cursor is always in bounds: `0 <= row < rows`, `0 <= col < cols`
- Zero allocations in the render hot path
- All colors flow from `ColorScheme` (base16, configurable)
- `io: std.Io` threaded through every I/O function
- VtParser is pure computation (no I/O, no allocation)
