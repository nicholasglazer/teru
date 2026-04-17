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

    const event_loop = wlr.wl_display_get_event_loop(display) orelse {
        wlr.wl_display_destroy(display);
        std.debug.print("teruwm: failed to get event loop\n", .{});
        return error.EventLoopFailed;
    };

    // ── Initialize compositor server ────────────────────────────
    const server = Server.initOnHeap(display, event_loop, allocator) catch |err| {
        wlr.wl_display_destroy(display);
        std.debug.print("teruwm: server init failed: {}\n", .{err});
        return err;
    };
    // Defer order matters. LIFO unwind means the LAST defer registered
    // runs FIRST. We want wl_display_destroy to fire BEFORE server.deinit
    // so that xdg/xwayland destroy listeners — which call into
    // server.nodes.remove() etc. — still see a valid Server. Registering
    // server.deinit first makes it run LAST, after every client listener
    // has fired. Pre-fix: Emacs-under-XWayland at shutdown triggered
    // `by_id.get()` on a HashMap whose backing was already freed →
    // "incorrect alignment" panic.
    defer server.deinit();
    defer wlr.wl_display_destroy(display);

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
        ServerRestart.restoreSession(server, allocator);
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

