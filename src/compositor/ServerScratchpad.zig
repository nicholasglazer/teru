//! Named + numbered scratchpads.
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

const std = @import("std");
const teru = @import("teru");
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");
const NodeRegistry = @import("Node.zig");
const Pane = teru.Pane;

const max_auto_name_len = 32;

pub const ScratchRect = struct { x: i32, y: i32, w: u32, h: u32 };

/// Scratchpad toggle semantics:
///   (a) no such scratchpad     → spawn a floating terminal, tag it, show it
///   (b) hidden (HIDDEN_WS)     → promote to active workspace
///   (c) on active workspace    → demote to HIDDEN_WS
///   (d) on another workspace   → migrate to active workspace (follow-me)
///
/// Per-name spawn commands (`[scratchpad.NAME] cmd = htop`) are read
/// via `server.scratchpadRuleFor(name)` in spawn() — no need for an
/// explicit parameter here.
pub fn toggleByName(server: *Server, name: []const u8) void {
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
            server.nodes.moveSlotToWorkspace(slot, active_ws);
            show(server, slot, active_ws);
        }
        // Hide/show mutate the scene graph (reparent + enable flag +
        // position), none of which schedule a frame on their own. Without
        // this the compositor keeps displaying the last frame —
        // symptom: Mod+T "opens" a scratchpad and a second press is
        // silently swallowed. Reparenting into a disabled scene tree
        // (see hide()) is what gets wlroots to actually atomic-flip.
        server.scheduleRender();
        return;
    }

    _ = spawn(server, name, active_ws);
    // spawn() calls tp.render() which damages the buffer, but we still
    // need to kick the output so the new buffer paints this vsync.
    server.scheduleRender();
}

/// Numbered compatibility shim — index N maps to named scratchpad
/// `pad<N+1>`. Pre-v0.4.18 had a 3×3 grid layout that's no longer
/// preserved; users who want fixed placement should use named
/// scratchpads directly.
pub fn toggleNumbered(server: *Server, index: u8) void {
    if (index >= 9) return;
    var name_buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "pad{d}", .{index + 1}) catch return;
    toggleByName(server, name);
}

/// Default geometry for a scratchpad rect — percentage of the active
/// output's dimensions, centered. Fallback when no per-name rule
/// exists. Prefer `rectForName(server, name)` which honours
/// `[scratchpad.NAME]` config + default-seeded xmonad rects.
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

/// Per-name scratchpad geometry. Looks up `[scratchpad.NAME]` rule
/// (either from config or pre-seeded xmonad defaults in
/// Server.applyDefaultScratchpadRules), multiplies its x/y/w/h
/// fractions by the active output's pixel dimensions, and returns
/// the absolute rect. Falls back to the centered defaultRect when
/// no rule matches — users can toggle a fresh name with
/// `teruwm_scratchpad name=whatever` and get a sensible default.
pub fn rectForName(server: *const Server, name: []const u8) ScratchRect {
    const rule = server.scratchpadRuleFor(name) orelse return defaultRect(server);
    if (!rule.has_rect) return defaultRect(server);
    const dims = server.activeOutputDims();
    const out_w_f: f32 = @floatFromInt(dims.w);
    const out_h_f: f32 = @floatFromInt(dims.h);
    const x_px: i32 = @intFromFloat(rule.x * out_w_f);
    const y_px: i32 = @intFromFloat(rule.y * out_h_f);
    const w_px: u32 = @intFromFloat(rule.w * out_w_f);
    const h_px: u32 = @intFromFloat(rule.h * out_h_f);
    return .{ .x = x_px, .y = y_px, .w = w_px, .h = h_px };
}

// ── Private ──────────────────────────────────────────────────

/// Populate `argv_storage` + `argv_ptrs` from a `[scratchpad.NAME]
/// cmd = …` rule and return a SpawnConfig that points at them. Empty
/// / missing cmd returns `.{}` (default shell). Caller owns the two
/// backing buffers — they must outlive the Pane.init fork. Simple
/// whitespace tokenisation; no quoting or shell expansion — if you
/// want those, wrap the cmd in `sh -c "…"`.
fn buildSpawnConfig(
    server: *const Server,
    name: []const u8,
    argv_storage: *[16][256:0]u8,
    argv_ptrs: *[17]?[*:0]const u8,
) Pane.SpawnConfig {
    const rule = server.scratchpadRuleFor(name) orelse return .{};
    if (!rule.has_cmd or rule.cmd_len == 0) return .{};

    var it = std.mem.tokenizeAny(u8, rule.getCmd(), " \t");
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= argv_storage.len) break;
        const len = @min(tok.len, argv_storage[n].len);
        @memcpy(argv_storage[n][0..len], tok[0..len]);
        argv_storage[n][len] = 0;
        argv_ptrs[n] = argv_storage[n][0..len :0].ptr;
        n += 1;
    }
    if (n == 0) return .{};
    argv_ptrs[n] = null;
    return .{ .exec_argv = @ptrCast(argv_ptrs) };
}

// ── Hide / show / spawn ──────────────────────────────────────

/// Promote a parked scratchpad slot onto workspace `ws` and focus it.
/// Reparents the scene buffer back into the scene root if it was
/// parked — see hide() for why we can't just rely on set_enabled.
fn show(server: *Server, slot: u16, ws: u8) void {
    server.nodes.moveSlotToWorkspace(slot, ws);
    // Look up per-name rect: fraction-of-output-size, evaluated at
    // every show() so multi-monitor + resolution change Just Work.
    const name = server.nodes.getScratchpad(slot);
    const rect = rectForName(server, name);
    server.nodes.applyRect(slot, rect.x, rect.y, rect.w, rect.h);

    if (server.nodes.kind[slot] == .terminal) {
        const nid = server.nodes.node_id[slot];
        if (server.terminalPaneById(nid)) |tp| {
            if (server.sceneRoot()) |root| {
                tp.reparent(root);
            }
            tp.setVisible(true);
            tp.resize(rect.w, rect.h);
            tp.setPosition(rect.x, rect.y);
            server.focused_terminal = tp;
            server.focused_view = null;
            tp.render();
        }
    }
}

/// Demote a visible scratchpad to HIDDEN_WS by reparenting the scene
/// buffer into Server.hidden_tree (disabled). `wlr_scene_node_reparent`
/// damages both the old (visible) and new (hidden, disabled) positions,
/// guaranteeing the next DRM commit actually flips — previously we
/// called only `wlr_scene_node_set_enabled(false)`, which updates the
/// flag but can lose the enable-transition damage in wlr_scene's output
/// propagation, so the eDP-1 panel kept showing the last frame until
/// something else forced a repaint.
fn hide(server: *Server, slot: u16) void {
    server.nodes.moveSlotToWorkspace(slot, NodeRegistry.HIDDEN_WS);
    if (server.nodes.kind[slot] == .terminal) {
        const nid = server.nodes.node_id[slot];
        if (server.terminalPaneById(nid)) |tp| {
            if (server.getOrCreateHiddenTree()) |parked| {
                tp.reparent(parked);
            }
            tp.setVisible(false);
            if (server.focused_terminal == tp) server.focused_terminal = null;
        }
    }
}

/// Create a fresh scratchpad terminal tagged `name`, floating on `ws`,
/// focused. Returns the registry slot, or null on alloc failure (pane
/// is torn down cleanly on that path).
fn spawn(server: *Server, name: []const u8, ws: u8) ?u16 {
    const rect = rectForName(server, name);
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const cols: u16 = @intCast(@max(1, rect.w / cell_w));
    const rows: u16 = @intCast(@max(1, rect.h / cell_h));

    // Build a SpawnConfig from `[scratchpad.NAME] cmd = …` if present.
    // No cmd → `{}` = default shell. Buffers are fork-safe: both the
    // argv array and the NUL-terminated token strings are copies of
    // the config rule data and live on the stack here long enough for
    // `Pane.init`'s fork/execvp to use them; the child inherits the
    // full address space on fork, so execvp sees valid pointers.
    var argv_storage: [16][256:0]u8 = undefined;
    var argv_ptrs: [17]?[*:0]const u8 = [_]?[*:0]const u8{null} ** 17;
    const cfg = buildSpawnConfig(server, name, &argv_storage, &argv_ptrs);

    const tp = TerminalPane.createFloating(server, rows, cols, cfg) orelse return null;

    const slot = server.nodes.addTerminal(server.zig_allocator, tp.node_id, ws) orelse {
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
