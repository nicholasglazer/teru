//! Tiling-layout math for teruwm.
//!
//! Pure-ish geometric transforms on top of the layout engine +
//! node registry. Reads Server.focused_*, Server.nodes,
//! Server.layout_engine, Server.activeOutputDims(), Server.bar
//! (for tiling-area height), Server.wm_config.gap, and
//! Server.arrange_scratch_buf (FBA scratch for per-call Rect
//! allocation).
//!
//! Both arrange paths must use identical gap inset math — drift
//! between them manifests as a visual jump at the end of a drag
//! when the smooth path hands control back to the final arrange.
//! `computeTilingScreen` is the single source of truth.

const std = @import("std");
const teru = @import("teru");
const LayoutEngine = teru.LayoutEngine;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const NodeRegistry = @import("Node.zig");

/// Gap-inset screen rect + per-pane inset accounts.
/// Pre-inset the screen by half-gap so edge gaps match inter-pane gaps:
/// layout divides the inset area, each pane is post-inset another hg
/// per side; result is edge = hg+hg = gap, between panes = hg+hg = gap.
pub fn computeTilingScreen(server: *Server) struct { rect: LayoutEngine.Rect, hg: i32, g: i32 } {
    const dims = server.activeOutputDims();
    const w: u16 = @intCast(dims.w);
    const full_h: u32 = dims.h;
    const bar_h: u32 = if (server.bar) |b| b.totalHeight() else 0;
    const bar_y_offset: i32 = if (server.bar) |b| @intCast(b.tilingOffsetY()) else 0;
    const h: u16 = @intCast(@max(1, full_h - bar_h));

    const g: i32 = @intCast(server.wm_config.gap);
    const hg: i32 = @divTrunc(g, 2);
    return .{
        .rect = .{
            .x = @intCast(@as(i32, 0) + hg),
            .y = @intCast(bar_y_offset + hg),
            .width = if (w > @as(u16, @intCast(g))) w - @as(u16, @intCast(g)) else w,
            .height = if (h > @as(u16, @intCast(g))) h - @as(u16, @intCast(g)) else h,
        },
        .hg = hg,
        .g = g,
    };
}

/// Recalculate layout for a workspace and apply rects to scene nodes.
/// Terminal panes are resized (grid + PTY); xdg clients get an applyRect
/// that ultimately sends xdg_toplevel_set_size on next commit.
pub fn arrangeWorkspace(server: *Server, ws_index: u8) void {
    const geom = computeTilingScreen(server);
    const hg = geom.hg;
    const g = geom.g;

    var fba = std.heap.FixedBufferAllocator.init(&server.arrange_scratch_buf);
    const rects = server.layout_engine.calculateWith(ws_index, geom.rect, fba.allocator()) catch return;

    const ws = &server.layout_engine.workspaces[ws_index];
    const node_ids = ws.node_ids.items;

    for (node_ids, 0..) |nid, i| {
        if (i >= rects.len) break;
        if (server.nodes.findById(nid)) |slot| {
            const rx = rects[i].x + hg;
            const ry = rects[i].y + hg;
            const gu16: u16 = @intCast(g);
            const rw: u16 = if (rects[i].width > gu16) rects[i].width - gu16 else rects[i].width;
            const rh: u16 = if (rects[i].height > gu16) rects[i].height - gu16 else rects[i].height;
            server.nodes.applyRect(slot, rx, ry, rw, rh);

            if (server.nodes.kind[slot] == .terminal) {
                if (server.terminalPaneById(nid)) |tp| {
                    tp.resize(rw, rh);
                    tp.setPosition(rx, ry);
                    // Force repaint so smart-border state (count change,
                    // solo ↔ shared) gets reflected even when the rect
                    // didn't change. Full-grid dirty is intentional —
                    // the border colour applies to every row's edge.
                    tp.pane.grid.markAllDirty();
                }
            }
        }
    }
}

/// Drag-feedback arrange: reposition + scale scene buffers WITHOUT
/// resizing terminal grids. Used during interactive resize drag for
/// instant visual feedback. The actual grid resize happens on release
/// via arrangeWorkspace.
pub fn arrangeWorkspaceSmooth(server: *Server, ws_index: u8) void {
    const geom = computeTilingScreen(server);
    const hg = geom.hg;
    const g = geom.g;

    var fba = std.heap.FixedBufferAllocator.init(&server.arrange_scratch_buf);
    const rects = server.layout_engine.calculateWith(ws_index, geom.rect, fba.allocator()) catch return;

    const ws = &server.layout_engine.workspaces[ws_index];
    const node_ids = ws.node_ids.items;

    for (node_ids, 0..) |nid, i| {
        if (i >= rects.len) break;
        const rx = rects[i].x + hg;
        const ry = rects[i].y + hg;
        const gu16: u16 = @intCast(g);
        const rw: u16 = if (rects[i].width > gu16) rects[i].width - gu16 else rects[i].width;
        const rh: u16 = if (rects[i].height > gu16) rects[i].height - gu16 else rects[i].height;

        if (server.terminalPaneById(nid)) |tp| {
            tp.setPosition(rx, ry);
            wlr.wlr_scene_buffer_set_dest_size(tp.scene_buffer, @intCast(rw), @intCast(rh));
        }

        if (server.nodes.findById(nid)) |slot| {
            server.nodes.pos_x[slot] = rx;
            server.nodes.pos_y[slot] = ry;
            server.nodes.width[slot] = rw;
            server.nodes.height[slot] = rh;
        }
    }
}

/// Un-float the focused node if currently floating. Reverses a
/// previous float toggle.
///
/// Resolves the target via focused_terminal/focused_view rather than
/// layout_engine.getActiveNodeId (which iterates tiled nodes only) —
/// the focused node may be floating, and sinking it is exactly what
/// the caller wants. Before this fix the action silently no-op'd on
/// the very case it exists to handle.
pub fn sinkFocused(server: *Server) void {
    const nid: u64 = if (server.focused_terminal) |tp|
        tp.node_id
    else if (server.focused_view) |v|
        v.node_id
    else
        return;
    const slot = server.nodes.findById(nid) orelse return;
    if (!server.nodes.floating[slot]) return;
    server.nodes.floating[slot] = false;
    server.layout_engine.workspaces[server.layout_engine.active_workspace].addNode(server.zig_allocator, nid) catch {};
    arrangeWorkspace(server, server.layout_engine.active_workspace);
}

/// Sink every floating node on the active workspace back into tiling.
/// Skips scratchpads (they live outside the tiled node list).
pub fn sinkAllOnActiveWorkspace(server: *Server) void {
    const ws_index = server.layout_engine.active_workspace;
    var changed = false;
    for (0..NodeRegistry.max_nodes) |i| {
        if (server.nodes.kind[i] == .empty) continue;
        if (server.nodes.workspace[i] != ws_index) continue;
        if (!server.nodes.floating[i]) continue;
        const nid = server.nodes.node_id[i];
        server.nodes.floating[i] = false;
        server.layout_engine.workspaces[ws_index].addNode(server.zig_allocator, nid) catch continue;
        changed = true;
    }
    if (changed) arrangeWorkspace(server, ws_index);
}
