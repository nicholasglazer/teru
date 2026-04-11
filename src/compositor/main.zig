//! miozu — Wayland compositor built on libteru + wlroots.
//!
//! Entry point for the compositor binary. Creates the Server (which
//! initializes wlroots), starts the backend, and runs the event loop.

const std = @import("std");
const teru = @import("teru");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // ── Create Wayland display ──────────────────────────────────
    const display = wlr.wl_display_create() orelse {
        std.debug.print("miozu: failed to create wl_display\n", .{});
        return error.DisplayCreateFailed;
    };
    defer wlr.wl_display_destroy(display);

    const event_loop = wlr.wl_display_get_event_loop(display) orelse {
        std.debug.print("miozu: failed to get event loop\n", .{});
        return error.EventLoopFailed;
    };

    // ── Initialize compositor server ────────────────────────────
    // Heap-allocated: Server embeds wl_listeners whose addresses are registered
    // with wlroots via wl_signal_add. Those pointers must remain stable — if
    // Server moves in memory, wlroots callbacks dangle. initOnHeap() allocates
    // first, then inits in-place so listener addresses are final.
    const server = Server.initOnHeap(display, event_loop, allocator) catch |err| {
        std.debug.print("miozu: server init failed: {}\n", .{err});
        return err;
    };
    defer server.deinit();

    // ── Add Wayland socket ──────────────────────────────────────
    const socket = wlr.wl_display_add_socket_auto(display);
    if (socket == null) {
        std.debug.print("miozu: failed to add Wayland socket\n", .{});
        return error.SocketFailed;
    }

    // ── Load font atlas (shared across all terminal panes) ───────
    if (teru.render.FontAtlas.init(allocator, null, 14, io)) |atlas| {
        const fa = try allocator.create(teru.render.FontAtlas);
        fa.* = atlas;
        server.font_atlas = fa;
        std.debug.print("miozu: font loaded ({d}x{d} cells)\n", .{ fa.cell_width, fa.cell_height });
    } else |err| {
        std.debug.print("miozu: font init failed: {}, using fallback\n", .{err});
    }

    // ── Start backend ───────────────────────────────────────────
    if (!wlr.wlr_backend_start(server.backend)) {
        std.debug.print("miozu: failed to start backend\n", .{});
        return error.BackendStartFailed;
    }

    // Set WAYLAND_DISPLAY for child processes
    if (socket) |sock| {
        _ = wlr.setenv("WAYLAND_DISPLAY", sock, 1);
    }

    std.debug.print("miozu: compositor running on WAYLAND_DISPLAY={s}\n", .{
        socket orelse "unknown",
    });

    // ── Run event loop ──────────────────────────────────────────
    wlr.wl_display_run(display);

    std.debug.print("miozu: shutting down\n", .{});
}
