//! teruwm — Wayland compositor built on libteru + wlroots.
//!
//! Entry point for the compositor binary. Loads config from teru.conf,
//! creates the Server (which initializes wlroots), starts the backend,
//! and runs the event loop.

const std = @import("std");
const teru = @import("teru");
const Config = teru.Config;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // ── Load config from ~/.config/teru/teru.conf ──────────────
    // Shared config: font, colors, terminal keybinds, workspace layouts.
    // teruwm adds Super+key compositor keybinds on top.
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

    std.debug.print("teruwm: compositor running on WAYLAND_DISPLAY={s}\n", .{
        socket orelse "unknown",
    });

    // ── Run event loop ──────────────────────────────────────────
    wlr.wl_display_run(display);

    std.debug.print("teruwm: shutting down\n", .{});
}
