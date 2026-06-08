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
show_window_menu: wlr.wl_listener = makeListener(handleShowWindowMenu),
new_popup: wlr.wl_listener = makeListener(handleNewPopup),
request_move: wlr.wl_listener = makeListener(handleRequestMove),
request_resize: wlr.wl_listener = makeListener(handleRequestResize),

// wlr_foreign_toplevel_management_v1 handle. Created on map, destroyed
// on unmap; null in between. Taskbar clients (waybar, nwg-panel) see
// the handle and can activate/close it — we translate those requests
// back into focusView / wlr_xdg_toplevel_send_close.
//
// ftl_destroy fires when wlroots tears the handle down before we get
// a chance (e.g. manager destroyed by wl_display_destroy on shutdown);
// it nulls view.ftl_handle so handleUnmap/handleDestroy skip the
// double-destroy. Default listeners use inert notify fns — callers
// must wl_signal_add to arm them; they're no-ops if invoked unarmed.
ftl_handle: ?*wlr.wlr_foreign_toplevel_handle_v1 = null,
ftl_request_activate: wlr.wl_listener = makeListener(handleFtlActivate),
ftl_request_close: wlr.wl_listener = makeListener(handleFtlClose),
ftl_destroy: wlr.wl_listener = makeListener(handleFtlDestroy),

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
        .show_window_menu = makeListener(handleShowWindowMenu),
        .new_popup = makeListener(handleNewPopup),
        .request_move = makeListener(handleRequestMove),
        .request_resize = makeListener(handleRequestResize),
    };

    // Register listeners on the surface and toplevel events
    const surface = wlr.miozu_xdg_surface_surface(xdg_surface) orelse return null;
    wlr.wl_signal_add(wlr.miozu_surface_map(surface), &view.map);
    wlr.wl_signal_add(wlr.miozu_surface_unmap(surface), &view.unmap);
    wlr.wl_signal_add(wlr.miozu_surface_commit(surface), &view.commit);
    wlr.wl_signal_add(wlr.miozu_xdg_toplevel_destroy(toplevel), &view.destroy);
    wlr.wl_signal_add(wlr.miozu_xdg_toplevel_request_show_window_menu(toplevel), &view.show_window_menu);
    wlr.wl_signal_add(wlr.miozu_xdg_surface_new_popup(xdg_surface), &view.new_popup);
    wlr.wl_signal_add(wlr.miozu_xdg_toplevel_request_move(toplevel), &view.request_move);
    wlr.wl_signal_add(wlr.miozu_xdg_toplevel_request_resize(toplevel), &view.request_resize);

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
    const slot = server.nodes.addSurface(server.zig_allocator, view.node_id, ws, view.toplevel, view.scene_tree, @ptrCast(view));

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

    // Transient toplevels (a dialog/modal the client anchored to a parent —
    // delete confirmation, file chooser, properties) FLOAT centered instead of
    // joining the tiling layout, which would split the screen "like a new
    // window". Detected via xdg_toplevel.parent. Everything else tiles.
    const is_dialog = wlr.miozu_xdg_toplevel_parent(view.toplevel) != null;
    if (is_dialog and slot != null) {
        server.nodes.floating[slot.?] = true;
        centerFloat(server, slot.?, view.toplevel);
    } else {
        // Add to tiling engine workspace
        server.layout_engine.workspaces[ws].addNode(server.zig_allocator, view.node_id) catch return;
    }

    server.emitMcpEventKind(
        "window_mapped",
        ",\"node_id\":{d},\"workspace\":{d}",
        .{ view.node_id, ws },
    );

    std.log.scoped(.compositor).info("surface mapped app_id='{s}' node={d} ws={d}", .{
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

            wlr.wl_signal_add(wlr.miozu_ftl_request_activate(h), &view.ftl_request_activate);
            wlr.wl_signal_add(wlr.miozu_ftl_request_close(h), &view.ftl_request_close);
            wlr.wl_signal_add(wlr.miozu_ftl_handle_destroy_signal(h), &view.ftl_destroy);
        }
    }

    // Focus the new surface
    server.focusView(view);
}

/// Center a floating node on the active output, sized to the client's own
/// window geometry so a dialog keeps its natural size (applyRect's set_size is
/// then a no-op the client already agreed to). Falls back to a sane default if
/// the geometry isn't reported yet.
fn centerFloat(server: *Server, slot: u16, toplevel: *wlr.wlr_xdg_toplevel) void {
    var w: i32 = 480;
    var h: i32 = 280;
    if (wlr.miozu_xdg_toplevel_base(toplevel)) |xdg_surface| {
        var geo: wlr.wlr_box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        wlr.wlr_xdg_surface_get_geometry(xdg_surface, &geo);
        if (geo.width > 0) w = geo.width;
        if (geo.height > 0) h = geo.height;
    }
    const dims = server.activeOutputDims();
    const x = @max(0, @divTrunc(@as(i32, @intCast(dims.w)) - w, 2));
    const y = @max(0, @divTrunc(@as(i32, @intCast(dims.h)) - h, 2));
    server.nodes.applyRect(slot, x, y, @intCast(w), @intCast(h));
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

/// wlroots destroyed the handle beneath us (manager teardown or
/// shutdown). Null our pointer so handleUnmap/handleDestroy don't
/// call _destroy again + unhook our own request listener links so
/// they don't live past the signal they're attached to.
fn handleFtlDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("ftl_destroy", listener);
    wlr.wl_list_remove(&view.ftl_request_activate.link);
    wlr.wl_list_remove(&view.ftl_request_close.link);
    wlr.wl_list_remove(&view.ftl_destroy.link);
    view.ftl_handle = null;
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
    // `closed` event and drop the icon. handleFtlDestroy will clear
    // the listener links + null ftl_handle; we don't touch them here.
    if (view.ftl_handle) |h| {
        wlr.wlr_foreign_toplevel_handle_v1_destroy(h);
    }

    // Capture the workspace the view lived on BEFORE removing it — we
    // reflow that specific workspace once the node is gone.
    const ws_index: ?u8 = if (server.nodes.findById(view.node_id)) |s|
        server.nodes.workspace[s]
    else
        null;

    // Remove from node registry and tiling engine
    _ = server.nodes.remove(view.node_id);
    for (&server.layout_engine.workspaces) |*ws| {
        ws.removeNode(view.node_id);
    }

    // Reflow the workspace so remaining tiles fill the gap. Without
    // this, closing a browser / xdg client leaves dead space where
    // the window was — the XwaylandView path already does this.
    // Smart-border state (count change → solo) also depends on the
    // rearrange to repaint borders correctly.
    if (ws_index) |w| server.arrangeworkspace(w);

    std.log.scoped(.compositor).info("surface unmapped node={d}", .{view.node_id});
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
    // wlroots fires the handle's destroy signal from inside
    // _destroy → handleFtlDestroy pulls the three listener links
    // + nulls ftl_handle. Don't remove them ourselves first, or
    // the signal handler double-removes undefined link state.
    if (view.ftl_handle) |h| {
        wlr.wlr_foreign_toplevel_handle_v1_destroy(h);
    }

    // Clean up node registry. Capture the workspace first so we can
    // reflow if destroy fires without a prior unmap (hard client crash).
    const ws_index: ?u8 = if (server.nodes.findById(view.node_id)) |s|
        server.nodes.workspace[s]
    else
        null;
    _ = server.nodes.remove(view.node_id);
    for (&server.layout_engine.workspaces) |*ws| {
        ws.removeNode(view.node_id);
    }
    if (ws_index) |w| server.arrangeworkspace(w);

    // Remove listeners
    wlr.wl_list_remove(&view.map.link);
    wlr.wl_list_remove(&view.unmap.link);
    wlr.wl_list_remove(&view.destroy.link);
    wlr.wl_list_remove(&view.commit.link);
    wlr.wl_list_remove(&view.show_window_menu.link);
    wlr.wl_list_remove(&view.new_popup.link);
    wlr.wl_list_remove(&view.request_move.link);
    wlr.wl_list_remove(&view.request_resize.link);

    std.log.scoped(.compositor).info("surface destroyed node={d}", .{view.node_id});

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


/// Per-xdg_popup tracking. A popup (context menu, tooltip, submenu) is its own
/// surface whose parent is EITHER a toplevel OR another popup. The toplevel's
/// new_popup only fires for first-level popups; a submenu's new_popup fires on
/// the *parent popup's* surface. Without a listener there, nested popups never
/// get a scene tree → the submenu is invisible (and wlroots logs "configure
/// scheduled for an uninitialized xdg_surface"). So we track each popup and
/// recursively listen for its children — arbitrary menu depth works.
///
/// `root_view` is the owning toplevel, threaded down the whole chain so the
/// unconstrain box is computed in the root toplevel's surface-local coords —
/// what wlr_xdg_popup_unconstrain_from_box expects (matches sway). The scene
/// tree is owned by the wlr_scene xdg-surface helper (auto-destroyed when the
/// surface dies), so destroy only frees this struct + unhooks our 2 listeners.
const Popup = struct {
    server: *Server,
    root_view: *XdgView,
    scene_tree: *wlr.wlr_scene_tree,
    new_popup: wlr.wl_listener,
    destroy: wlr.wl_listener,
};

/// Wire up a popup: create its scene tree under `parent_tree`, constrain it to
/// the output, and start tracking it so its own child popups (submenus) are
/// caught too. Shared by the toplevel's new_popup (parent_tree = view tree) and
/// the recursive popup new_popup (parent_tree = parent popup's tree).
fn setupPopup(server: *Server, root_view: *XdgView, parent_tree: *wlr.wlr_scene_tree, popup: *wlr.wlr_xdg_popup) void {
    const popup_surface = wlr.miozu_xdg_popup_base(popup) orelse return;
    const scene_tree = wlr.wlr_scene_xdg_surface_create(parent_tree, popup_surface) orelse return;
    // A nested popup (submenu) logs parent_tree == an earlier line's scene_tree.
    std.log.scoped(.compositor).debug("popup setup root_node={d} parent_tree={*} -> scene_tree={*}", .{ root_view.node_id, parent_tree, scene_tree });

    // Constrain first — without it the popup never gets a configure, so the
    // client never commits a buffer and the menu doesn't appear. This must
    // run even if the tracking alloc below fails, so the popup still shows.
    unconstrainPopup(server, root_view, popup);

    const p = server.zig_allocator.create(Popup) catch return;
    p.* = .{
        .server = server,
        .root_view = root_view,
        .scene_tree = scene_tree,
        .new_popup = makeListener(handlePopupNewPopup),
        .destroy = makeListener(handlePopupDestroy),
    };
    wlr.wl_signal_add(wlr.miozu_xdg_surface_new_popup(popup_surface), &p.new_popup);
    wlr.wl_signal_add(wlr.miozu_xdg_popup_destroy(popup), &p.destroy);
}

/// Constrain a popup to the active output. Box is in the ROOT toplevel's
/// surface-local coordinates (origin = output (0,0) minus the root view's
/// position). Multi-monitor with offset outputs would also subtract the
/// output's layout position: (output.x - vx, output.y - vy).
fn unconstrainPopup(server: *Server, root_view: *XdgView, popup: *wlr.wlr_xdg_popup) void {
    const slot = server.nodes.findById(root_view.node_id) orelse return;
    const vx = server.nodes.pos_x[slot];
    const vy = server.nodes.pos_y[slot];
    const dims = server.activeOutputDims();
    var constraint_box = wlr.wlr_box{
        .x = -vx,
        .y = -vy,
        .width = @intCast(dims.w),
        .height = @intCast(dims.h),
    };
    wlr.wlr_xdg_popup_unconstrain_from_box(popup, &constraint_box);
}

/// xdg_surface.new_popup handler on a TOPLEVEL — first-level popups (the
/// right-click / menubar menu itself).
fn handleNewPopup(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("new_popup", listener);
    const popup: *wlr.wlr_xdg_popup = @ptrCast(@alignCast(data orelse return));
    setupPopup(view.server, view, view.scene_tree, popup);
}

/// xdg_surface.new_popup handler on a POPUP — submenus / nested popups. Their
/// scene tree must nest under the parent popup's tree, and they keep the same
/// root_view so unconstrain stays in root-toplevel coordinates.
fn handlePopupNewPopup(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const p: *Popup = @fieldParentPtr("new_popup", listener);
    const popup: *wlr.wlr_xdg_popup = @ptrCast(@alignCast(data orelse return));
    setupPopup(p.server, p.root_view, p.scene_tree, popup);
}

/// xdg_popup.destroy handler — unhook our listeners + free the tracking struct.
/// The scene tree is owned by the wlr_scene helper, which tears it down on the
/// same surface-destroy; we must not touch it here.
fn handlePopupDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const p: *Popup = @fieldParentPtr("destroy", listener);
    wlr.wl_list_remove(&p.new_popup.link);
    wlr.wl_list_remove(&p.destroy.link);
    p.server.zig_allocator.destroy(p);
}

/// xdg_toplevel.show_window_menu handler. Toggle floating on the
/// requesting toplevel.
fn handleShowWindowMenu(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("show_window_menu", listener);
    const server = view.server;
    const slot = server.nodes.findByToplevel(view.toplevel) orelse return;

    server.nodes.floating[slot] = !server.nodes.floating[slot];
    const now_float = server.nodes.floating[slot];
    std.log.scoped(.compositor).debug("show_window_menu node={d} float={}", .{ view.node_id, now_float });

    if (now_float) {
        const ws = server.nodes.workspace[slot];
        if (ws < 10) server.layout_engine.workspaces[ws].removeNode(view.node_id);
        const cx = wlr.miozu_cursor_x(server.cursor);
        const cy = wlr.miozu_cursor_y(server.cursor);
        server.nodes.applyRect(slot, @intFromFloat(cx - 200), @intFromFloat(cy - 24), server.nodes.width[slot], server.nodes.height[slot]);
    } else {
        const ws = server.nodes.workspace[slot];
        if (ws < 10) server.layout_engine.workspaces[ws].addNode(server.zig_allocator, view.node_id) catch {};
    }
    server.arrangeworkspace(server.layout_engine.active_workspace);
    if (server.bar) |b| _ = b.render(server);
}

/// xdg_toplevel.request_move handler. CSD titlebar drag — float the
/// window and start an interactive move grab at the cursor position.
fn handleRequestMove(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("request_move", listener);
    const server = view.server;
    const slot = server.nodes.findByToplevel(view.toplevel) orelse return;

    if (!server.nodes.floating[slot]) {
        const ws = server.nodes.workspace[slot];
        if (ws < 10) server.layout_engine.workspaces[ws].removeNode(view.node_id);
        server.nodes.floating[slot] = true;
        const cx = wlr.miozu_cursor_x(server.cursor);
        const cy = wlr.miozu_cursor_y(server.cursor);
        const cur_w = server.nodes.width[slot];
        const cur_h = server.nodes.height[slot];
        const fw: u32 = if (cur_w > 0) cur_w else server.wm_config.float_default_w;
        const fh: u32 = if (cur_h > 0) cur_h else server.wm_config.float_default_h;
        server.nodes.applyRect(slot, @intFromFloat(cx - @as(f64, @floatFromInt(fw)) / 2.0), @intFromFloat(cy - @as(f64, @floatFromInt(fh)) / 2.0), fw, fh);
        server.arrangeworkspace(server.layout_engine.active_workspace);
        if (server.bar) |b| _ = b.render(server);
    }

    server.cursor_mode = .move;
    server.grab_node_id = view.node_id;
    server.grab_x = wlr.miozu_cursor_x(server.cursor) - @as(f64, @floatFromInt(server.nodes.pos_x[slot]));
    server.grab_y = wlr.miozu_cursor_y(server.cursor) - @as(f64, @floatFromInt(server.nodes.pos_y[slot]));
}

/// xdg_toplevel.request_resize handler. CSD edge drag — float the
/// window and start an interactive resize grab at the cursor position.
fn handleRequestResize(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XdgView = @fieldParentPtr("request_resize", listener);
    const server = view.server;
    const slot = server.nodes.findByToplevel(view.toplevel) orelse return;

    if (!server.nodes.floating[slot]) {
        const ws = server.nodes.workspace[slot];
        if (ws < 10) server.layout_engine.workspaces[ws].removeNode(view.node_id);
        server.nodes.floating[slot] = true;
        const cx = wlr.miozu_cursor_x(server.cursor);
        const cy = wlr.miozu_cursor_y(server.cursor);
        const cur_w = server.nodes.width[slot];
        const cur_h = server.nodes.height[slot];
        const fw: u32 = if (cur_w > 0) cur_w else server.wm_config.float_default_w;
        const fh: u32 = if (cur_h > 0) cur_h else server.wm_config.float_default_h;
        server.nodes.applyRect(slot, @intFromFloat(cx - @as(f64, @floatFromInt(fw)) / 2.0), @intFromFloat(cy - @as(f64, @floatFromInt(fh)) / 2.0), fw, fh);
        server.arrangeworkspace(server.layout_engine.active_workspace);
        if (server.bar) |b| _ = b.render(server);
    }

    server.cursor_mode = .resize;
    server.grab_node_id = view.node_id;
    server.grab_x = wlr.miozu_cursor_x(server.cursor);
    server.grab_y = wlr.miozu_cursor_y(server.cursor);
    server.grab_w = server.nodes.width[slot];
    server.grab_h = server.nodes.height[slot];
}
// ── Helper ─────────────────────────────────────────────────────

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}
