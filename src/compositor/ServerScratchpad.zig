//! Named + numbered scratchpads (xmonad NamedScratchpad model).
//!
//! A scratchpad is a regular terminal pane with a stable string
//! identity and a HIDDEN_WS "parked" sentinel. Toggling it promotes
//! the pane to the active workspace (or demotes back to HIDDEN_WS),
//! so the user can keep one floating terminal always-available
//! without cluttering any real workspace.
//!
//! Pre-v0.4.18 this used a side-channel `Server.scratchpads[]` array;
//! since v0.4.18 scratchpads live in the main NodeRegistry with
//! `scratchpad_name` set and an optional HIDDEN_WS workspace. That
//! means list_windows sees them, screenshot paths pick them up via
//! the floating walk, and hot-restart serializes them.
//!
//! Split out of Server.zig as part of the 2026-04-16 modularization pass.

const std = @import("std");
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");
const NodeRegistry = @import("Node.zig");

const max_auto_name_len = 32;

pub const ScratchRect = struct { x: i32, y: i32, w: u32, h: u32 };

/// xmonad namedScratchpadAction semantics:
///   (a) no such scratchpad     → spawn a floating terminal, tag it, show it
///   (b) hidden (HIDDEN_WS)     → promote to active workspace
///   (c) on active workspace    → demote to HIDDEN_WS
///   (d) on another workspace   → migrate to active workspace (follow-me)
pub fn toggleByName(server: *Server, name: []const u8, default_cmd: ?[]const u8) void {
    _ = default_cmd; // reserved for future per-scratchpad spawn cmds
    if (name.len == 0 or name.len >= NodeRegistry.max_scratchpad_name) return;
    const active_ws = server.layout_engine.active_workspace;

    if (server.nodes.findByScratchpad(name)) |slot| {
        const on_ws = server.nodes.workspace[slot];
        if (on_ws == NodeRegistry.HIDDEN_WS) {
            show(server, slot, active_ws);
        } else if (on_ws == active_ws) {
            hide(server, slot);
        } else {
            // Follow-me migration.
            server.nodes.workspace[slot] = active_ws;
            show(server, slot, active_ws);
        }
        return;
    }

    _ = spawn(server, name, active_ws);
}

/// Numbered compatibility shim — index N maps to named scratchpad
/// `pad<N+1>`. Pre-v0.4.18 had a 3×3 grid layout that's no longer
/// preserved; users who want fixed placement should use named
/// scratchpads directly.
pub fn toggleNumbered(server: *Server, index: u8) void {
    if (index >= 9) return;
    var name_buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "pad{d}", .{index + 1}) catch return;
    toggleByName(server, name, null);
}

/// Default geometry for a scratchpad rect — percentage of the active
/// output's dimensions, centered. Future: per-name overrides from a
/// `[scratchpads]` config section.
pub fn defaultRect(server: *const Server) ScratchRect {
    const dims = server.activeOutputDims();
    const out_w: u32 = dims.w;
    const out_h: u32 = dims.h;
    const w: u32 = out_w * server.wm_config.scratchpad_width_pct / 100;
    const h: u32 = out_h * server.wm_config.scratchpad_height_pct / 100;
    return .{
        .x = @intCast((out_w - w) / 2),
        .y = @intCast((out_h - h) / 2),
        .w = w,
        .h = h,
    };
}

// ── Private ──────────────────────────────────────────────────

/// Promote a parked scratchpad slot onto workspace `ws` and focus it.
fn show(server: *Server, slot: u16, ws: u8) void {
    server.nodes.workspace[slot] = ws;
    const rect = defaultRect(server);
    server.nodes.applyRect(slot, rect.x, rect.y, rect.w, rect.h);

    if (server.nodes.kind[slot] == .terminal) {
        const nid = server.nodes.node_id[slot];
        if (server.terminalPaneById(nid)) |tp| {
            tp.setVisible(true);
            tp.resize(rect.w, rect.h);
            tp.setPosition(rect.x, rect.y);
            server.focused_terminal = tp;
            server.focused_view = null;
            tp.render();
        }
    }
}

/// Demote a visible scratchpad to HIDDEN_WS.
fn hide(server: *Server, slot: u16) void {
    server.nodes.workspace[slot] = NodeRegistry.HIDDEN_WS;
    if (server.nodes.kind[slot] == .terminal) {
        const nid = server.nodes.node_id[slot];
        if (server.terminalPaneById(nid)) |tp| {
            tp.setVisible(false);
            if (server.focused_terminal == tp) server.focused_terminal = null;
        }
    }
}

/// Create a fresh scratchpad terminal tagged `name`, floating on `ws`,
/// focused. Returns the registry slot, or null on alloc failure (pane
/// is torn down cleanly on that path).
fn spawn(server: *Server, name: []const u8, ws: u8) ?u16 {
    const rect = defaultRect(server);
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const cols: u16 = @intCast(@max(1, rect.w / cell_w));
    const rows: u16 = @intCast(@max(1, rect.h / cell_h));

    const tp = TerminalPane.createFloating(server, rows, cols) orelse return null;

    const slot = server.nodes.addTerminal(tp.node_id, ws) orelse {
        tp.deinit(server.zig_allocator);
        server.zig_allocator.destroy(tp);
        return null;
    };
    server.nodes.floating[slot] = true;
    server.nodes.setScratchpad(slot, name);
    var auto_name_buf: [max_auto_name_len]u8 = undefined;
    const auto_name = std.fmt.bufPrint(&auto_name_buf, "scratch-{s}", .{name}) catch "scratch";
    server.nodes.setName(slot, auto_name);

    tp.setPosition(rect.x, rect.y);
    server.nodes.applyRect(slot, rect.x, rect.y, rect.w, rect.h);

    // Register for PTY read polling.
    for (&server.terminal_panes) |*p_slot| {
        if (p_slot.* == null) {
            p_slot.* = tp;
            server.terminal_count += 1;
            break;
        }
    }

    server.focused_terminal = tp;
    server.focused_view = null;
    std.debug.print("teruwm: scratchpad '{s}' spawned on ws={d}\n", .{ name, ws });
    return slot;
}
