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

// ── Multi-output state (v0.4.20) ──────────────────────────────
//
// The three-rule architecture (see docs/ARCHITECTURE.md):
//   R1  Node.workspace is identity (which workspace a window belongs to).
//   R2  Output.workspace is a viewport (which workspace is visible here).
//   R3  A node renders iff some output is currently showing its workspace.
//
// `workspace` and `prev_workspace` implement R2. `prev_workspace`
// powers Mod+Escape per-output toggle-last. Other outputs reference
// the same global `layout_engine.workspaces[]` set — workspaces don't
// belong to outputs, they just get shown on them.

/// Currently visible workspace on this output.
workspace: u8 = 0,
/// Previous visible workspace (for Mod+Escape toggle-last).
prev_workspace: ?u8 = null,

/// Create an Output, register listeners, enable the output.
pub fn create(server: *Server, wlr_output: *wlr.wlr_output, allocator: std.mem.Allocator) !*Output {
    const output = try allocator.create(Output);
    output.* = .{
        .server = server,
        .wlr_output = wlr_output,
        .frame = .{ .link = .{ .prev = null, .next = null }, .notify = handleFrame },
        .request_state = .{ .link = .{ .prev = null, .next = null }, .notify = handleRequestState },
        .destroy = .{ .link = .{ .prev = null, .next = null }, .notify = handleDestroy },
        // New outputs take the server's active workspace as their initial
        // viewport. If the workspace is already shown on another output
        // the user can Mod+N to pick a different one — we don't pull-swap
        // on connect.
        .workspace = server.layout_engine.active_workspace,
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

    // Track in Server.outputs — pointer identity survives disconnect.
    // Failure here is non-fatal (legacy code paths still work with just
    // primary_output); we just can't cycle focus to a non-tracked output.
    server.outputs.append(server.zig_allocator, output) catch {
        std.debug.print("teruwm: WARN: outputs list append failed\n", .{});
    };
    if (server.focused_output == null) server.focused_output = output;

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

        // Bar must exist before anything is tiled so arrangeworkspace
        // accounts for bar height.
        server.bar = Bar.create(server);
        server.applyWmBar(); // apply teruwm config bar format strings

        // Start on workspace 1 (key 1, index 0). Do NOT auto-spawn a
        // terminal — tiling compositors conventionally start empty
        // and let the user (or an autostart config) decide what to
        // launch. Auto-spawn also made the "close all" UX confusing:
        // the last-closed pane would vanish, then the auto-spawn ran
        // only on first output so it didn't come back, leaving users
        // unsure whether close worked.
        server.layout_engine.switchWorkspace(0);

        if (server.bar) |b| b.render(server);
        std.debug.print("teruwm: output attached, workspace 1 active (empty)\n", .{});
    }

    return output;
}

// ── Signal handlers ────────────────────────────────────────────

fn handleFrame(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const output: *Output = @fieldParentPtr("frame", listener);
    const server = output.server;
    const frame_start = compat.monotonicNow();

    // Global, cross-output side effects run on the focused output's
    // frame callback only — otherwise on N monitors at 60 Hz each we'd
    // re-arrange / re-resize / restart N times per vsync.
    // Single-monitor setups: focused_output == this output == harmless.
    const is_canonical = if (server.focused_output) |fo| fo == output else true;

    if (is_canonical) {
        // Apply deferred layout from border drag (once per vsync).
        if (server.layout_dirty) {
            server.arrangeWorkspaceSmooth(server.layout_engine.active_workspace);
            server.layout_dirty = false;
        }

        // Apply deferred terminal resize from floating drag.
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

        // Render dirty terminal panes before compositing. Terminals are
        // software-rendered into a shared scene graph, so rendering once
        // per vsync on the canonical output is enough — every other
        // output that shows the same workspace reads the same buffer.
        for (server.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| _ = tp.renderIfDirty();
        }
    }

    const scene_output = wlr.wlr_scene_get_scene_output(server.scene, output.wlr_output) orelse return;
    _ = wlr.wlr_scene_output_commit(scene_output, null);

    // Fire wl_surface.frame callbacks so Wayland clients know the frame
    // landed and can submit their next buffer. Chromium/Ozone — and
    // anything else using wp_presentation-style throttling — blocks on
    // this callback: without it, the renderer produces one frame and then
    // waits forever, which manifests as Vivaldi stuck on its splash and
    // Chromium freezing after the initial paint.
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    wlr.wlr_scene_output_send_frame_done(scene_output, &now);

    if (is_canonical) {
        // MCP-triggered restart — ordered after commit so the response
        // reaches the client before we exec().
        if (server.restart_pending) {
            server.restart_pending = false;
            server.execRestart();
            // If we get here, exec() failed — the event loop resumes.
        }
    }

    // Frame timing is per-output (measures THIS output's path).
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
    const server = output.server;
    const name = wlr.miozu_output_name(output.wlr_output) orelse "unknown";
    std.debug.print("teruwm: output '{s}' disconnected\n", .{name});

    // Remove listeners
    wlr.wl_list_remove(&output.frame.link);
    wlr.wl_list_remove(&output.request_state.link);
    wlr.wl_list_remove(&output.destroy.link);

    // Drop from Server.outputs and fix up focused_output. Nodes whose
    // workspace was only shown on this output become invisible — the
    // user can Mod+N to see them again. xmonad calls this "screen gone,
    // workspace orphaned" and handles it the same way.
    for (server.outputs.items, 0..) |o, i| {
        if (o == output) {
            _ = server.outputs.orderedRemove(i);
            break;
        }
    }
    if (server.focused_output == output) {
        server.focused_output = if (server.outputs.items.len > 0) server.outputs.items[0] else null;
    }
    if (server.primary_output == output.wlr_output) {
        server.primary_output = if (server.focused_output) |fo| fo.wlr_output else null;
    }
    server.recomputeVisibility();

    // Tell wlr-output-management clients the head is gone — but only
    // when we're still running normally. During shutdown the manager
    // is itself being torn down by wl_display_destroy; pushing a new
    // configuration at that moment crashed with a general-protection
    // fault inside wlr_output_manager_v1_set_configuration.
    if (!server.shutting_down) {
        server.pushOutputManagerState();
    }

    server.zig_allocator.destroy(output);
}
