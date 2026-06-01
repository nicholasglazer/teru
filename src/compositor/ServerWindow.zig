//! Window & workspace lifecycle for teruwm — node hit-testing, close
//! paths (terminal panes + XDG views), float/fullscreen toggles,
//! workspace placement and switching, scene-graph visibility
//! recompute, and multi-output focus cycling. Server.zig keeps thin
//! `pub const` re-exports; the bodies live here as `fn(server, …)`.

const std = @import("std");
const wlr = @import("wlr.zig");
const Output = @import("Output.zig");
const XdgView = @import("XdgView.zig");
const TerminalPane = @import("TerminalPane.zig");
const Session = @import("Session.zig");
const XwaylandView = @import("XwaylandView.zig");
const Launcher = @import("Launcher.zig");
const Bar = @import("Bar.zig");
const WmConfig = @import("WmConfig.zig");
const WmMcpServer = @import("WmMcpServer.zig");
const NodeRegistry = @import("Node.zig");
const Listeners = @import("ServerListeners.zig");
const Input = @import("ServerInput.zig");
const Cursor = @import("ServerCursor.zig");
const Focus = @import("ServerFocus.zig");
const Layout = @import("ServerLayout.zig");
const Scratchpad = @import("ServerScratchpad.zig");
const Restart = @import("ServerRestart.zig");
const Screenshot = @import("ServerScreenshot.zig");
const Process = @import("ServerProcess.zig");
const Repeat = @import("ServerRepeat.zig");
const Config = @import("ServerConfig.zig");
const teru = @import("teru");
const LayoutEngine = teru.LayoutEngine;
const Keybinds = teru.Keybinds;
const Mods = Keybinds.Mods;
const KB = Keybinds.Keybinds;
const KBAction = Keybinds.Action;
const KBMods = Keybinds.Mods;
const Server = @import("Server.zig");

// ── Workspace visibility ──────────────────────────────────────

/// Show or hide all nodes in a workspace.
pub fn setWorkspaceVisibility(self: *Server, ws: u8, visible: bool) void {
    const ws_nodes = self.layout_engine.workspaces[ws].node_ids.items;
    for (ws_nodes) |nid| {
        // Terminal panes
        if (terminalPaneById(self, nid)) |tp| tp.setVisible(visible);
        // External views: handled by the scene tree (XdgView nodes)
        if (self.nodes.findById(nid)) |slot| {
            if (self.nodes.kind[slot] == .wayland_surface) {
                if (self.nodes.scene_tree[slot]) |tree| {
                    if (wlr.miozu_scene_tree_node(tree)) |node| {
                        wlr.wlr_scene_node_set_enabled(node, visible);
                    }
                }
            }
        }
    }
}

// ── Float toggle ────────────────────────────────────────────

/// Snap the focused node back into the tiling layout if it was floating.
/// Tile → floating is NOT the keybind's job; floats are created by
/// Mod+drag with the mouse (a grab in ServerCursor). That rule matches
/// xmonad / bspwm: keyboard-only users never accidentally escape the
/// layout, mouse users get a dedicated physical gesture for floats.
/// No-op if the focused node is already tiled.
pub fn toggleFloat(self: *Server) void {
    // Determine the focused node ID
    const nid: u64 = if (self.focused_terminal) |tp|
        tp.node_id
    else if (self.focused_view) |view|
        view.node_id
    else
        return;

    const slot = self.nodes.findById(nid) orelse return;
    const ws = self.layout_engine.active_workspace;

    if (!self.nodes.floating[slot]) return; // already tiled — nothing to do

    self.nodes.floating[slot] = false;
    self.layout_engine.workspaces[ws].addNode(self.zig_allocator, nid) catch {};
    self.arrangeworkspace(ws);
    std.log.scoped(.compositor).debug("unfloat node={d}", .{nid});

    if (self.bar) |b| _ = b.render(self);
}

// ── Fullscreen ───────────────────────────────────────────────

/// Toggle the focused node (terminal OR Wayland client) to fill the
/// entire output. Before v0.5.1 this bailed early for xdg views because
/// it only read `focused_terminal` — so Mod+F did nothing on Chrome /
/// Firefox / any native-Wayland client. Now resolves the target via
/// focused_terminal OR focused_view and expands either one.
pub fn toggleFullscreen(self: *Server) void {
    if (self.fullscreen_node != null) {
        // ── Exit fullscreen ──
        self.fullscreen_node = null;

        // Restore bar visibility
        if (self.bar) |b| {
            b.top.enabled = self.fullscreen_prev_bar_top;
            b.bottom.enabled = self.fullscreen_prev_bar_bottom;
            if (b.top.enabled) {
                if (wlr.miozu_scene_buffer_node(b.top.scene_buffer)) |node| {
                    wlr.wlr_scene_node_set_enabled(node, true);
                }
            }
            if (b.bottom.enabled) {
                if (wlr.miozu_scene_buffer_node(b.bottom.scene_buffer)) |node| {
                    wlr.wlr_scene_node_set_enabled(node, true);
                }
            }
        }

        // Re-show every node via the derived-visibility pass. Unlike the
        // tiled-only setWorkspaceVisibility, this covers floating windows and
        // shown scratchpads (which enter-fullscreen hid via recomputeVisibility)
        // across all outputs, and observes fullscreen_node == null. Symmetric
        // with the enter path.
        recomputeVisibility(self);

        // Re-tile (respects bar height again)
        const ws = self.layout_engine.active_workspace;
        self.arrangeworkspace(ws);
        if (self.bar) |b| _ = b.render(self);

        std.log.scoped(.compositor).info("fullscreen off", .{});
        return;
    }

    // ── Enter fullscreen ──
    // Target = focused terminal OR focused xdg view. Either way we
    // expand its node to the full output.
    const target_id: u64 = if (self.focused_terminal) |tp|
        tp.node_id
    else if (self.focused_view) |v|
        v.node_id
    else
        return;

    self.fullscreen_node = target_id;

    // Save and hide bars
    if (self.bar) |b| {
        self.fullscreen_prev_bar_top = b.top.enabled;
        self.fullscreen_prev_bar_bottom = b.bottom.enabled;
        if (wlr.miozu_scene_buffer_node(b.top.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, false);
        }
        if (wlr.miozu_scene_buffer_node(b.bottom.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, false);
        }
    }

    // Hide everything except the fullscreened node. recomputeVisibility
    // now observes fullscreen_node as an override, so one O(N) pass
    // covers terminals + xdg views on every output — no double loop.
    recomputeVisibility(self);

    // Expand focused pane to fill entire output (no bar, no gaps).
    // For terminals we also resize the SW renderer framebuffer so the
    // cell grid expands to match; for xdg clients, applyRect sends the
    // xdg_toplevel_set_size configure.
    const dims_fs = activeOutputDims(self);
    const out_w: u32 = dims_fs.w;
    const out_h: u32 = dims_fs.h;
    if (self.focused_terminal) |tp| {
        tp.resize(out_w, out_h);
        tp.setPosition(0, 0);
    } else if (self.nodes.findById(target_id)) |slot| {
        self.nodes.applyRect(slot, 0, 0, out_w, out_h);
    }

    std.log.scoped(.compositor).info("fullscreen on node={d}", .{target_id});
}

// ── Terminal lifecycle ─────────────────────────────────────────

/// Handle terminal pane exit (shell process died).
/// Close a window (terminal pane or XDG view) by node_id.
/// Returns true if a window was closed.
/// Hit-test: return the node_id of the pane whose rect contains (x, y),
/// or null. Floating panes win over tiled because they render on top in
/// the scene graph. Linear scan — fine given the node count budget.
pub fn nodeAtPoint(self: *const Server, x: f64, y: f64) ?u64 {
    var best_floating: ?u64 = null;
    var best_tiled: ?u64 = null;
    const ix: i32 = @intFromFloat(x);
    const iy: i32 = @intFromFloat(y);
    const cur_ws = self.layout_engine.active_workspace;

    for (0..NodeRegistry.max_nodes) |slot| {
        if (self.nodes.kind[slot] == .empty) continue;
        if (self.nodes.workspace[slot] != cur_ws) continue;
        const px = self.nodes.pos_x[slot];
        const py = self.nodes.pos_y[slot];
        const pw: i32 = @intCast(self.nodes.width[slot]);
        const ph: i32 = @intCast(self.nodes.height[slot]);
        if (ix < px or ix >= px + pw) continue;
        if (iy < py or iy >= py + ph) continue;
        if (self.nodes.floating[slot]) {
            best_floating = self.nodes.node_id[slot];
        } else {
            best_tiled = self.nodes.node_id[slot];
        }
    }
    return best_floating orelse best_tiled;
}

/// Dimensions of the currently-focused output (or first connected if
/// no focus yet). Replaces miozu_output_layout_first_* which always
/// returned the first output in layout order — wrong under multi-head
/// for callers that mean "the output the user is looking at".
///
/// Returns 1920×1080 fallback when no outputs are connected (same as
/// the previous glue helper). Several callers do (w - x)/2 arithmetic
/// that would underflow u32 at w=0; 1920×1080 is the "drawing on a
/// virtual display" best guess.
pub fn activeOutputDims(self: *const Server) struct { w: u32, h: u32 } {
    const out: *wlr.wlr_output = if (self.focused_output) |o|
        o.wlr_output
    else if (self.outputs.items.len > 0)
        self.outputs.items[0].wlr_output
    else
        return .{ .w = 1920, .h = 1080 };
    return .{
        .w = @intCast(@max(1, wlr.miozu_output_width(out))),
        .h = @intCast(@max(1, wlr.miozu_output_height(out))),
    };
}

/// Find the TerminalPane with the given node_id. Still O(n) over the
/// fixed-size array, but keeps the lookup in one place — callers that
/// only need a node_id → *TerminalPane mapping shouldn't hand-roll the
/// nested slot/tp scan.
pub fn terminalPaneById(self: *const Server, node_id: u64) ?*TerminalPane {
    return self.pane_index.get(node_id);
}

/// Null every Server pointer that references the node being torn down.
/// Call BEFORE freeing the pane / view — a reentrant render or any code
/// that dereferences focused_terminal / focused_view touches freed memory
/// otherwise. `last_pointer_surface` is handled by the View's unmap/
/// destroy handlers since it's keyed on wlr_surface, not node_id.
pub fn clearFocusRefs(self: *Server, node_id: u64) void {
    Focus.clearFocusRefs(self, node_id);
}

pub fn closeNode(self: *Server, node_id: u64) bool {
    // Try terminal pane first
    for (&self.terminal_panes, 0..) |*slot, i| {
        _ = i;
        if (slot.*) |tp| {
            if (tp.node_id == node_id) {
                const ws = if (self.nodes.findById(node_id)) |s| self.nodes.workspace[s] else self.layout_engine.active_workspace;
                // A parked scratchpad has ws == HIDDEN_WS (255); indexing the
                // [10]Workspace array with it is OOB. Remove from every
                // workspace like handleTerminalExit does — node ids are unique
                // so the extra removeNode calls are harmless no-ops.
                for (&self.layout_engine.workspaces) |*w| w.removeNode(node_id);
                if (self.nodes.findById(node_id)) |_| _ = self.nodes.remove(node_id);

                clearFocusRefs(self, node_id);

                tp.deinit(self.zig_allocator);
                self.zig_allocator.destroy(tp);
                slot.* = null;
                self.terminal_count -|= 1;
                if (ws < self.layout_engine.workspaces.len) self.arrangeworkspace(ws);
                updateFocusedTerminal(self);
                if (self.bar) |b| _ = b.render(self);
                return true;
            }
        }
    }

    // XDG view: find the view with matching node_id and send close request.
    // Defensive: the view may already be gone (the client crashed /
    // unmapped between the MCP caller's list_windows and this call);
    // dereferencing view.toplevel then feeds a dead wl_resource to
    // wl_resource_post_event, which aborts. Cross-check NodeRegistry
    // before touching the toplevel.
    if (self.focused_view) |view| {
        if (view.node_id == node_id and self.nodes.findById(node_id) != null) {
            clearFocusRefs(self, node_id);
            wlr.wlr_xdg_toplevel_send_close(view.toplevel);
            return true;
        }
    }
    // Search all XDG views for node_id match (walk the scene? no tracking, so
    // we need to iterate differently). For now, handle only focused_view —
    // MCP callers close by node_id through NodeRegistry instead.
    return false;
}

/// Close whatever window is currently focused (terminal pane or XDG view).
/// Bound to Win+X. No-op if nothing focused.
pub fn closeFocused(self: *Server) void {
    if (self.focused_view) |view| {
        clearFocusRefs(self, view.node_id);
        std.log.scoped(.compositor).info("closeFocused → xdg view node={d}", .{view.node_id});
        wlr.wlr_xdg_toplevel_send_close(view.toplevel);
        return;
    }
    if (self.focused_xwayland) |xw| {
        // X11 client: wlr_xwayland_surface_close sends WM_DELETE_WINDOW
        // which most XWayland apps (Emacs, GIMP, Steam) listen for.
        std.log.scoped(.compositor).info("closeFocused → xwayland surface", .{});
        wlr.wlr_xwayland_surface_close(xw);
        return;
    }
    if (self.focused_terminal) |tp| {
        std.log.scoped(.compositor).info("closeFocused → terminal node={d}", .{tp.node_id});
        _ = closeNode(self, tp.node_id);
        return;
    }
    // Neither focused_terminal nor focused_view — telemetry for the
    // "can't close last pane" symptom. Either focus is stale (action
    // dispatched before updateFocusedTerminal ran after the previous
    // close) or the workspace is legitimately empty. Print the state
    // so we can see which one it is in live logs.
    const ws = self.layout_engine.getActiveWorkspace();
    std.log.scoped(.compositor).warn(
        "closeFocused with no focus — ws={d} tiled_count={d} terminal_count={d}",
        .{ self.layout_engine.active_workspace, ws.node_ids.items.len, self.terminal_count },
    );
}

pub fn handleTerminalExit(self: *Server, tp: *TerminalPane) void {
    std.log.scoped(.compositor).info("terminal exited node={d}", .{tp.node_id});

    clearFocusRefs(self, tp.node_id);

    // Remove from node registry and tiling engine
    _ = self.nodes.remove(tp.node_id);
    for (&self.layout_engine.workspaces) |*ws| {
        ws.removeNode(tp.node_id);
    }

    // DynamicProjects: if this empties any workspace, reset its
    // startup-fired flag so the next visit re-runs its startup hook.
    for (0..10) |ws_i| self.resetWorkspaceStartupIfEmpty(@intCast(ws_i));

    // Remove from terminal_panes array. Scratchpads since v0.4.18 live
    // here too (they're regular panes with a scratchpad_name tag) —
    // single loop covers both cases.
    for (&self.terminal_panes) |*slot| {
        if (slot.* == tp) {
            slot.* = null;
            self.terminal_count -= 1;
            break;
        }
    }
    _ = self.pane_index.remove(tp.node_id);

    // Drop the dangling focus pointer before tp is freed below.
    // updateFocusedTerminal() is deferred until after the re-tile.
    if (self.focused_terminal == tp) self.focused_terminal = null;

    // Free the pane. tp.deinit removes the PTY event source, hides +
    // detaches the scene buffer, frees the grid/scrollback and closes
    // the PTY master fd; destroy() releases the struct. Mirrors
    // closeNode — must come after the unregistration above so nothing
    // dereferences a freed pane. (Previously this function only hid the
    // scene node and leaked the pane + its PTY fd on every shell exit —
    // unnoticed because its sole caller, ptyReadable's HANGUP branch,
    // was dead code.)
    tp.deinit(self.zig_allocator);
    self.zig_allocator.destroy(tp);

    // Re-tile, then move focus onto a surviving pane. removeNode above
    // cleared the workspace's active_node (it pointed at the exited
    // pane), and for split-tree layouts getActiveNodeId() then yields
    // null — so updateFocusedTerminal would give up and leave keyboard
    // focus null until the user manually refocuses. Re-seat active_node
    // on a survivor first so focus follows the exit.
    const aws_idx = self.layout_engine.active_workspace;
    self.arrangeworkspace(aws_idx);
    const aws = &self.layout_engine.workspaces[aws_idx];
    if (aws.active_node == null and aws.node_ids.items.len > 0) {
        const idx = @min(aws.active_index, aws.node_ids.items.len - 1);
        aws.active_node = aws.node_ids.items[idx];
    }
    updateFocusedTerminal(self);
    if (self.bar) |b| _ = b.render(self);
}

// ── Focus management ──────────────────────────────────────────

/// Update focused_terminal to match the LayoutEngine's active node.
/// Also updates visual focus indicators (border color).
///
/// Prefer `ws.active_node` over `getActiveNodeId()`: floating panes are
/// removed from `node_ids.items` (the tiled list) so `getActiveNodeId`
/// can't see them. `active_node` is the explicit authoritative focus
/// target set by `teruwm_focus_window` and friends — it works for both
/// tiled and floating panes.
pub fn updateFocusedTerminal(self: *Server) void {
    Focus.updateFocusedTerminal(self);
}

// ── Multi-output: the 3-rule architecture (v0.4.20) ──────────
//
// R1: Node.workspace is identity (already in NodeRegistry).
// R2: Output.workspace is a viewport (stored per-Output).
// R3: Visibility is derived via recomputeVisibility().
//
// All workspace-level mutations go through focusWorkspace (viewport)
// or moveNodeToWorkspace (identity). Call recomputeVisibility after
// each mutation — it's O(max_nodes), sub-microsecond, no allocation.

/// Which workspace the focused output currently shows. Shim for
/// legacy call sites that read `layout_engine.active_workspace`.
pub fn activeWorkspace(self: *const Server) u8 {
    if (self.focused_output) |out| return out.workspace;
    return self.layout_engine.active_workspace;
}

/// Return the output currently showing `ws`, if any. Null means the
/// workspace is orphaned (nodes on it stay hidden until some output
/// takes it). Multi-output invariant: at most one output per ws.
pub fn outputShowing(self: *const Server, ws: u8) ?*Output {
    for (self.outputs.items) |out| {
        if (out.workspace == ws) return out;
    }
    return null;
}

/// **The only mutation path for Output.workspace.** Handles xmonad
/// pull-swap: if `target` is already visible on another output, that
/// output takes the focused output's previous workspace. All four
/// cases (identity, collision, no-op, first-show) live in one path.
pub fn focusWorkspace(self: *Server, target: u8) void {
    Focus.focusWorkspace(self, target);
}

/// Move a node (pane or Wayland client) to a different workspace.
/// Orthogonal to Output.workspace: just flips Node.workspace, then
/// recomputes visibility and re-arranges affected outputs.
pub fn moveNodeToWorkspace(self: *Server, nid: u64, target: u8) void {
    if (target >= 10) return;
    const slot = self.nodes.findById(nid) orelse return;
    const from = self.nodes.workspace[slot];
    if (from == target) return;

    // If the node we're moving was the focused terminal and the target
    // workspace isn't visible anywhere, the pane becomes invisible —
    // we must drop focus so subsequent keystrokes don't silently feed
    // an off-screen PTY. updateFocusedTerminal (called below) picks a
    // new focus target on the now-visible workspace.
    const was_focused_nid = if (self.focused_terminal) |tp| tp.node_id else 0;
    const was_focused = (was_focused_nid == nid);

    // Update node identity. Workspace list bookkeeping: remove from old
    // node_ids (if it was tiled there), add to new.
    self.nodes.moveSlotToWorkspace(slot, target);
    // `from` is HIDDEN_WS (255) for a parked scratchpad — only `target` was
    // range-checked above. Guard the source index against the [10]Workspace
    // array. (moveSlotToWorkspace already handled the 255→target identity.)
    if (from < self.layout_engine.workspaces.len) self.layout_engine.workspaces[from].removeNode(nid);
    if (!self.nodes.floating[slot]) {
        self.layout_engine.workspaces[target].addNode(self.zig_allocator, nid) catch |e| {
            std.log.scoped(.compositor).err("moveNodeToWorkspace addNode failed: {s}", .{@errorName(e)});
        };
    }

    // Re-arrange every output showing either ws (cheap: N ≤ 4).
    for (self.outputs.items) |out| {
        if (out.workspace == from or out.workspace == target) {
            self.arrangeworkspace(out.workspace);
        }
    }
    recomputeVisibility(self);

    if (was_focused) {
        // Focused pane moved. If target workspace isn't shown anywhere,
        // the pane is now invisible; refresh focus to whatever's on the
        // current workspace instead (or null if empty).
        if (outputShowing(self, target) == null) {
            self.focused_terminal = null;
            updateFocusedTerminal(self);
        }
    }
    self.emitMcpEventKind("node_moved", ",\"node_id\":{d},\"from\":{d},\"to\":{d}", .{ nid, from, target });

    // Repaint the bar immediately. Otherwise the workspace-occupancy
    // pills only update when the next frame callback happens to detect
    // a signature change — felt like a noticeable lag after Mod+Shift+N.
    if (self.bar) |b| {
        b.dirty = true;
        _ = b.render(self);
    }
}

/// Rule 3: a node renders iff some output currently shows its
/// workspace. Called after any R1 or R2 mutation. Single-output
/// case: identical to the legacy setWorkspaceVisibility toggle.
pub fn recomputeVisibility(self: *Server) void {
    // Iterate active slots only — Node.by_id has exactly `nodes.count`
    // entries, so on realistic workloads (<20 panes) this is ~13x
    // fewer iterations than scanning all 256.
    var it = self.nodes.by_id.valueIterator();
    while (it.next()) |slot_ptr| {
        const slot = slot_ptr.*;
        const ws = self.nodes.workspace[slot];
        if (ws == NodeRegistry.HIDDEN_WS) {
            setSlotVisible(self, slot, false);
            continue;
        }
        // Fullscreen takes precedence: every node but the fullscreened
        // one is hidden, regardless of which output shows its workspace.
        if (self.fullscreen_node) |fs_nid| {
            setSlotVisible(self, slot, self.nodes.node_id[slot] == fs_nid);
            continue;
        }
        const visible = outputShowing(self, ws) != null;
        setSlotVisible(self, slot, visible);
    }
}

fn setSlotVisible(self: *Server, slot: u16, visible: bool) void {
    // Terminal panes: O(1) index lookup (see pane_index).
    if (self.nodes.kind[slot] == .terminal) {
        if (terminalPaneById(self, self.nodes.node_id[slot])) |tp| {
            tp.setVisible(visible);
        }
        return;
    }
    if (self.nodes.kind[slot] == .wayland_surface) {
        if (self.nodes.scene_tree[slot]) |tree| {
            if (wlr.miozu_scene_tree_node(tree)) |node| {
                wlr.wlr_scene_node_set_enabled(node, visible);
            }
        }
    }
}

/// Cycle focus to the next connected output (keybind action).
pub fn focusNextOutput(self: *Server) void {
    Focus.focusNextOutput(self);
}

/// Cycle focus across every node on the current workspace (including
/// floating). Win+J = forward, Win+K = backward.
pub fn cycleFocusAll(self: *Server, forward: bool) void {
    Focus.cycleFocusAll(self, forward);
}

pub fn focusXwaylandSurface(self: *Server, xw: *wlr.wlr_xwayland_surface) void {
    Focus.focusXwaylandSurface(self, xw);
}

