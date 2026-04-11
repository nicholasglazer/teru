//! Per-XDG-toplevel state for the miozu compositor.
//!
//! Each Wayland client window gets an XdgView that tracks its listeners,
//! scene tree node, and tiling node ID. Allocated on surface creation,
//! freed on destroy. The struct embeds its wl_listeners so @fieldParentPtr
//! can recover it in callbacks — no hash map lookup, O(1) dispatch.

const std = @import("std");
const wlr = @import("wlr.zig");
const NodeRegistry = @import("Node.zig");
const Server = @import("Server.zig");

const XdgView = @This();

server: *Server,
toplevel: *wlr.wlr_xdg_toplevel,
scene_tree: *wlr.wlr_scene_tree,
node_id: u64,

// Listeners (embedded for O(1) container-of dispatch)
map: wlr.wl_listener,
unmap: wlr.wl_listener,
destroy: wlr.wl_listener,
commit: wlr.wl_listener,

/// Create an XdgView for a new toplevel surface.
pub fn create(server: *Server, toplevel: *wlr.wlr_xdg_toplevel) ?*XdgView {
    const allocator = server.zig_allocator;

    // Get the xdg_surface from the toplevel
    const xdg_surface = wlr.miozu_xdg_toplevel_base(toplevel) orelse return null;

    // Create a scene tree node for this surface under the root scene tree
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_tree = wlr.wlr_scene_xdg_surface_create(scene_tree_root, xdg_surface) orelse return null;

    // Allocate the view
    const view = allocator.create(XdgView) catch return null;
    const node_id = server.next_node_id;
    server.next_node_id += 1;

    view.* = .{
        .server = server,
        .toplevel = toplevel,
        .scene_tree = scene_tree,
        .node_id = node_id,
        .map = makeListener(handleMap),
        .unmap = makeListener(handleUnmap),
        .destroy = makeListener(handleDestroy),
        .commit = makeListener(handleCommit),
    };

    // Register listeners on the surface and toplevel events
    const surface = wlr.miozu_xdg_surface_surface(xdg_surface) orelse return null;
    wlr.wl_signal_add(wlr.miozu_surface_map(surface), &view.map);
    wlr.wl_signal_add(wlr.miozu_surface_unmap(surface), &view.unmap);
    wlr.wl_signal_add(wlr.miozu_surface_commit(surface), &view.commit);
    wlr.wl_signal_add(wlr.miozu_xdg_toplevel_destroy(toplevel), &view.destroy);

    return view;
}

// ── Signal handlers ────────────────────────────────────────────

fn handleMap(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("map", listener);
    const server = view.server;

    // Register in the node registry on the active workspace
    const ws = server.layout_engine.active_workspace;
    _ = server.nodes.addSurface(view.node_id, ws, view.toplevel, view.scene_tree);

    // Add to tiling engine workspace
    server.layout_engine.workspaces[ws].addNode(server.zig_allocator, view.node_id) catch return;

    const app_id = wlr.miozu_xdg_toplevel_app_id(view.toplevel);
    std.debug.print("miozu: surface mapped app_id='{s}' node={d} ws={d}\n", .{
        app_id orelse "none",
        view.node_id,
        ws,
    });

    // Trigger re-tile
    server.arrangeworkspace(ws);

    // Focus the new surface
    server.focusView(view);
}

fn handleUnmap(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("unmap", listener);

    // Remove from node registry and tiling engine
    _ = view.server.nodes.remove(view.node_id);
    for (&view.server.layout_engine.workspaces) |*ws| {
        ws.removeNode(view.node_id);
    }

    std.debug.print("miozu: surface unmapped node={d}\n", .{view.node_id});
}

fn handleDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("destroy", listener);

    // Clean up node registry
    _ = view.server.nodes.remove(view.node_id);
    for (&view.server.layout_engine.workspaces) |*ws| {
        ws.removeNode(view.node_id);
    }

    // Remove listeners
    wlr.wl_list_remove(&view.map.link);
    wlr.wl_list_remove(&view.unmap.link);
    wlr.wl_list_remove(&view.destroy.link);
    wlr.wl_list_remove(&view.commit.link);

    std.debug.print("miozu: surface destroyed node={d}\n", .{view.node_id});

    // Free the view
    view.server.zig_allocator.destroy(view);
}

fn handleCommit(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    _ = listener;
    // Surface committed a new buffer — wlr_scene handles this automatically.
    // We only need this for future damage tracking optimization.
}

// ── Helper ─────────────────────────────────────────────────────

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}
