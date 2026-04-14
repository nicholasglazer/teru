//! teruwm — Wayland compositor built on libteru + wlroots.
//!
//! Entry point for the compositor binary. Loads config from teru.conf,
//! creates the Server (which initializes wlroots), starts the backend,
//! and runs the event loop.
//!
//! Supports --restore for zero-downtime restart: PTY fds survive exec(),
//! shells keep running. Like xmonad --restart but for Wayland.

const std = @import("std");
const teru = @import("teru");
const Config = teru.Config;
const Pty = teru.Pty;
const Pane = teru.Pane;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");

const restart_state_path = "/tmp/teruwm-restart.bin";

/// Custom panic handler: print "teruwm: PANIC <msg>" + a stack trace
/// before aborting. Without this, segfaults look like clean exits in
/// the log and we waste hours debugging "why did teruwm just vanish?"
pub const panic = std.debug.FullPanic(panicHandler);
fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("\nteruwm: PANIC {s}\n", .{msg});
    const addr = first_trace_addr orelse @returnAddress();
    std.debug.dumpCurrentStackTrace(.{ .first_address = addr });
    std.process.exit(134);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // ── Check for --restore flag ───────────────────────────────
    var restoring = false;
    {
        var it = init.minimal.args.iterate();
        _ = it.next(); // skip argv[0]
        while (it.next()) |arg| {
            if (std.mem.eql(u8, std.mem.sliceTo(arg, 0), "--restore")) restoring = true;
        }
    }

    // ── Load config from ~/.config/teru/teru.conf ──────────────
    const config = Config.load(allocator, io) catch Config{ .allocator = allocator };

    // ── Create Wayland display ──────────────────────────────────
    const display = wlr.wl_display_create() orelse {
        std.debug.print("teruwm: failed to create wl_display\n", .{});
        return error.DisplayCreateFailed;
    };
    defer wlr.wl_display_destroy(display);

    const event_loop = wlr.wl_display_get_event_loop(display) orelse {
        std.debug.print("teruwm: failed to get event loop\n", .{});
        return error.EventLoopFailed;
    };

    // ── Initialize compositor server ────────────────────────────
    const server = Server.initOnHeap(display, event_loop, allocator) catch |err| {
        std.debug.print("teruwm: server init failed: {}\n", .{err});
        return err;
    };
    defer server.deinit();

    // ── Apply config to server ──────────────────────────────────
    server.applyConfig(&config, allocator, io);

    // ── Add Wayland socket ──────────────────────────────────────
    const socket = wlr.wl_display_add_socket_auto(display);
    if (socket == null) {
        std.debug.print("teruwm: failed to add Wayland socket\n", .{});
        return error.SocketFailed;
    }

    // ── Start backend ───────────────────────────────────────────
    if (!wlr.wlr_backend_start(server.backend)) {
        std.debug.print("teruwm: failed to start backend\n", .{});
        return error.BackendStartFailed;
    }

    // Set environment for child processes
    if (socket) |sock| {
        _ = wlr.setenv("WAYLAND_DISPLAY", sock, 1);
    }

    // ── Restore session from restart ───────────────────────────
    if (restoring) {
        restoreSession(server, allocator);
        // Don't re-run autostart on hot-restart: the clients it would
        // spawn are still connected from the previous compositor.
        server.autostart_fired = true;
    }

    // ── Start MCP server for compositor control ────────────────
    server.startMcp();

    std.debug.print("teruwm: compositor running on WAYLAND_DISPLAY={s}\n", .{
        socket orelse "unknown",
    });

    // ── Run event loop ──────────────────────────────────────────
    wlr.wl_display_run(display);

    std.debug.print("teruwm: shutting down\n", .{});
}

/// Restore terminal panes from a restart state file.
/// PTY master fds were inherited across exec() — shells are still running.
fn restoreSession(server: *Server, allocator: std.mem.Allocator) void {
    // Read state file
    var buf: [4096]u8 = undefined;
    const file = std.c.fopen(restart_state_path, "rb") orelse {
        std.debug.print("teruwm: no restart state found\n", .{});
        return;
    };
    const n = std.c.fread(&buf, 1, buf.len, file);
    _ = std.c.fclose(file);

    // Delete state file (one-shot restore)
    _ = std.c.unlink(restart_state_path);

    if (n < 13) return; // too small

    var pos: usize = 0;

    // Header
    const pane_count = std.mem.readInt(u16, buf[pos..][0..2], .little);
    pos += 2;
    const active_ws = buf[pos];
    pos += 1;

    // Per-workspace layouts
    for (0..10) |wi| {
        if (pos < n) {
            server.layout_engine.workspaces[wi].layout = @enumFromInt(buf[pos]);
            pos += 1;
        }
    }

    std.debug.print("teruwm: restoring {d} panes (active ws={d})\n", .{ pane_count, active_ws });

    // Restore each pane
    var restored: u16 = 0;
    for (0..pane_count) |_| {
        if (pos + 13 > n) break;

        const ws = buf[pos]; pos += 1;
        const pty_fd = std.mem.readInt(i32, buf[pos..][0..4], .little); pos += 4;
        const rows = std.mem.readInt(u16, buf[pos..][0..2], .little); pos += 2;
        const cols = std.mem.readInt(u16, buf[pos..][0..2], .little); pos += 2;
        const pid = std.mem.readInt(i32, buf[pos..][0..4], .little); pos += 4;

        if (pty_fd < 0) continue;

        // Create a Pane that attaches to the existing PTY fd
        const pty = Pty.attach(pty_fd, if (pid >= 0) @intCast(pid) else null);
        const spawn_config = Pane.SpawnConfig{};
        var pane = Pane.initWithPty(allocator, rows, cols, server.next_node_id, spawn_config, pty) catch continue;
        _ = &pane;

        // Create TerminalPane around it
        const tp = TerminalPane.createRestored(server, ws, &pane) orelse continue;
        _ = tp;

        server.next_node_id += 1;
        restored += 1;
    }

    // Switch to the active workspace
    server.layout_engine.switchWorkspace(active_ws);
    server.setWorkspaceVisibility(active_ws, true);
    server.arrangeworkspace(active_ws);
    server.updateFocusedTerminal();
    if (server.bar) |b| b.render(server);

    std.debug.print("teruwm: restored {d}/{d} panes\n", .{ restored, pane_count });
}
