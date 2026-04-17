//! Pointer handling for teruwm.
//!
//! Cursor path summary:
//!
//!   listener → handleCursorMotion / handleCursorButton / etc.
//!          → processCursorMotion / processCursorButton
//!          → endGrab / tryBeginFloatDrag / tryBeginBorderDrag /
//!            forwardAndFocus (seat notify + focus update)
//!          → fallbackPointerToTiledView (hit-test misses)
//!
//! processCursorMotion + processCursorButton are pub free functions
//! so ServerMouse (the MCP human-like mouse tool) can drive synthetic
//! pointer events through the same dispatch as libinput.
//!
//! Invariants this file upholds:
//!
//!   * ALWAYS latch `last_pointer_surface` on every motion that
//!     reaches a live surface — focusView's leaf-subsurface target
//!     depends on it.
//!   * Every button notify is followed by a frame notify.
//!   * Focus update precedes the button notify (chromium Ozone state
//!     machine bug: configure+enter must arrive before the triggering
//!     press).
//!   * request_set_cursor is rejected from any client that doesn't
//!     own pointer focus, and from any stale (resource-destroyed)
//!     surface — see `miozu_surface_is_live`.

const std = @import("std");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const XdgView = @import("XdgView.zig");
const NodeRegistry = @import("Node.zig");

// ── Signal handlers ──────────────────────────────────────────

pub fn handleCursorMotion(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_motion", listener);
    const event: *wlr.wlr_pointer_motion_event = @ptrCast(@alignCast(data orelse return));
    wlr.wlr_cursor_move(server.cursor, null, wlr.miozu_pointer_motion_dx(event), wlr.miozu_pointer_motion_dy(event));
    server.notifyActivity();
    processCursorMotion(server, wlr.miozu_pointer_motion_time(event));
}

pub fn handleCursorMotionAbsolute(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_motion_absolute", listener);
    const event: *wlr.wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data orelse return));
    wlr.wlr_cursor_warp_absolute(server.cursor, null, wlr.miozu_pointer_motion_abs_x(event), wlr.miozu_pointer_motion_abs_y(event));
    server.notifyActivity();
    processCursorMotion(server, wlr.miozu_pointer_motion_abs_time(event));
}

pub fn handleCursorButton(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_button", listener);
    const event: *wlr.wlr_pointer_button_event = @ptrCast(@alignCast(data orelse return));
    server.notifyActivity();
    processCursorButton(
        server,
        wlr.miozu_pointer_button_button(event),
        wlr.miozu_pointer_button_state(event),
        wlr.miozu_pointer_button_time(event),
        null, // null = read live xkb state
    );
}

pub fn handleCursorAxis(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_axis", listener);
    const event: *wlr.wlr_pointer_axis_event = @ptrCast(@alignCast(data orelse return));
    server.notifyActivity();

    const orientation = wlr.miozu_pointer_axis_orientation(event);
    const delta = wlr.miozu_pointer_axis_delta(event);

    if (orientation == 0 and server.focused_terminal != null) {
        const tp = server.focused_terminal.?;
        const max_offset: u32 = @intCast(tp.pane.scrollback.total_lines);
        if (max_offset > 0) {
            const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
            const scroll_lines: i32 = if (delta > 0) 3 else -3;
            const pixel_delta: i32 = scroll_lines * @as(i32, @intCast(cell_h));

            // Scroll-offset math runs in i32 so the carry-over loops
            // can decrement below zero before clamping. u32→i32 on
            // scroll_offset is safe: grid.rows × scrollback_lines is
            // bounded at ~O(10^6), well under i32::MAX. Clamp the
            // maximum (u32) explicitly to i32::MAX before the
            // comparison so nothing silently wraps.
            var new_pixel = tp.pane.scroll_pixel + pixel_delta;
            var new_offset: i32 = @intCast(@min(tp.pane.scroll_offset, @as(u32, std.math.maxInt(i32))));
            const max_offset_i32: i32 = @intCast(@min(max_offset, @as(u32, std.math.maxInt(i32))));
            const ch: i32 = @intCast(cell_h);

            while (new_pixel >= ch) {
                new_pixel -= ch;
                new_offset += 1;
            }
            while (new_pixel < 0) {
                new_pixel += ch;
                new_offset -= 1;
            }

            if (new_offset < 0) {
                new_offset = 0;
                new_pixel = 0;
            }
            if (new_offset > max_offset_i32) {
                new_offset = max_offset_i32;
                new_pixel = 0;
            }

            tp.pane.scroll_offset = @intCast(new_offset);
            tp.pane.scroll_pixel = new_pixel;
            // Scroll moves the whole viewport — every row's content is
            // different. markAllDirty keeps the dirty range tracking
            // consistent with the "range-invalidates full paint"
            // semantics the renderer already has, without the
            // implicit-fallback cost.
            tp.pane.grid.markAllDirty();
            tp.render();
            return;
        }
    }

    wlr.wlr_seat_pointer_notify_axis(
        server.seat,
        wlr.miozu_pointer_axis_time(event),
        orientation,
        delta,
        wlr.miozu_pointer_axis_delta_discrete(event),
        wlr.miozu_pointer_axis_source(event),
        0,
    );
}

pub fn handleCursorFrame(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_frame", listener);
    wlr.wlr_seat_pointer_notify_frame(server.seat);
}

/// request_set_cursor guard. Only the client that currently owns
/// pointer focus may set the cursor image. Before v0.4.25 we accepted
/// from ANY client — a defocused chromium pushing a stale wlr_surface
/// built a scene-cursor node whose invariant (`active_outputs implies
/// primary_output`) blew up on the next cursor-motion scene update
/// (coredump 429591, Shift+Alt trigger).
pub fn handleRequestSetCursor(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "request_set_cursor", listener);
    const event_ptr = data orelse return;

    if (wlr.miozu_set_cursor_event_from_focused(event_ptr, server.seat) == 0) return;

    const surface = wlr.miozu_set_cursor_event_surface(event_ptr);
    const hx = wlr.miozu_set_cursor_event_hotspot_x(event_ptr);
    const hy = wlr.miozu_set_cursor_event_hotspot_y(event_ptr);
    if (surface) |s| {
        if (wlr.miozu_surface_is_live(s) == 0) return; // stale surface
        wlr.wlr_cursor_set_surface(server.cursor, s, hx, hy);
    } else {
        wlr.wlr_cursor_set_surface(server.cursor, null, 0, 0);
    }
}

/// wp_cursor_shape_v1.request_set_shape — the modern alternative to
/// wl_pointer.set_cursor(surface). Chromium/GTK send the requested shape
/// as an enum (default, text, pointer, grab, resize_*, etc.) and we map
/// that to an xcursor theme name so wlr_cursor can draw it. Without this
/// path hovering over links / text inputs / resize edges in a browser
/// leaves the default arrow — looks broken even when clicks land.
pub fn handleRequestSetShape(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "request_set_shape", listener);
    const event_ptr: *wlr.wlr_cursor_shape_manager_v1_request_set_shape_event =
        @ptrCast(@alignCast(data orelse return));

    // Same focused-client gate as request_set_cursor — a stale client
    // pushing a shape after losing focus mustn't override the live one.
    if (wlr.miozu_cursor_shape_event_from_focused(event_ptr, server.seat) == 0) return;

    const shape = wlr.miozu_cursor_shape_event_shape(event_ptr);
    const name_ptr = wlr.miozu_cursor_shape_name(shape) orelse return;
    wlr.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, name_ptr);
}

// ── Button dispatch ──────────────────────────────────────────

/// Pointer button dispatch. Shared by wlroots and MCP test tools.
/// `super_override = null` reads live xkb state; `true/false` forces
/// the Super-held value (E2E tests + ServerMouse synthetic clicks).
///
/// Split into four phases; the parent just sequences them. Each sub-
/// function returns true if it claimed the event.
pub fn processCursorButton(server: *Server, button: u32, state: u32, time: u32, super_override: ?bool) void {
    if (state == 0) {
        endGrab(server, button, state, time);
        return;
    }

    const cx = wlr.miozu_cursor_x(server.cursor);
    const cy = wlr.miozu_cursor_y(server.cursor);
    const super_held = readSuperHeld(server, super_override);

    if (super_held and tryBeginFloatDrag(server, button, cx, cy)) return;
    if (!super_held and tryBeginBorderDrag(server, cx)) return;

    forwardAndFocus(server, button, state, time, super_held, cx, cy);
}

/// Phase A — button release. Drop any active grab, arrange if we
/// were border-dragging, flush button + frame to the seat.
fn endGrab(server: *Server, button: u32, state: u32, time: u32) void {
    if (server.cursor_mode == .border_drag) {
        server.arrangeworkspace(server.layout_engine.active_workspace);
    }
    if (server.cursor_mode != .normal) {
        server.cursor_mode = .normal;
        server.grab_node_id = null;
    }
    _ = wlr.wlr_seat_pointer_notify_button(server.seat, time, button, state);
    // Every button notify must be followed by a frame, or clients
    // that batch (chromium, GTK) never dispatch the click. libinput
    // normally sends it via cursor_frame, but MCP test events and
    // some touchpad timings bypass that — flush explicitly.
    wlr.wlr_seat_pointer_notify_frame(server.seat);
}

/// Read the effective Super-held bit. `override` from MCP test tools
/// skips the xkb state read (synthetic keyboards don't mirror it).
fn readSuperHeld(server: *Server, override: ?bool) bool {
    if (override) |v| return v;
    const keyboard = wlr.miozu_seat_get_keyboard(server.seat) orelse return false;
    const xkb_st = wlr.miozu_keyboard_xkb_state(keyboard) orelse return false;
    return wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;
}

/// Phase B — Super+click initiates move (LEFT) or resize (RIGHT) on
/// the pane under the cursor. Auto-floats a still-tiled pane first
/// so the drag starts under the cursor instead of snapping to center.
fn tryBeginFloatDrag(server: *Server, button: u32, cx: f64, cy: f64) bool {
    const nid: u64 = server.nodeAtPoint(cx, cy) orelse
        (if (server.focused_terminal) |tp|
            tp.node_id
        else if (server.focused_view) |view|
            view.node_id
        else
            return false);

    const slot = server.nodes.findById(nid) orelse return false;

    if (!server.nodes.floating[slot]) {
        const cur_w = server.nodes.width[slot];
        const cur_h = server.nodes.height[slot];
        const float_w: u32 = if (cur_w > 0) cur_w else server.wm_config.float_default_w;
        const float_h: u32 = if (cur_h > 0) cur_h else server.wm_config.float_default_h;
        const fx: i32 = @intFromFloat(cx - @as(f64, @floatFromInt(float_w)) / 2.0);
        const fy: i32 = @intFromFloat(cy - @as(f64, @floatFromInt(float_h)) / 2.0);

        server.nodes.floating[slot] = true;
        server.layout_engine.workspaces[server.layout_engine.active_workspace].removeNode(nid);
        server.nodes.applyRect(slot, fx, fy, float_w, float_h);
        if (server.nodes.kind[slot] == .terminal) {
            if (server.terminalPaneById(nid)) |tp| tp.resize(float_w, float_h);
        }
        server.arrangeworkspace(server.layout_engine.active_workspace);
    }

    if (button == 272) { // BTN_LEFT: move
        server.cursor_mode = .move;
        server.grab_node_id = nid;
        server.grab_x = cx - @as(f64, @floatFromInt(server.nodes.pos_x[slot]));
        server.grab_y = cy - @as(f64, @floatFromInt(server.nodes.pos_y[slot]));
        return true;
    } else if (button == 274) { // BTN_RIGHT: resize
        server.cursor_mode = .resize;
        server.grab_node_id = nid;
        server.grab_x = cx;
        server.grab_y = cy;
        server.grab_w = server.nodes.width[slot];
        server.grab_h = server.nodes.height[slot];
        return true;
    }
    return false;
}

/// Phase C — click on the gap between tiled panes starts a master-
/// ratio drag. Returns true on hit.
fn tryBeginBorderDrag(server: *Server, cx: f64) bool {
    const ws = server.layout_engine.getActiveWorkspace();
    if (ws.node_ids.items.len < 2) return false;

    const cursor_x: i32 = @intFromFloat(cx);
    const ins = server.wm_config.border_drag_insensitive_px;
    const zone = server.wm_config.border_drag_zone_px;

    for (server.terminal_panes) |maybe_tp| {
        const tp = maybe_tp orelse continue;
        const slot = server.nodes.findById(tp.node_id) orelse continue;
        const px = server.nodes.pos_x[slot];
        const pw: i32 = @intCast(server.nodes.width[slot]);
        const right_edge = px + pw;
        if (cursor_x >= right_edge - ins and cursor_x <= right_edge + zone) {
            server.cursor_mode = .border_drag;
            server.grab_x = cx;
            return true;
        }
    }
    return false;
}

/// Phase D — forward the button + frame, then update keyboard focus
/// to the clicked node.
///
/// CRITICAL ORDERING: focus update FIRST, then button. Chromium's
/// Ozone state machine expects xdg_toplevel.configure(activated=true)
/// + keyboard.enter to arrive BEFORE the button that triggered the
/// focus change. With the previous button-first order, chromium
/// received configure+enter in the SAME batch as the press, ack'd
/// the configure first, and by the time it could handle the press
/// the release was already in a subsequent batch — click dispatcher
/// dropped the click as spurious.
fn forwardAndFocus(server: *Server, button: u32, state: u32, time: u32, super_held: bool, cx: f64, cy: f64) void {
    _ = super_held;

    if (state == 1) {
        if (server.nodeAtPoint(cx, cy)) |nid| {
            if (server.nodes.findById(nid)) |slot| {
                switch (server.nodes.kind[slot]) {
                    .terminal => focusTerminalByNode(server, nid),
                    .wayland_surface => {
                        if (server.nodes.xdg_view[slot]) |opaque_view| {
                            const view: *XdgView = @ptrCast(@alignCast(opaque_view));
                            server.focusView(view);
                            syncWsActiveIndex(&server.layout_engine.workspaces[server.layout_engine.active_workspace], nid);
                        } else if (server.nodes.xwayland_surface[slot]) |xw| {
                            // X11 clients (Emacs, Steam, ...) don't have
                            // an xdg_view. Route focus through the
                            // xwayland-specific path so key events
                            // actually reach the client.
                            server.focusXwaylandSurface(xw);
                            syncWsActiveIndex(&server.layout_engine.workspaces[server.layout_engine.active_workspace], nid);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    // Deliver the button event AFTER focus has been updated. Seat
    // routes to the (now-activated) surface; chromium sees
    // configure → enter → button as three ordered protocol events
    // rather than one batched frame.
    _ = wlr.wlr_seat_pointer_notify_button(server.seat, time, button, state);
    wlr.wlr_seat_pointer_notify_frame(server.seat);
}

/// Focus a terminal pane by node id: deactivate any prior XDG focus,
/// set focused_terminal, repaint borders, sync active_index.
fn focusTerminalByNode(server: *Server, nid: u64) void {
    const tp = server.terminalPaneById(nid) orelse return;
    if (server.focused_view) |prev_view| {
        _ = wlr.wlr_xdg_toplevel_set_activated(prev_view.toplevel, false);
    }
    const prev_focused = server.focused_terminal;
    server.focused_terminal = tp;
    server.focused_view = null;
    syncWsActiveIndex(server.layout_engine.getActiveWorkspace(), nid);
    // Only the two panes whose focus flipped need a border repaint —
    // full tp.render() on N panes was ~N×300 µs of pointless SIMD.
    if (prev_focused) |prev| {
        if (prev != tp) prev.repaintBorderOnly();
    }
    tp.repaintBorderOnly();
    if (server.bar) |b| b.render(server);
}

fn syncWsActiveIndex(ws: anytype, nid: u64) void {
    for (ws.node_ids.items, 0..) |id2, idx| {
        if (id2 == nid) {
            ws.active_index = @intCast(idx);
            return;
        }
    }
}

// ── Motion dispatch ──────────────────────────────────────────

pub fn processCursorMotion(server: *Server, time: u32) void {
    const cx = wlr.miozu_cursor_x(server.cursor);
    const cy = wlr.miozu_cursor_y(server.cursor);

    // Tiled border drag — update ratio, defer layout to frame callback.
    if (server.cursor_mode == .border_drag) {
        // Belt-and-suspenders against div-by-zero — activeOutputDims
        // already clamps to 1920 on zero-outputs, but a racing hotplug
        // during drag could theoretically slip through.
        const out_w: f64 = @floatFromInt(@max(@as(u32, 1), server.activeOutputDims().w));
        const delta = cx - server.grab_x;
        const ratio_delta: f32 = @floatCast(delta / out_w);
        const ws = server.layout_engine.getActiveWorkspace();
        ws.master_ratio = @max(0.1, @min(0.9, ws.master_ratio + ratio_delta));
        server.grab_x = cx;
        // Defer layout to frame callback — one arrange per vsync, not per motion.
        server.layout_dirty = true;
        server.scheduleRender();
        return;
    }

    // Floating move.
    if (server.cursor_mode == .move) {
        if (server.grab_node_id) |id| {
            // Defensive: if the grabbed node vanished (pane exit, client
            // crash), drop the grab rather than chase a stale id.
            if (server.nodes.findById(id) == null) {
                server.grab_node_id = null;
                server.cursor_mode = .normal;
                return;
            }
            if (server.nodes.findById(id)) |slot| {
                const new_x: i32 = @intFromFloat(cx - server.grab_x);
                const new_y: i32 = @intFromFloat(cy - server.grab_y);
                server.nodes.pos_x[slot] = new_x;
                server.nodes.pos_y[slot] = new_y;

                if (server.nodes.scene_tree[slot]) |tree| {
                    if (wlr.miozu_scene_tree_node(tree)) |node| {
                        wlr.wlr_scene_node_set_position(node, new_x, new_y);
                    }
                }
                if (server.nodes.kind[slot] == .terminal) {
                    if (server.terminalPaneById(id)) |tp| tp.setPosition(new_x, new_y);
                }
            }
        }
        return;
    }

    // Floating resize.
    if (server.cursor_mode == .resize) {
        if (server.grab_node_id) |id| {
            if (server.nodes.findById(id) == null) {
                server.grab_node_id = null;
                server.cursor_mode = .normal;
                return;
            }
            if (server.nodes.findById(id)) |slot| {
                const dx = cx - server.grab_x;
                const dy = cy - server.grab_y;
                const min: i64 = @intCast(server.wm_config.resize_min_px);
                const new_w: u32 = @intCast(@max(min, @as(i64, server.grab_w) + @as(i64, @intFromFloat(dx))));
                const new_h: u32 = @intCast(@max(min, @as(i64, server.grab_h) + @as(i64, @intFromFloat(dy))));
                server.nodes.width[slot] = new_w;
                server.nodes.height[slot] = new_h;

                if (server.nodes.kind[slot] == .wayland_surface) {
                    if (server.nodes.xdg_toplevel[slot]) |toplevel| {
                        _ = wlr.wlr_xdg_toplevel_set_size(toplevel, new_w, new_h);
                    }
                }
                // Defer terminal pane resize to frame callback (avoids
                // buffer realloc per motion).
                if (server.nodes.kind[slot] == .terminal) {
                    server.resize_pending_id = id;
                    server.resize_pending_w = new_w;
                    server.resize_pending_h = new_h;
                    server.scheduleRender();
                }
            }
        }
        return;
    }

    // Normal path — scene-graph hit test, then forward to surface.
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return;
    const root_node = wlr.miozu_scene_tree_node(scene_tree_root) orelse return;

    var sx: f64 = 0;
    var sy: f64 = 0;
    const node_under = wlr.wlr_scene_node_at(root_node, cx, cy, &sx, &sy);

    if (node_under) |scene_node| {
        // scene_node_at returns ANY visible node — buffer, rect, tree.
        // wlr_scene_buffer_from_node asserts on non-buffer nodes (the
        // node->type check at wlr_scene.c:38), so pre-filter via
        // miozu_scene_node_is_buffer. RECT nodes show up when the
        // cursor is over our bg_rect; TREE nodes appear during
        // float-toggle transitions.
        if (wlr.miozu_scene_node_is_buffer(scene_node) != 0) {
            // The motion→enter→notify chain asserts inside wlroots if
            // the surface resource has been freed (unmap race). Scene
            // buffers can out-live their surface briefly — guard with
            // miozu_surface_is_live (resource + mapped check).
            if (wlr.wlr_scene_buffer_from_node(scene_node)) |buffer| {
                if (wlr.wlr_scene_surface_try_from_buffer(buffer)) |scene_surface| {
                    if (wlr.miozu_scene_surface_get_surface(scene_surface)) |surface| {
                        // Chromium (Ozone) + some GTK4 apps paint
                        // content tiles as wl_subsurfaces with an
                        // EMPTY wl_surface.input_region. Wayland spec
                        // says an empty input region rejects pointer
                        // events and they must route via the parent.
                        // A bare scene hit-test cheerfully returned
                        // the subsurface, so enter/motion landed on a
                        // surface that never fires button handlers —
                        // and every click was silently dropped. This
                        // was the user-visible "can't click chromium"
                        // bug (2026-04-16 research, stash triaged
                        // 2026-04-17). Fix: require the surface to
                        // accept pointer input at (sx, sy); otherwise
                        // fall through to fallbackPointerToTiledView,
                        // which targets the toplevel root (whose
                        // input-region default is infinite).
                        if (wlr.miozu_surface_is_live(surface) != 0 and
                            wlr.wlr_surface_point_accepts_input(surface, sx, sy))
                        {
                            // ALWAYS latch last_pointer_surface (not
                            // just on change). focusView reads this to
                            // target the leaf surface for keyboard_enter.
                            server.last_pointer_surface = surface;
                            wlr.wlr_seat_pointer_notify_enter(server.seat, surface, sx, sy);
                            wlr.wlr_seat_pointer_notify_motion(server.seat, time, sx, sy);
                            // Chromium + GTK batch events until frame;
                            // libinput auto-flushes via cursor_frame,
                            // but synthetic MCP test_move bypasses
                            // that. Always flushing here is cheap.
                            wlr.wlr_seat_pointer_notify_frame(server.seat);
                            return;
                        }
                    }
                }
            }
        }
        // Scene node isn't a live client surface (bg_rect, tree
        // container, freed surface). Before giving up, check whether
        // the cursor is inside an XDG view's nominal tile rect — that
        // happens routinely while a client is mid-resize, its actual
        // wl_buffer covers only the top-left of the tile, and our
        // hit-test returns bg_rect instead of the client. Forward the
        // pointer to the view's root surface at clamped coords so
        // clicks register where the user expects.
        if (fallbackPointerToTiledView(server, cx, cy, time)) return;
        wlr.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, "default");
        wlr.wlr_seat_pointer_clear_focus(server.seat);
    } else {
        if (fallbackPointerToTiledView(server, cx, cy, time)) return;
        wlr.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, "default");
        wlr.wlr_seat_pointer_clear_focus(server.seat);
    }
}

/// On a motion hit-test miss, check whether (cx, cy) is inside any
/// mapped XDG view's tile rect. If so, deliver pointer enter/motion
/// to that view's root surface at clamped coords. Fix for "can't
/// click client area while it's still resizing to fill the tile".
fn fallbackPointerToTiledView(server: *Server, cx: f64, cy: f64, time: u32) bool {
    const ix: i32 = @intFromFloat(cx);
    const iy: i32 = @intFromFloat(cy);
    var i: u16 = 0;
    while (i < NodeRegistry.max_nodes) : (i += 1) {
        if (server.nodes.kind[i] != .wayland_surface) continue;
        if (server.nodes.workspace[i] != server.layout_engine.active_workspace) continue;
        const px = server.nodes.pos_x[i];
        const py = server.nodes.pos_y[i];
        const pw: i32 = @intCast(server.nodes.width[i]);
        const ph: i32 = @intCast(server.nodes.height[i]);
        if (ix < px or ix >= px + pw) continue;
        if (iy < py or iy >= py + ph) continue;

        const opaque_view = server.nodes.xdg_view[i] orelse continue;
        const view: *XdgView = @ptrCast(@alignCast(opaque_view));
        const surface = wlr.miozu_xdg_surface_surface(
            wlr.miozu_xdg_toplevel_base(view.toplevel) orelse continue,
        ) orelse continue;
        if (wlr.miozu_surface_is_live(surface) == 0) continue;

        // Clamp surface-local coords to (0, 0) — the surface's actual
        // buffer doesn't extend to (cx, cy), but the protocol still
        // requires we deliver coords. (0, 0) is harmless and lets
        // chromium's mousedown handler fire on its content area.
        const sx_local: f64 = @max(0, cx - @as(f64, @floatFromInt(px)));
        const sy_local: f64 = @max(0, cy - @as(f64, @floatFromInt(py)));
        server.last_pointer_surface = surface;
        wlr.wlr_seat_pointer_notify_enter(server.seat, surface, sx_local, sy_local);
        wlr.wlr_seat_pointer_notify_motion(server.seat, time, sx_local, sy_local);
        wlr.wlr_seat_pointer_notify_frame(server.seat);
        return true;
    }
    return false;
}
