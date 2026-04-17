//! Focus state transitions for teruwm.
//!
//! Every focus change — click-to-focus, keybind traversal, MCP
//! focus_window, workspace switch — funnels through one of these.
//! They preserve two load-bearing invariants:
//!
//!   1. focused_terminal XOR focused_view — never both non-null.
//!      Pre-v0.4.27 a click path forwarded keyboard focus but left
//!      the XOR violated; Win+X / Win+S then acted on the wrong
//!      window.
//!
//!   2. keyboard_notify_enter target = deepest subsurface under the
//!      cursor that shares the focused client. Without that, GTK /
//!      Chromium dispatch JS-level click events but leave
//!      document.activeElement on <body> — typing has nowhere to go.
//!      This was the "can't interact with chrome" bug from v0.4.26.
//!
//! Functions take *Server directly (Zig 0.16 split pattern).

const std = @import("std");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const XdgView = @import("XdgView.zig");
const NodeRegistry = @import("Node.zig");

/// Focus an xdg view — activate its toplevel, route keyboard focus.
///
/// Picks the keyboard-enter target carefully: prefer the leaf
/// subsurface the pointer last entered if it belongs to this view's
/// client, else fall back to the toplevel root. Passes live pressed-
/// keycodes + modifiers so mid-chord focus changes don't drop the
/// held modifier (IMEs + browsers both care).
///
/// No explicit wl_display_flush_clients — the event loop flushes on
/// its next iteration. Racing the activation configure here
/// interleaved button + configure + enter in the same client batch;
/// clients ack'd configure first and by the time they handled the
/// press the release was already in the next batch, so the click
/// dispatcher dropped it.
pub fn focusView(server: *Server, view: *XdgView) void {
    // Deactivate the previous focused view if different.
    if (server.focused_view) |prev| {
        if (prev != view) {
            _ = wlr.wlr_xdg_toplevel_set_activated(prev.toplevel, false);
            if (prev.ftl_handle) |h| {
                wlr.wlr_foreign_toplevel_handle_v1_set_activated(h, false);
            }
        }
    }

    _ = wlr.wlr_xdg_toplevel_set_activated(view.toplevel, true);
    if (view.ftl_handle) |h| wlr.wlr_foreign_toplevel_handle_v1_set_activated(h, true);
    const was_focused = (server.focused_view == view and server.focused_terminal == null);
    server.focused_view = view;
    server.focused_terminal = null;
    if (!was_focused) {
        std.debug.print("teruwm: focusView ran node={d} focused_terminal->null\n", .{view.node_id});
    }

    // Clear urgency on focus gain + emit focus_changed.
    if (server.nodes.findByToplevel(view.toplevel)) |slot| {
        _ = server.nodes.clearUrgent(slot);
        server.emitMcpEventKind("focus_changed", ",\"node_id\":{d}", .{server.nodes.node_id[slot]});
    }

    const root_surface = wlr.miozu_xdg_surface_surface(
        wlr.miozu_xdg_toplevel_base(view.toplevel) orelse return,
    ) orelse return;

    // Leaf-if-same-client else root.
    const target: *wlr.wlr_surface = blk: {
        if (server.last_pointer_surface) |leaf| {
            if (wlr.miozu_surfaces_same_client(leaf, root_surface) != 0) {
                break :blk leaf;
            }
        }
        break :blk root_surface;
    };

    const kb_opt = wlr.miozu_seat_get_keyboard(server.seat);
    const modifiers: ?*anyopaque = if (kb_opt) |kb| wlr.miozu_keyboard_modifiers_ptr(kb) else null;
    const keycodes: ?[*]const u32 = if (kb_opt) |kb| wlr.miozu_keyboard_keycodes(kb) else null;
    const num_keycodes: usize = if (kb_opt) |kb| wlr.miozu_keyboard_num_keycodes(kb) else 0;
    wlr.wlr_seat_keyboard_notify_enter(server.seat, target, keycodes, num_keycodes, modifiers);
    std.debug.print(
        "teruwm: keyboard_notify_enter target={x} (root={x} leaf={?x})\n",
        .{ @intFromPtr(target), @intFromPtr(root_surface), if (server.last_pointer_surface) |l| @intFromPtr(l) else null },
    );

    if (server.bar) |b| b.render(server);
}

/// Null every Server pointer that references `node_id`. Call BEFORE
/// freeing the pane / view — a reentrant render or any code that
/// dereferences focused_terminal / focused_view touches freed memory
/// otherwise. `last_pointer_surface` is handled by View unmap /
/// destroy handlers since it's keyed on wlr_surface, not node_id.
pub fn clearFocusRefs(server: *Server, node_id: u64) void {
    if (server.focused_terminal) |tp| {
        if (tp.node_id == node_id) server.focused_terminal = null;
    }
    if (server.focused_view) |view| {
        if (view.node_id == node_id) server.focused_view = null;
    }
    if (server.grab_node_id) |id| if (id == node_id) {
        server.grab_node_id = null;
        server.cursor_mode = .normal;
    };
}

/// Reconcile focused_terminal/focused_view with the layout engine's
/// active node. Called after workspace switches, close, move, restore.
/// Cycle focus across every node on the current workspace — both
/// tiled and floating. Workspace.focusNext/Prev alone iterates only
/// Workspace.node_ids (tiled), so floating windows were invisible to
/// Win+J/K. This walker builds a ring out of the tiled list followed by
/// every floating node whose workspace matches, finds the currently
/// focused id in that ring, and advances to the neighbour. When the
/// target is tiled, we sync Workspace.active_index so subsequent layout
/// operations (swap, promote, resize) operate on the right slot.
pub fn cycleFocusAll(server: *Server, forward: bool) void {
    const ws_index = server.layout_engine.active_workspace;
    const ws = &server.layout_engine.workspaces[ws_index];

    // Ring: tiled first (preserves layout order), then floating.
    var ring: [NodeRegistry.max_nodes]u64 = undefined;
    var count: usize = 0;
    for (ws.node_ids.items) |nid| {
        if (count >= ring.len) break;
        ring[count] = nid;
        count += 1;
    }
    // Append floating nodes on this workspace. Node storage is SoA so
    // a single pass over max_nodes is cheap.
    for (0..NodeRegistry.max_nodes) |i| {
        if (count >= ring.len) break;
        if (server.nodes.kind[i] == .empty) continue;
        if (server.nodes.workspace[i] != ws_index) continue;
        if (!server.nodes.floating[i]) continue;
        ring[count] = server.nodes.node_id[i];
        count += 1;
    }
    if (count == 0) return;

    // Current focus id — prefer xdg view (may be floating), then
    // terminal. Falls back to the tiled active_index so the first
    // press still has a sensible anchor even if nothing was focused.
    const current_id: u64 = blk: {
        if (server.focused_view) |v| break :blk v.node_id;
        if (server.focused_terminal) |tp| break :blk tp.node_id;
        if (ws.getActiveNodeId()) |nid| break :blk nid;
        break :blk 0;
    };

    var idx: usize = 0;
    for (ring[0..count], 0..) |nid, i| {
        if (nid == current_id) {
            idx = i;
            break;
        }
    }
    const next_idx = if (forward)
        (idx + 1) % count
    else if (idx == 0) count - 1 else idx - 1;
    const target_nid = ring[next_idx];

    // Sync workspace.active_index when target is tiled so later
    // layout keybinds (swap_next/prev, promote) see the same anchor.
    for (ws.node_ids.items, 0..) |nid, i| {
        if (nid == target_nid) {
            ws.active_index = @intCast(i);
            ws.active_node = null;
            break;
        }
    }

    // Dispatch by node kind. updateFocusedTerminal routes through the
    // right focusView / focused_terminal code paths, and it already
    // knows how to consult active_index for tiled targets.
    if (server.nodes.findById(target_nid)) |slot| {
        switch (server.nodes.kind[slot]) {
            .terminal => {
                server.focused_view = null;
                updateFocusedTerminal(server);
            },
            .wayland_surface => {
                if (server.nodes.xdg_view[slot]) |opaque_view| {
                    const view: *XdgView = @ptrCast(@alignCast(opaque_view));
                    focusView(server, view);
                } else if (server.nodes.xwayland_surface[slot]) |xw| {
                    focusXwaylandSurface(server, xw);
                }
            },
            .empty => {},
        }
    }
}

/// Focus an XWayland surface: activate it, and route the seat keyboard
/// focus to its wlr_surface so typed keys actually reach the X11 client.
/// Without this, Emacs / Steam / GIMP under XWayland could be clicked
/// but never received key events — Spacemacs "SPC SPC" just sat there
/// because the seat had no keyboard-focused surface.
pub fn focusXwaylandSurface(server: *Server, xw: *wlr.wlr_xwayland_surface) void {
    const target = wlr.miozu_xwayland_surface_surface(xw) orelse return;

    // Deactivate prior XDG toplevel, if any — same XOR invariant the
    // XdgView path preserves.
    if (server.focused_view) |prev| {
        _ = wlr.wlr_xdg_toplevel_set_activated(prev.toplevel, false);
    }
    wlr.wlr_xwayland_surface_activate(xw, true);
    server.focused_view = null;
    server.focused_terminal = null;

    const kb_opt = wlr.miozu_seat_get_keyboard(server.seat);
    const modifiers: ?*anyopaque = if (kb_opt) |kb| wlr.miozu_keyboard_modifiers_ptr(kb) else null;
    const keycodes: ?[*]const u32 = if (kb_opt) |kb| wlr.miozu_keyboard_keycodes(kb) else null;
    const num_keycodes: usize = if (kb_opt) |kb| wlr.miozu_keyboard_num_keycodes(kb) else 0;
    wlr.wlr_seat_keyboard_notify_enter(server.seat, target, keycodes, num_keycodes, modifiers);

    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| tp.repaintBorderOnly();
    }
    if (server.bar) |b| b.render(server);
}

pub fn updateFocusedTerminal(server: *Server) void {
    const ws = server.layout_engine.getActiveWorkspace();
    const active_id = ws.active_node orelse ws.getActiveNodeId() orelse return;

    var found = false;
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.node_id == active_id) {
                if (server.focused_view) |prev_view| {
                    _ = wlr.wlr_xdg_toplevel_set_activated(prev_view.toplevel, false);
                }
                server.focused_terminal = tp;
                server.focused_view = null;
                found = true;
                break;
            }
        }
    }
    if (!found) {
        // Active node is an XDG view — route through focusView so the
        // Wayland client gets keyboard focus + activated state, and
        // focused_view is kept consistent for Win+X / Win+S.
        server.focused_terminal = null;
        if (server.nodes.findById(active_id)) |slot| {
            if (server.nodes.xdg_view[slot]) |opaque_view| {
                const view: *XdgView = @ptrCast(@alignCast(opaque_view));
                focusView(server, view);
                // Border-only repaint — cells unchanged, only the
                // focus-state colour flipped.
                for (server.terminal_panes) |maybe_tp| {
                    if (maybe_tp) |tp| tp.repaintBorderOnly();
                }
                return;
            }
        }
    }

    // Clear urgency for the newly-focused node, if any.
    if (server.nodes.findById(active_id)) |slot| {
        _ = server.nodes.clearUrgent(slot);
    }
    server.emitMcpEventKind("focus_changed", ",\"node_id\":{d}", .{active_id});

    applyFocusOpacity(server);

    // Border repaint — cells haven't changed, only focus-state colour.
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| tp.repaintBorderOnly();
    }
    if (server.bar) |b| b.render(server);
}

/// Switch the focused output to workspace `target`. Handles the
/// multi-output pull-swap: if another output is showing `target`,
/// it takes the focused output's previous workspace. Fires
/// workspace_switched on the MCP event channel.
pub fn focusWorkspace(server: *Server, target: u8) void {
    if (target >= 10) return;
    const focused = server.focused_output orelse {
        // No outputs yet — fall back to pre-multi-output path.
        const old = server.layout_engine.active_workspace;
        if (target == old) return;
        server.prev_workspace = old;
        server.layout_engine.switchWorkspace(target);
        server.setWorkspaceVisibility(old, false);
        server.setWorkspaceVisibility(target, true);
        server.arrangeworkspace(target);
        updateFocusedTerminal(server);
        server.maybeFireWorkspaceStartup(target);
        server.emitMcpEventKind("workspace_switched", ",\"from\":{d},\"to\":{d}", .{ old, target });
        if (server.bar) |b| b.render(server);
        return;
    };

    const prev = focused.workspace;
    if (target == prev) return;

    // Pull-swap: another output showing `target` takes our prev.
    if (server.outputShowing(target)) |other| {
        if (other != focused) {
            other.prev_workspace = other.workspace;
            other.workspace = prev;
            server.arrangeworkspace(prev);
        }
    }

    focused.prev_workspace = prev;
    focused.workspace = target;
    // Keep legacy active_workspace in sync for unmigrated code
    // (screenshot, bar, etc.).
    server.layout_engine.active_workspace = target;

    server.arrangeworkspace(target);
    server.recomputeVisibility();
    updateFocusedTerminal(server);
    server.maybeFireWorkspaceStartup(target);
    server.prev_workspace = prev;
    server.emitMcpEventKind("workspace_switched", ",\"from\":{d},\"to\":{d}", .{ prev, target });
    if (server.bar) |b| b.render(server);
}

/// Cycle focus to the next connected output (keybind action).
pub fn focusNextOutput(server: *Server) void {
    if (server.outputs.items.len < 2) return;
    const cur = server.focused_output orelse return;
    var next_idx: usize = 0;
    for (server.outputs.items, 0..) |o, i| {
        if (o == cur) {
            next_idx = (i + 1) % server.outputs.items.len;
            break;
        }
    }
    const next = server.outputs.items[next_idx];
    const from_ws = cur.workspace;
    const to_ws = next.workspace;
    server.focused_output = next;
    // Active workspace follows focus — legacy helpers read this.
    server.layout_engine.active_workspace = to_ws;
    updateFocusedTerminal(server);
    server.emitMcpEventKind("output_focused", ",\"from_ws\":{d},\"to_ws\":{d}", .{ from_ws, to_ws });
    if (server.bar) |b| b.render(server);
}

/// Move the focused node to the next output's current workspace.
pub fn moveFocusedToNextOutput(server: *Server) void {
    if (server.outputs.items.len < 2) return;
    const cur = server.focused_output orelse return;
    var next_idx: usize = 0;
    for (server.outputs.items, 0..) |o, i| {
        if (o == cur) {
            next_idx = (i + 1) % server.outputs.items.len;
            break;
        }
    }
    const target_ws = server.outputs.items[next_idx].workspace;
    const ws = server.layout_engine.getActiveWorkspace();
    if (ws.getActiveNodeId()) |nid| server.moveNodeToWorkspace(nid, target_ws);
}

/// Apply wm_config.unfocused_opacity to every terminal pane's
/// scene_buffer. 1.0 for the focused pane, unfocused_opacity for the
/// rest. wlroots blends on composite — zero CPU renderer cost.
/// When opacity ≥ 0.999 this is treated as disabled and we force
/// every buffer back to 1.0 in case a prior config change left one
/// faded.
pub fn applyFocusOpacity(server: *Server) void {
    const op = server.wm_config.unfocused_opacity;
    if (op >= 0.999) {
        for (server.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| wlr.wlr_scene_buffer_set_opacity(tp.scene_buffer, 1.0);
        }
        return;
    }
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            const o: f32 = if (tp == server.focused_terminal) 1.0 else op;
            wlr.wlr_scene_buffer_set_opacity(tp.scene_buffer, o);
        }
    }
}
