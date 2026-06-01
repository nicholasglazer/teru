//! Per-XWayland-surface state for the teruwm compositor.
//!
//! Each X11 client window gets an XwaylandView that tracks its listeners
//! and scene node. Override-redirect windows (menus, tooltips) float
//! instead of tiling. Regular windows tile like XDG surfaces.

const std = @import("std");
const wlr = @import("wlr.zig");
const NodeRegistry = @import("Node.zig");
const Server = @import("Server.zig");

const XwaylandView = @This();

server: *Server,
surface: *wlr.wlr_xwayland_surface,
scene_tree: ?*wlr.wlr_scene_tree = null,
node_id: u64 = 0,
mapped: bool = false,

// Listeners
map_listener: wlr.wl_listener,
unmap_listener: wlr.wl_listener,
destroy_listener: wlr.wl_listener,
configure_listener: wlr.wl_listener,

pub fn create(server: *Server, surface: *wlr.wlr_xwayland_surface) ?*XwaylandView {
    const allocator = server.zig_allocator;

    const view = allocator.create(XwaylandView) catch return null;
    view.* = .{
        .server = server,
        .surface = surface,
        .map_listener = makeListener(handleMap),
        .unmap_listener = makeListener(handleUnmap),
        .destroy_listener = makeListener(handleDestroy),
        .configure_listener = makeListener(handleConfigure),
    };

    wlr.wl_signal_add(wlr.miozu_xwayland_surface_map(surface), &view.map_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_unmap(surface), &view.unmap_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_destroy(surface), &view.destroy_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_request_configure(surface), &view.configure_listener);

    return view;
}

fn handleMap(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("map_listener", listener);
    const server = view.server;

    // Get the wlr_surface to create a scene node
    const wlr_surface = wlr.miozu_xwayland_surface_surface(view.surface) orelse return;

    // Create scene surface under root tree
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return;
    view.scene_tree = wlr.wlr_scene_subsurface_tree_create(scene_tree_root, wlr_surface);
    view.mapped = true;

    const is_or = wlr.miozu_xwayland_surface_override_redirect(view.surface);
    const class = wlr.miozu_xwayland_surface_class(view.surface);

    // Auxiliary X11 windows (notifications, dialogs, fixed-size HUDs) are
    // NOT override-redirect but absolutely must not be tiled — dunst is
    // the canonical case. Detect the common shapes:
    //
    //   - Fixed size_hints (PMinSize == PMaxSize): dunst, dmenu, polybar,
    //     conky, slock, screenkey, lxqt-policykit-agent, etc.
    //   - transient_for / modal: file pickers, "About" boxes, file/save
    //     dialogs, GIMP toolboxes when in single-window mode.
    //   - Class allowlist: hard-coded fallback for clients that set a
    //     window-type atom but no size hint (we don't intern atoms here).
    //
    // Anything matching is treated like an override-redirect: we honour
    // its requested position + size and don't put it in the tiling list.
    const wants_floating = is_or
        or wlr.miozu_xwayland_surface_is_fixed_size(view.surface)
        or wlr.miozu_xwayland_surface_has_parent(view.surface)
        or wlr.miozu_xwayland_surface_is_modal(view.surface)
        or classIsAlwaysFloating(class);

    if (wants_floating) {
        // Position at client-requested coords, don't tile, don't put it
        // in the layout engine's node list.
        const x = wlr.miozu_xwayland_surface_x(view.surface);
        const y = wlr.miozu_xwayland_surface_y(view.surface);
        if (view.scene_tree) |tree| {
            if (wlr.miozu_scene_tree_node(tree)) |node| {
                wlr.wlr_scene_node_set_position(node, x, y);
            }
        }
        std.log.scoped(.compositor).info("X11 floating mapped class='{s}' or={} fixed={} parent={} modal={}", .{
            class orelse "none",
            is_or,
            wlr.miozu_xwayland_surface_is_fixed_size(view.surface),
            wlr.miozu_xwayland_surface_has_parent(view.surface),
            wlr.miozu_xwayland_surface_is_modal(view.surface),
        });
    } else {
        // Regular X11 window: tile like XDG surface
        // Check window rules for workspace assignment
        const ws = if (class) |cls|
            server.wm_config.matchRule(std.mem.sliceTo(cls, 0)) orelse server.layout_engine.active_workspace
        else
            server.layout_engine.active_workspace;

        view.node_id = server.next_node_id;
        server.next_node_id += 1;

        if (view.scene_tree) |tree| {
            if (server.nodes.addSurface(server.zig_allocator, view.node_id, ws, null, tree, null)) |slot| {
                // Distinguishes this node from XDG toplevels so applyRect
                // dispatches to wlr_xwayland_surface_configure — without
                // this, Emacs / Steam etc. never receive geometry and
                // stay at whatever pre-map size X assigned them (a 1x1
                // square in the top-left is the usual outcome).
                server.nodes.xwayland_surface[slot] = view.surface;
            }
        }
        server.layout_engine.workspaces[ws].addNode(server.zig_allocator, view.node_id) catch return;

        std.log.scoped(.compositor).info("X11 surface mapped class='{s}' node={d} ws={d}", .{ class orelse "none", view.node_id, ws });

        server.arrangeworkspace(ws);

        // Give the newly-mapped X11 client keyboard focus. Without
        // this, Emacs maps and the seat never calls keyboard_enter on
        // it — typing goes nowhere and the user thinks the window is
        // frozen. Match the XdgView auto-focus-on-map behaviour.
        server.focusXwaylandSurface(view.surface);
    }
}

fn handleUnmap(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("unmap_listener", listener);
    const server = view.server;
    view.mapped = false;

    // Destroy the scene tree — handleMap recreates it on the next map. Without
    // this, an unmap→remap (menus, tooltips, dialogs that hide/show) leaked the
    // old tree and stacked a second one for the same surface. wlr_scene_node_destroy
    // also drops the node's internal surface-destroy listener, so the later
    // surface-destroy won't double-free.
    if (view.scene_tree) |tree| {
        if (wlr.miozu_scene_tree_node(tree)) |node| wlr.wlr_scene_node_destroy(node);
        view.scene_tree = null;
    }

    server.clearFocusRefs(view.node_id);
    // If this xwayland surface currently held keyboard focus, clear
    // the pointer. closeFocused would otherwise dereference a dead
    // surface on the next Win+Shift+C press.
    if (server.focused_xwayland == view.surface) {
        server.focused_xwayland = null;
    }

    // Raw *wlr_surface — keyed off the surface itself, not node_id.
    if (wlr.miozu_xwayland_surface_surface(view.surface)) |s| {
        if (server.last_pointer_surface == s) server.last_pointer_surface = null;
    }

    if (view.node_id > 0) {
        const ws_index: ?u8 = if (server.nodes.findById(view.node_id)) |s|
            server.nodes.workspace[s]
        else
            null;
        _ = server.nodes.remove(view.node_id);
        for (&server.layout_engine.workspaces) |*ws| {
            ws.removeNode(view.node_id);
        }
        if (ws_index) |w| server.arrangeworkspace(w);
    }
}

fn handleDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("destroy_listener", listener);
    const server = view.server;

    server.clearFocusRefs(view.node_id);
    if (server.focused_xwayland == view.surface) {
        server.focused_xwayland = null;
    }
    if (wlr.miozu_xwayland_surface_surface(view.surface)) |s| {
        if (server.last_pointer_surface == s) server.last_pointer_surface = null;
    }

    if (view.node_id > 0) {
        // Capture workspace before removing — handleDestroy can fire
        // without a prior unmap on a hard client crash, so the unmap
        // path wouldn't have arranged.
        const ws_index: ?u8 = if (server.nodes.findById(view.node_id)) |s|
            server.nodes.workspace[s]
        else
            null;
        _ = server.nodes.remove(view.node_id);
        for (&server.layout_engine.workspaces) |*ws| {
            ws.removeNode(view.node_id);
        }
        if (ws_index) |w| server.arrangeworkspace(w);
    }

    wlr.wl_list_remove(&view.map_listener.link);
    wlr.wl_list_remove(&view.unmap_listener.link);
    wlr.wl_list_remove(&view.destroy_listener.link);
    wlr.wl_list_remove(&view.configure_listener.link);

    server.zig_allocator.destroy(view);
}

fn handleConfigure(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("configure_listener", listener);
    _ = data;

    // For tiled windows, we set the size from the layout engine.
    // For OR windows, accept the requested geometry.
    if (wlr.miozu_xwayland_surface_override_redirect(view.surface)) {
        const x = wlr.miozu_xwayland_surface_x(view.surface);
        const y = wlr.miozu_xwayland_surface_y(view.surface);
        const w = wlr.miozu_xwayland_surface_width(view.surface);
        const h = wlr.miozu_xwayland_surface_height(view.surface);
        wlr.wlr_xwayland_surface_configure(view.surface, x, y, w, h);
    }
}

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{ .link = .{ .prev = null, .next = null }, .notify = func };
}

/// Hard-coded allowlist of X11 WM_CLASS values that should always float.
/// Matched case-insensitively against `class`. Backstop for clients that
/// declare _NET_WM_WINDOW_TYPE_NOTIFICATION/etc. but no `size_hints` —
/// we don't intern X atoms here so a class-name compare is the cheap
/// path. Add new entries as users hit them.
fn classIsAlwaysFloating(class_z: ?[*:0]const u8) bool {
    const class_ptr = class_z orelse return false;
    const class = std.mem.span(class_ptr);
    if (class.len == 0) return false;
    const known = [_][]const u8{
        "Dunst",                 // dunst notification daemon
        "dunst",
        "dmenu",                 // suckless menu
        "Polybar",               // polybar status bar (rare under teruwm but harmless)
        "Conky",                 // conky monitor overlay
        "conky",
        "screenkey",             // on-screen key display
        "Screenkey",
        "Pavucontrol",           // pulseaudio mixer (always intended floating)
        "lxqt-policykit-agent",  // polkit prompt
        "Lxpolkit",
        "polkit-gnome-authentication-agent-1",
        "Xmessage",              // tiny X message dialogs
        "feh",                   // image viewer in floating mode
    };
    for (known) |k| {
        if (std.ascii.eqlIgnoreCase(class, k)) return true;
    }
    return false;
}
