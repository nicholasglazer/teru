# Architecture

teru is a single-binary terminal emulator, multiplexer, and tiling manager. See the [README](../README.md#architecture) for the full source tree and module descriptions.

## Data Flow

```
Input:  X11/Wayland/AppKit/Win32 events -> main.zig -> KeyHandler -> PTY write
Output: PTY read -> VtParser -> Grid -> SoftwareRenderer -> framebuffer -> display
Agent:  Hook events -> HookListener -> ProcessGraph
        MCP requests -> McpServer -> Multiplexer
        OSC 9999 -> VtParser -> ProcessGraph
        CustomPaneBackend -> PaneBackend -> Multiplexer
```

## Key Invariants

- Grid cursor is always in bounds: `0 <= row < rows`, `0 <= col < cols`
- Zero allocations in the render hot path
- All colors flow from `ColorScheme` (base16, configurable)
- `io: std.Io` threaded through every I/O function
- VtParser is pure computation (no I/O, no allocation)
- CSI params capped at 16; overflow stops collecting, never crashes
- OSC strings bounded; overflow truncates, never crashes

## Platform Support

| Platform | Display | PTY | Keyboard | Status |
|----------|---------|-----|----------|--------|
| Linux | X11 (XCB+SHM) + Wayland (xdg-shell) | posix_openpt + fork | xkbcommon (any layout) | Production |
| macOS | AppKit (NSWindow + objc_msgSend) | posix_openpt + fork | IOKit tables (US ANSI) | Feature-complete, needs testing |
| Windows | Win32 (CreateWindowExW + GDI) | ConPTY (CreatePseudoConsole) | VK + ToUnicode (any layout) | Feature-complete, needs testing |
