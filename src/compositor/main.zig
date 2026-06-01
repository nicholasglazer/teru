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
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const ServerRestart = @import("ServerRestart.zig");

// Env-gated logging (TERU_LOG=debug|info|warn|err). TERU_LOG=debug captures the
// full teruwm MCP trace via std.log.scoped(.mcp).
pub const std_options = teru.log.std_options;

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
        std.log.scoped(.compositor).err("failed to create wl_display", .{});
        return error.DisplayCreateFailed;
    };

    const event_loop = wlr.wl_display_get_event_loop(display) orelse {
        wlr.wl_display_destroy(display);
        std.log.scoped(.compositor).err("failed to get event loop", .{});
        return error.EventLoopFailed;
    };

    // ── Initialize compositor server ────────────────────────────
    const server = Server.initOnHeap(display, event_loop, allocator) catch |err| {
        wlr.wl_display_destroy(display);
        std.log.scoped(.compositor).err("server init failed: {}", .{err});
        return err;
    };
    // Defer order matters. LIFO unwind means the LAST defer registered
    // runs FIRST. We want:
    //   1. shutting_down = true — gates handlers like
    //      Output.handleDestroy from pushing state into a wlroots
    //      manager that's itself being torn down.
    //   2. wl_display_destroy_clients — tears down every client
    //      connection (Chromium, Emacs, etc.) and fires each surface's
    //      destroy listeners while Server state is still alive.
    //   3. wl_display_destroy — tears down globals + the event loop.
    //      Without step 2, scene nodes and per-surface listeners for
    //      still-mapped clients get walked with dangling notify
    //      pointers → "Segmentation fault" inside libwayland-server.
    //   4. server.deinit — frees Server-owned heap memory last.
    // Registered LAST runs FIRST, so we register in reverse of the
    // desired run order.
    defer server.deinit();
    defer wlr.wl_display_destroy(display);
    defer wlr.wl_display_destroy_clients(display);
    defer server.shutting_down = true;

    // ── Apply config to server ──────────────────────────────────
    server.applyConfig(&config, allocator, io);

    // ── Add Wayland socket ──────────────────────────────────────
    const socket = wlr.wl_display_add_socket_auto(display);
    if (socket == null) {
        std.log.scoped(.compositor).err("failed to add Wayland socket", .{});
        return error.SocketFailed;
    }

    // ── Start backend ───────────────────────────────────────────
    if (!wlr.wlr_backend_start(server.backend)) {
        std.log.scoped(.compositor).err("failed to start backend", .{});
        return error.BackendStartFailed;
    }

    // Set environment for child processes
    if (socket) |sock| {
        _ = wlr.setenv("WAYLAND_DISPLAY", sock, 1);
    }

    // ── Restore session from restart ───────────────────────────
    if (restoring) {
        ServerRestart.restoreSession(server, allocator);
        // Don't re-run autostart on hot-restart: the clients it would
        // spawn are still connected from the previous compositor.
        server.autostart_fired = true;
    }

    // ── Start MCP server for compositor control ────────────────
    server.startMcp();

    std.log.scoped(.compositor).info("compositor running on WAYLAND_DISPLAY={s}", .{
        socket orelse "unknown",
    });

    // ── Graceful shutdown on SIGTERM / SIGINT ───────────────────
    // Without this, `kill` and Ctrl+C terminate teruwm by the signal's
    // default action — main's defer chain never runs, so MCP socket
    // files leak in $XDG_RUNTIME_DIR and clients are not torn down
    // cleanly. wl_event_loop_add_signal routes the signal through the
    // event loop; the handler just calls wl_display_terminate, which
    // returns wl_display_run() and unwinds the defers normally.
    _ = wlr.wl_event_loop_add_signal(event_loop, @intCast(@intFromEnum(std.posix.SIG.TERM)), handleTerminationSignal, display);
    _ = wlr.wl_event_loop_add_signal(event_loop, @intCast(@intFromEnum(std.posix.SIG.INT)), handleTerminationSignal, display);

    // ── Run event loop ──────────────────────────────────────────
    wlr.wl_display_run(display);

    std.log.scoped(.compositor).info("shutting down", .{});
}

/// SIGTERM / SIGINT handler — runs in event-loop context (signalfd).
/// wl_display_terminate makes wl_display_run() return so main's defer
/// chain (destroy_clients → display_destroy → server.deinit) runs.
fn handleTerminationSignal(_: c_int, data: ?*anyopaque) callconv(.c) c_int {
    if (data) |d| {
        const display: *wlr.wl_display = @ptrCast(@alignCast(d));
        wlr.wl_display_terminate(display);
    }
    return 0;
}

