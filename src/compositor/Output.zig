//! Per-output state for the miozu compositor.
//!
//! Each connected monitor gets an Output struct that tracks the wlr_output,
//! its scene_output, and the frame listener. On each frame callback, we
//! commit the wlr_scene to this output.

const std = @import("std");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const Bar = @import("Bar.zig");

const Output = @This();

server: *Server,
wlr_output: *wlr.wlr_output,

// Listeners
frame: wlr.wl_listener,
request_state: wlr.wl_listener,
destroy: wlr.wl_listener,

/// Create an Output, register listeners, enable the output.
pub fn create(server: *Server, wlr_output: *wlr.wlr_output, allocator: std.mem.Allocator) !*Output {
    const output = try allocator.create(Output);
    output.* = .{
        .server = server,
        .wlr_output = wlr_output,
        .frame = .{ .link = .{ .prev = null, .next = null }, .notify = handleFrame },
        .request_state = .{ .link = .{ .prev = null, .next = null }, .notify = handleRequestState },
        .destroy = .{ .link = .{ .prev = null, .next = null }, .notify = handleDestroy },
    };

    // Init render pipeline for this output
    _ = wlr.wlr_output_init_render(wlr_output, server.allocator, server.renderer);

    // Enable output with preferred mode
    _ = wlr.miozu_output_enable_and_commit(wlr_output);

    // Register per-output listeners
    wlr.wl_signal_add(wlr.miozu_output_frame(wlr_output), &output.frame);
    wlr.wl_signal_add(wlr.miozu_output_request_state(wlr_output), &output.request_state);
    wlr.wl_signal_add(wlr.miozu_output_destroy(wlr_output), &output.destroy);

    // Add to output layout (auto-positions next to existing outputs)
    wlr.wlr_output_layout_add_auto(server.output_layout, wlr_output);

    // Create scene output for compositing
    _ = wlr.wlr_scene_output_create(server.scene, wlr_output);

    const name = wlr.miozu_output_name(wlr_output) orelse "unknown";
    const w = wlr.miozu_output_width(wlr_output);
    const h = wlr.miozu_output_height(wlr_output);
    std.debug.print("miozu: output '{s}' connected ({d}x{d})\n", .{ name, w, h });

    // On first output: spawn the immortal terminal on workspace 9 (key 0)
    if (server.terminal_count == 0) {
        server.layout_engine.switchWorkspace(9); // workspace "0" (immortal home)
        server.spawnTerminal(9); // auto-sizes to fill output

        // Create configurable dual bar system
        server.bar = Bar.create(server);
        if (server.bar) |b| b.render(server);

        std.debug.print("miozu: immortal terminal spawned on workspace 0\n", .{});
    }

    return output;
}

// ── Signal handlers ────────────────────────────────────────────

fn handleFrame(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const output: *Output = @fieldParentPtr("frame", listener);
    const scene_output = wlr.wlr_scene_get_scene_output(output.server.scene, output.wlr_output) orelse return;

    // Commit the scene graph to this output (renders all visible surfaces)
    _ = wlr.wlr_scene_output_commit(scene_output, null);
}

fn handleRequestState(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const output: *Output = @fieldParentPtr("request_state", listener);
    _ = output;
    // wlroots 0.18: handle output state change requests (mode, enabled, etc.)
    // For now, accept all state changes
    const event: ?*wlr.wlr_output_event_request_state = @ptrCast(@alignCast(data));
    _ = event;
}

fn handleDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const output: *Output = @fieldParentPtr("destroy", listener);
    const name = wlr.miozu_output_name(output.wlr_output) orelse "unknown";
    std.debug.print("miozu: output '{s}' disconnected\n", .{name});

    // Remove listeners
    wlr.wl_list_remove(&output.frame.link);
    wlr.wl_list_remove(&output.request_state.link);
    wlr.wl_list_remove(&output.destroy.link);

    // Note: we leak the Output allocation here. In production, track outputs
    // in a list on Server and free properly. Fine for now.
}
