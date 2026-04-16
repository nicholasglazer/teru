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

// wlr_foreign_toplevel_management_v1 handle. Created on map, destroyed
// on unmap; null in between. Taskbar clients (waybar, nwg-panel) see
// the handle and can activate/close it — we translate those requests
// back into focusView / wlr_xdg_toplevel_send_close.
ftl_handle: ?*wlr.wlr_foreign_toplevel_handle_v1 = null,
ftl_request_activate: wlr.wl_listener = undefined,
ftl_request_close: wlr.wl_listener = undefined,

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

    const app_id = wlr.miozu_xdg_toplevel_app_id(view.toplevel);

    // Check window rules for workspace assignment
    const ws = if (app_id) |aid|
        server.wm_config.matchRule(std.mem.sliceTo(aid, 0)) orelse server.layout_engine.active_workspace
    else
        server.layout_engine.active_workspace;

    // Register in the node registry on the target workspace
    const slot = server.nodes.addSurface(view.node_id, ws, view.toplevel, view.scene_tree, @ptrCast(view));

    // Store app_id and assign name
    if (slot) |s| {
        const aid_str = if (app_id) |aid| std.mem.sliceTo(aid, 0) else "";
        if (aid_str.len > 0) {
            server.nodes.setAppId(s, aid_str);
            // Check [names] config rules, fall back to app_id as name
            if (server.wm_config.matchName(aid_str)) |custom_name| {
                server.nodes.setName(s, custom_name);
            } else {
                server.nodes.setName(s, aid_str);
            }
        }
    }

    // Add to tiling engine workspace
    server.layout_engine.workspaces[ws].addNode(server.zig_allocator, view.node_id) catch return;

    server.emitMcpEventKind(
        "window_mapped",
        ",\"node_id\":{d},\"workspace\":{d}",
        .{ view.node_id, ws },
    );

    std.debug.print("teruwm: surface mapped app_id='{s}' node={d} ws={d}\n", .{
        app_id orelse "none",
        view.node_id,
        ws,
    });

    // Trigger re-tile
    server.arrangeworkspace(ws);

    // Register as a foreign-toplevel handle so taskbars see this
    // window. Push title + app_id so the taskbar icon labels itself.
    if (server.foreign_toplevel_mgr) |mgr| {
        if (wlr.wlr_foreign_toplevel_handle_v1_create(mgr)) |h| {
            view.ftl_handle = h;
            const title = wlr.miozu_xdg_toplevel_title(view.toplevel);
            if (title) |t| wlr.wlr_foreign_toplevel_handle_v1_set_title(h, t);
            if (app_id) |a| wlr.wlr_foreign_toplevel_handle_v1_set_app_id(h, a);

            view.ftl_request_activate = makeListener(handleFtlActivate);
            view.ftl_request_close = makeListener(handleFtlClose);
            wlr.wl_signal_add(wlr.miozu_ftl_request_activate(h), &view.ftl_request_activate);
            wlr.wl_signal_add(wlr.miozu_ftl_request_close(h), &view.ftl_request_close);
        }
    }

    // Focus the new surface
    server.focusView(view);
}

fn handleFtlActivate(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("ftl_request_activate", listener);
    // Taskbar asked us to focus this window — route through focusView
    // which handles ws switch + keyboard notify + bar re-render.
    view.server.focusView(view);
}

fn handleFtlClose(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("ftl_request_close", listener);
    // Same path as Win+X / teruwm_close_window.
    wlr.wlr_xdg_toplevel_send_close(view.toplevel);
}

fn handleUnmap(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("unmap", listener);
    const server = view.server;

    // Clear Server pointers into this view BEFORE the registry row
    // goes away — otherwise any subsequent code path that checks
    // focused_view / grab_node_id dereferences a dangling wlr_surface
    // and wl_resource_post_event aborts. Matches the invariant we
    // enforce in Server.closeNode / handleTerminalExit.
    server.clearFocusRefs(view.node_id);

    // Null last_pointer_surface if it points at this view's wlr_surface.
    // Raw *wlr_surface stored in Server; keyed off the surface itself
    // not node_id, so clearFocusRefs can't handle it.
    if (wlr.miozu_xdg_toplevel_base(view.toplevel)) |xdg_surface| {
        if (wlr.miozu_xdg_surface_surface(xdg_surface)) |s| {
            if (server.last_pointer_surface == s) server.last_pointer_surface = null;
        }
    }

    // Tear down the foreign-toplevel handle — taskbars receive the
    // `closed` event and drop the icon.
    if (view.ftl_handle) |h| {
        wlr.wl_list_remove(&view.ftl_request_activate.link);
        wlr.wl_list_remove(&view.ftl_request_close.link);
        wlr.wlr_foreign_toplevel_handle_v1_destroy(h);
        view.ftl_handle = null;
    }

    // Remove from node registry and tiling engine
    _ = server.nodes.remove(view.node_id);
    for (&server.layout_engine.workspaces) |*ws| {
        ws.removeNode(view.node_id);
    }

    std.debug.print("teruwm: surface unmapped node={d}\n", .{view.node_id});
}

fn handleDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("destroy", listener);
    const server = view.server;

    // Mirror handleUnmap — the client may have gone away without
    // unmap (race on crash), so guard the same Server pointers here.
    server.clearFocusRefs(view.node_id);

    // Same wlr_surface invalidation as handleUnmap — toplevel_destroy
    // can arrive without a prior surface_unmap on a hard client crash.
    if (wlr.miozu_xdg_toplevel_base(view.toplevel)) |xdg_surface| {
        if (wlr.miozu_xdg_surface_surface(xdg_surface)) |s| {
            if (server.last_pointer_surface == s) server.last_pointer_surface = null;
        }
    }

    // Tear down foreign-toplevel handle if unmap didn't already.
    if (view.ftl_handle) |h| {
        wlr.wl_list_remove(&view.ftl_request_activate.link);
        wlr.wl_list_remove(&view.ftl_request_close.link);
        wlr.wlr_foreign_toplevel_handle_v1_destroy(h);
        view.ftl_handle = null;
    }

    // Clean up node registry
    _ = server.nodes.remove(view.node_id);
    for (&server.layout_engine.workspaces) |*ws| {
        ws.removeNode(view.node_id);
    }

    // Remove listeners
    wlr.wl_list_remove(&view.map.link);
    wlr.wl_list_remove(&view.unmap.link);
    wlr.wl_list_remove(&view.destroy.link);
    wlr.wl_list_remove(&view.commit.link);

    std.debug.print("teruwm: surface destroyed node={d}\n", .{view.node_id});

    // Free the view
    server.zig_allocator.destroy(view);
}

fn handleCommit(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("commit", listener);

    // XDG protocol: on the client's initial commit, the compositor MUST
    // send a configure event before the client can map the surface.
    // Passing (0, 0) tells the client "you pick the size" — we'll override
    // it later via arrangeworkspace() once the surface maps.
    const xdg_surface = wlr.miozu_xdg_toplevel_base(view.toplevel) orelse return;
    if (wlr.miozu_xdg_surface_initial_commit(xdg_surface)) {
        _ = wlr.wlr_xdg_toplevel_set_size(view.toplevel, 0, 0);
    }
}

// ── Helper ─────────────────────────────────────────────────────

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}
