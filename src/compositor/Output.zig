//! Per-output state for the miozu compositor.
//!
//! Each connected monitor gets an Output struct that tracks the wlr_output,
//! its scene_output, and the frame listener. On each frame callback, we
//! commit the wlr_scene to this output.

const std = @import("std");
const teru = @import("teru");
const compat = teru.compat;
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
    std.debug.print("teruwm: output '{s}' connected ({d}x{d})\n", .{ name, w, h });

    // On first output: create background, bars, then spawn terminal
    if (server.terminal_count == 0) {
        // Background rect: covers full output, lowered below everything else.
        // Color is solid ARGB from wm_config.bg_color.
        const scene_tree_root = wlr.miozu_scene_tree(server.scene);
        if (scene_tree_root) |root| {
            const col = server.wm_config.bg_color;
            const rgba: [4]f32 = .{
                @as(f32, @floatFromInt((col >> 16) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((col >> 8) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt(col & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((col >> 24) & 0xFF)) / 255.0,
            };
            if (wlr.wlr_scene_rect_create(root, w, h, &rgba)) |rect| {
                server.bg_rect = rect;
                wlr.wlr_scene_node_lower_to_bottom(wlr.miozu_scene_rect_node(rect));
            }
        }

        // Bar must exist before spawnTerminal so arrangeworkspace accounts for bar height
        server.bar = Bar.create(server);
        server.applyWmBar(); // apply teruwm config bar format strings

        // Start on workspace 1 (key 1, index 0) with a terminal
        server.layout_engine.switchWorkspace(0);
        server.spawnTerminal(0);

        if (server.bar) |b| b.render(server);
        std.debug.print("teruwm: terminal spawned on workspace 1\n", .{});
    }

    return output;
}

// ── Signal handlers ────────────────────────────────────────────

fn handleFrame(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const output: *Output = @fieldParentPtr("frame", listener);
    const server = output.server;
    const frame_start = compat.monotonicNow();

    // Apply deferred layout from border drag (once per vsync, not per mouse motion)
    if (server.layout_dirty) {
        server.arrangeWorkspaceSmooth(server.layout_engine.active_workspace);
        server.layout_dirty = false;
    }

    // Apply deferred terminal resize from floating drag
    if (server.resize_pending_id) |rid| {
        for (server.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                if (tp.node_id == rid) {
                    tp.resize(server.resize_pending_w, server.resize_pending_h);
                    break;
                }
            }
        }
        server.resize_pending_id = null;
    }

    // Render dirty terminal panes before compositing (coalesces PTY reads to vsync)
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| _ = tp.renderIfDirty();
    }

    const scene_output = wlr.wlr_scene_get_scene_output(server.scene, output.wlr_output) orelse return;
    _ = wlr.wlr_scene_output_commit(scene_output, null);

    // MCP-triggered restart (deferred to after response is sent)
    if (server.restart_pending) {
        server.restart_pending = false;
        server.execRestart();
        // If we get here, exec() failed
    }

    // Record frame timing
    const elapsed_ns = compat.monotonicNow() - frame_start;
    const elapsed_us: u64 = @intCast(@max(0, @divTrunc(elapsed_ns, 1000)));
    server.perf.recordFrame(elapsed_us);
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
    std.debug.print("teruwm: output '{s}' disconnected\n", .{name});

    // Remove listeners
    wlr.wl_list_remove(&output.frame.link);
    wlr.wl_list_remove(&output.request_state.link);
    wlr.wl_list_remove(&output.destroy.link);

    // Note: we leak the Output allocation here. In production, track outputs
    // in a list on Server and free properly. Fine for now.
}
