//! libteru — AI-first terminal emulator core library.
//!
//! This is the kernel of teru: a C-ABI compatible library containing
//! all platform-independent terminal emulation logic.
//!
//! Modules:
//!   pty      — Pseudoterminal management (spawn, read, write, resize)
//!   graph    — Process graph (DAG of all processes/agents)
//!   agent    — Agent protocol parser (OSC 9999) and MCP bridge
//!   core     — Terminal state, raw mode, I/O loop
//!   tiling   — Layout engine (master-stack, grid, monocle, floating)
//!   config   — Configuration file parser and plugin hooks
//!   persist  — Session serialization and scrollback compression

pub const Pty = @import("pty/Pty.zig");
pub const ProcessGraph = @import("graph/ProcessGraph.zig");
pub const protocol = @import("agent/protocol.zig");
pub const HookHandler = @import("agent/HookHandler.zig");
pub const McpServer = @import("agent/McpServer.zig");
pub const PaneBackend = @import("agent/PaneBackend.zig");
pub const HookListener = @import("agent/HookListener.zig");
pub const Terminal = @import("core/Terminal.zig");
pub const Grid = @import("core/Grid.zig");
pub const VtParser = @import("core/VtParser.zig");
pub const Pane = @import("core/Pane.zig");
pub const Multiplexer = @import("core/Multiplexer.zig");
pub const Selection = @import("core/Selection.zig");
pub const Clipboard = @import("core/Clipboard.zig");
pub const KeyHandler = @import("core/KeyHandler.zig");
pub const SignalManager = @import("core/SignalManager.zig");
pub const UrlDetector = @import("core/UrlDetector.zig");
pub const Session = @import("persist/Session.zig");
pub const Scrollback = @import("persist/Scrollback.zig");
pub const LayoutEngine = @import("tiling/LayoutEngine.zig");
pub const Workspace = @import("tiling/Workspace.zig");
pub const render = @import("render/render.zig");
pub const Compositor = @import("render/Compositor.zig");
pub const Ui = @import("render/Ui.zig");
pub const Config = @import("config/Config.zig");
pub const Hooks = @import("config/Hooks.zig");
pub const WinPty = @import("pty/WinPty.zig");
pub const compat = @import("compat.zig");

test {
    _ = Pty;
    _ = ProcessGraph;
    _ = protocol;
    _ = HookHandler;
    _ = McpServer;
    _ = PaneBackend;
    _ = HookListener;
    _ = Terminal;
    _ = Grid;
    _ = VtParser;
    _ = Pane;
    _ = Multiplexer;
    _ = Selection;
    _ = Clipboard;
    _ = KeyHandler;
    _ = SignalManager;
    _ = UrlDetector;
    _ = Session;
    _ = Scrollback;
    _ = LayoutEngine;
    _ = Workspace;
    _ = render;
    _ = Config;
    _ = Hooks;
    _ = WinPty;
}
