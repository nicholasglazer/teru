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
/// True while an override-redirect popup holds the seat keyboard (search
/// fields inside Steam/CEF dropdowns). Unmap restores focus to the parent.
took_keyboard_focus: bool = false,

// Listeners
map_listener: wlr.wl_listener,
unmap_listener: wlr.wl_listener,
destroy_listener: wlr.wl_listener,
configure_listener: wlr.wl_listener,
geometry_listener: wlr.wl_listener,
fullscreen_listener: wlr.wl_listener,
override_redirect_listener: wlr.wl_listener,
/// Armed per map cycle on the scene tree's node. A subsurface tree
/// destroys ITSELF when its wl_surface dies, which can precede the
/// dissociate event (xwayland teardown at quit/hot-restart, X client
/// crash) — this listener nulls `scene_tree` so unmap/destroy never
/// double-destroy a dangling node (was a 0x39 segfault in the quit path).
scene_destroy_listener: wlr.wl_listener,

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
        .geometry_listener = makeListener(handleSetGeometry),
        .fullscreen_listener = makeListener(handleRequestFullscreen),
        .override_redirect_listener = makeListener(handleSetOverrideRedirect),
        .scene_destroy_listener = makeListener(handleSceneTreeDestroy),
    };

    wlr.wl_signal_add(wlr.miozu_xwayland_surface_map(surface), &view.map_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_unmap(surface), &view.unmap_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_destroy(surface), &view.destroy_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_request_configure(surface), &view.configure_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_set_geometry(surface), &view.geometry_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_request_fullscreen(surface), &view.fullscreen_listener);
    wlr.wl_signal_add(wlr.miozu_xwayland_surface_set_override_redirect(surface), &view.override_redirect_listener);

    return view;
}

fn handleMap(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("map_listener", listener);
    mapView(view);
}

fn mapView(view: *XwaylandView) void {
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

        // Keyboard for O-R popups that want it (ICCCM input hint / window
        // type — wlroots computes this): Steam/CEF dropdowns contain live
        // search fields. Keyboard only, no activate — the parent window
        // must stay "the focused window" or opening a menu would visually
        // defocus (and in CEF's case, dismiss) it. Mirrors sway's
        // unmanaged-surface model.
        if (is_or and wlr.wlr_xwayland_or_surface_wants_focus(view.surface)) {
            seatKeyboardEnter(server, wlr_surface);
            view.took_keyboard_focus = true;
        }
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
                // WM_CLASS as app_id — dropFullscreenForNewWindowOn's
                // same-app guard (and the focus guard below) match on it;
                // without this every X11 node reads "" and a fullscreen
                // X11 game is kicked out by its own secondary windows.
                if (class) |c| server.nodes.setAppId(slot, std.mem.sliceTo(c, 0));
            }
        }
        // Same fullscreen reconciliation as the XDG tiled path: a real tiled X11
        // window joining the fullscreen workspace drops fullscreen first, so the
        // re-tile below produces a clean, bar-restored layout instead of a broken
        // half-fullscreen one. The wants_floating branch above is the dialog/HUD
        // case and intentionally floats over fullscreen.
        server.dropFullscreenForNewWindowOn(ws, if (class) |c| std.mem.sliceTo(c, 0) else "");

        server.layout_engine.workspaces[ws].addNode(server.zig_allocator, view.node_id) catch return;

        std.log.scoped(.compositor).info("X11 surface mapped class='{s}' node={d} ws={d}", .{ class orelse "none", view.node_id, ws });

        server.arrangeworkspace(ws);

        // Give the newly-mapped X11 client keyboard focus. Without
        // this, Emacs maps and the seat never calls keyboard_enter on
        // it — typing goes nowhere and the user thinks the window is
        // frozen. Match the XdgView auto-focus-on-map behaviour —
        // including its same-app-as-fullscreen skip: a fullscreen X11
        // game's own secondary window (Steam chat/news, same WM_CLASS)
        // must not steal focus from it. Computed AFTER
        // dropFullscreenForNewWindowOn, so a different-app map (which
        // just dropped fullscreen) still focuses normally.
        const cls_slice: []const u8 = if (class) |c| std.mem.sliceTo(c, 0) else "";
        const same_app_as_fullscreen = blk: {
            const fs = server.fullscreen_node orelse break :blk false;
            const fslot = server.nodes.findById(fs) orelse break :blk false;
            break :blk cls_slice.len > 0 and std.mem.eql(u8, cls_slice, server.nodes.getAppId(fslot));
        };
        if (!same_app_as_fullscreen) server.focusXwaylandSurface(view.surface);

        // Come-up-fullscreen: games set _NET_WM_STATE_FULLSCREEN before
        // mapping, so request_fullscreen fired while node_id was still 0
        // and couldn't be honoured. The surface's fullscreen flag holds
        // the pending state — drive it now (same as XdgView's map path).
        if (wlr.miozu_xwayland_surface_fullscreen(view.surface)) {
            wlr.wlr_xwayland_surface_set_fullscreen(view.surface, true);
            server.enterFullscreen(view.node_id);
        }
    }
}

fn handleUnmap(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("unmap_listener", listener);
    unmapView(view);
}

fn unmapView(view: *XwaylandView) void {
    const server = view.server;
    view.mapped = false;

    // A closing O-R popup that held the seat keyboard hands it back to
    // the focused X11 window. wlroots clears keyboard focus when the
    // popup's surface dies; without the explicit re-enter the parent
    // stops receiving keys until the next click.
    if (view.took_keyboard_focus) {
        view.took_keyboard_focus = false;
        if (server.focused_xwayland) |parent_xw| {
            if (parent_xw != view.surface) {
                if (wlr.miozu_xwayland_surface_surface(parent_xw)) |ps| {
                    seatKeyboardEnter(server, ps);
                }
            }
        } else if (server.focused_view) |v| {
            // XOR invariant: focused_xwayland==null + focused_view!=null
            // means a Wayland-native toplevel is the logically-focused
            // window (a background X app's popup grabbed the keyboard
            // over it). Re-enter its root surface, else it stays
            // keyboard-dead until the next click.
            if (wlr.miozu_xdg_toplevel_base(v.toplevel)) |base| {
                if (wlr.miozu_xdg_surface_surface(base)) |ps| {
                    seatKeyboardEnter(server, ps);
                }
            }
        }
    }

    // Destroy the scene tree — handleMap recreates it on the next map. Without
    // this, an unmap→remap (menus, tooltips, dialogs that hide/show) leaked the
    // old tree and stacked a second one for the same surface. If the wl_surface
    // died before dissociate (xwayland teardown, client crash), the subsurface
    // tree already destroyed itself and handleSceneTreeDestroy nulled the
    // pointer — the destroy below is skipped instead of hitting freed memory.
    if (view.scene_tree) |tree| {
        if (wlr.miozu_scene_tree_node(tree)) |node| wlr.wlr_scene_node_destroy(node);
        // handleSceneTreeDestroy fires synchronously inside the destroy
        // above and nulls view.scene_tree + disarms the listener.
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
    // The node registration died with this unmap. Reset the id so a remap
    // that lands in the floating branch (set_override_redirect toggle)
    // doesn't carry a stale tiled id — handleSetGeometry, handleConfigure
    // and handleRequestFullscreen all key float-vs-tile off node_id, and
    // enterFullscreen(stale_id) hides every node + both bars. Must stay
    // AFTER clearFocusRefs above; mapView's tiled branch always assigns a
    // fresh id (ids start at 1, so 0 is the canonical "not tiled").
    view.node_id = 0;
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
    wlr.wl_list_remove(&view.geometry_listener.link);
    wlr.wl_list_remove(&view.fullscreen_listener.link);
    wlr.wl_list_remove(&view.override_redirect_listener.link);

    // Destroy-without-dissociate safety: if the scene tree still exists,
    // destroy it now so the armed scene_destroy_listener can never fire
    // into this view's freed memory later (display-destroy walker).
    if (view.scene_tree) |tree| {
        if (wlr.miozu_scene_tree_node(tree)) |node| wlr.wlr_scene_node_destroy(node);
    }

    server.zig_allocator.destroy(view);
}

/// The scene tree's node died — either because unmapView destroyed it
/// (normal path; this fires synchronously inside that call) or because
/// the subsurface tree destroyed itself when its wl_surface died before
/// dissociate (xwayland teardown at quit/hot-restart, X client crash).
/// Null the reference and disarm so nothing touches the freed node.
fn handleSceneTreeDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("scene_destroy_listener", listener);
    wlr.wl_list_remove(&view.scene_destroy_listener.link);
    view.scene_tree = null;
    // The node registry mirrors this pointer (Node.scene_tree[slot]) for the
    // visibility/layout passes. Null the mirror too: unmapView destroys the
    // tree BEFORE clearFocusRefs, and clearFocusRefs → exitFullscreen →
    // recomputeVisibility → setSlotVisible would set_enabled the freed node.
    // Observed live as a hot-restart segfault (mod+' with fullscreen
    // steam_app: destroyXwayland unmaps while fullscreen_node is still set);
    // the same window exists for any X11 surface that unmaps while
    // fullscreen without politely un-fullscreening first.
    // Same for the border rects: they are CHILDREN of this tree
    // (Node.setBorder creates them with wlr_scene_rect_create(tree, ...)),
    // and wlr_scene_node_destroy frees children recursively — so they died
    // just now too. Leaving the pointers would make nodes.remove →
    // destroyBorderRects double-destroy freed rects a few lines after the
    // setSlotVisible hazard above (any bordered, i.e. non-solo, X11 window).
    if (view.node_id > 0) {
        if (view.server.nodes.findById(view.node_id)) |slot| {
            view.server.nodes.scene_tree[slot] = null;
            for (&view.server.nodes.border_rects[slot]) |*rect| rect.* = null;
        }
    }
}

/// ConfigureRequest from a managed X11 window. The client gets NOTHING
/// (no ConfigureNotify) unless the compositor answers — Steam dialogs
/// that self-center/self-resize post-map sat frozen at their initial
/// geometry because only the (dead — O-R windows bypass ConfigureRequest
/// redirection entirely) override-redirect branch ever answered.
///
/// Policy, same as sway: floating windows are granted exactly what they
/// asked for; tiled windows are re-sent their current layout rect so the
/// client at least receives a ConfigureNotify and stops waiting.
fn handleConfigure(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("configure_listener", listener);
    const server = view.server;
    const ev: *wlr.wlr_xwayland_surface_configure_event = @ptrCast(@alignCast(data orelse return));

    if (view.node_id > 0) {
        if (server.nodes.findById(view.node_id)) |slot| {
            // Same truncate/saturate casts as Node.applyRect — raw
            // @intCast would Debug-panic on multi-output coords > i16.
            const w = server.nodes.width[slot];
            const h = server.nodes.height[slot];
            const ww: u16 = if (w > 0xFFFF) 0xFFFF else @intCast(w);
            const hh: u16 = if (h > 0xFFFF) 0xFFFF else @intCast(h);
            wlr.wlr_xwayland_surface_configure(
                view.surface,
                @truncate(server.nodes.pos_x[slot]),
                @truncate(server.nodes.pos_y[slot]),
                ww,
                hh,
            );
            return;
        }
    }

    // Floating (or not-yet-mapped) window: honour the request. wlroots
    // 0.18 pre-writes xsurface->x/y/w/h before sending the X11 configure
    // (xwm.c:1809), so the resulting ConfigureNotify matches the cache
    // and set_geometry is NEVER emitted for grants the compositor itself
    // made — move the scene node synchronously here. handleSetGeometry
    // still covers O-R self-moves, which bypass redirection and do emit.
    const x = wlr.miozu_xwayland_configure_event_x(ev);
    const y = wlr.miozu_xwayland_configure_event_y(ev);
    wlr.wlr_xwayland_surface_configure(
        view.surface,
        x,
        y,
        wlr.miozu_xwayland_configure_event_width(ev),
        wlr.miozu_xwayland_configure_event_height(ev),
    );
    if (view.mapped) {
        if (view.scene_tree) |tree| {
            if (wlr.miozu_scene_tree_node(tree)) |node| {
                wlr.wlr_scene_node_set_position(node, x, y);
                server.scheduleRender();
            }
        }
    }
}

/// Geometry actually changed (xwm finished the round-trip, or an O-R
/// window moved itself via XMoveWindow — Steam menus, tooltips tracking
/// the cursor, CEF dropdown repositioning). Tiled windows are owned by
/// the layout; floating scene nodes must follow the surface or they
/// render at stale coords with misaligned pointer input.
fn handleSetGeometry(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("geometry_listener", listener);
    if (view.node_id > 0 or !view.mapped) return;
    const tree = view.scene_tree orelse return;
    const node = wlr.miozu_scene_tree_node(tree) orelse return;
    wlr.wlr_scene_node_set_position(
        node,
        wlr.miozu_xwayland_surface_x(view.surface),
        wlr.miozu_xwayland_surface_y(view.surface),
    );
    view.server.scheduleRender();
}

/// _NET_WM_STATE_FULLSCREEN request (Steam Big Picture, games launched
/// under the same Xwayland). Ack the state and drive teruwm's fullscreen
/// for tiled windows — the same contract XdgView.handleRequestFullscreen
/// implements for Wayland-native clients.
fn handleRequestFullscreen(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("fullscreen_listener", listener);
    const server = view.server;
    const want = wlr.miozu_xwayland_surface_fullscreen(view.surface);
    std.log.scoped(.compositor).info("X11 fullscreen request node={d} want={}", .{ view.node_id, want });
    wlr.wlr_xwayland_surface_set_fullscreen(view.surface, want);
    if (view.node_id == 0) return; // floating/pre-map: state acked; map path drives pre-map fullscreen
    if (want) {
        server.focusXwaylandSurface(view.surface);
        server.enterFullscreen(view.node_id);
    } else if (server.fullscreen_node == view.node_id) {
        server.exitFullscreen();
    }
    server.scheduleRender();
}

/// Client toggled the override-redirect attribute on a live window —
/// CEF (Steam's UI toolkit) does this for popups. The float-vs-tile
/// decision was made at map time, so remap to re-evaluate it; otherwise
/// a window that became O-R stays tiled (or vice versa) with stale
/// input/geometry treatment.
fn handleSetOverrideRedirect(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const view: *XwaylandView = @fieldParentPtr("override_redirect_listener", listener);
    if (!view.mapped) return;
    unmapView(view);
    mapView(view);
}

/// Route the seat keyboard to `target` without touching the activate /
/// focused_* bookkeeping — used for O-R popups where the parent must stay
/// the logically-focused window. Same enter sequence as focusXwaylandSurface.
fn seatKeyboardEnter(server: *Server, target: *wlr.wlr_surface) void {
    // Surface-liveness invariant (see "Known crash patterns" in CLAUDE.md):
    // never seat-notify a surface whose resource is mid-teardown — during
    // xwayland destroy the parent can die before its popup's dissociate.
    if (wlr.miozu_surface_is_live(target) == 0) return;
    const kb_opt = wlr.miozu_seat_get_keyboard(server.seat);
    const modifiers: ?*anyopaque = if (kb_opt) |kb| wlr.miozu_keyboard_modifiers_ptr(kb) else null;
    const keycodes: ?[*]const u32 = if (kb_opt) |kb| wlr.miozu_keyboard_keycodes(kb) else null;
    const num_keycodes: usize = if (kb_opt) |kb| wlr.miozu_keyboard_num_keycodes(kb) else 0;
    wlr.wlr_seat_keyboard_notify_enter(server.seat, target, keycodes, num_keycodes, modifiers);
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
