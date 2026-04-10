//! Configurable keybinding system.
//!
//! Parses [keybinds.MODE] sections from teru.conf / keybinds.conf.
//! Supports modes (normal, prefix, scroll, search), shared bindings,
//! modifier flags (alt, ralt, ctrl, shift, super), and namespaced actions.
//!
//! Format:
//!   [keybinds.normal]
//!   alt+j = pane:focus_next
//!   ralt+h = resize:shrink_w
//!   alt+1 = workspace:1
//!   ctrl+space = mode:prefix
//!
//!   [keybinds.shared]
//!   ctrl+shift+c = copy:selection

const std = @import("std");

// ── Modifier flags ──────────────────────────────────────────

pub const Mods = packed struct(u8) {
    alt: bool = false,
    ralt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    super_: bool = false,
    _pad: u3 = 0,

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }

    pub const ALT = Mods{ .alt = true };
    pub const RALT = Mods{ .alt = true, .ralt = true };
    pub const CTRL = Mods{ .ctrl = true };
    pub const SHIFT = Mods{ .shift = true };
    pub const CTRL_SHIFT = Mods{ .ctrl = true, .shift = true };
    pub const NONE = Mods{};
};

// ── Modes ───────────────────────────────────────────────────

pub const Mode = enum(u8) {
    normal = 0,
    prefix = 1,
    scroll = 2,
    search = 3,
    locked = 4,
    shared = 252, // applies to all modes
    shared_except_normal = 253, // all except normal
    shared_except_locked = 254, // all except locked
    _,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "prefix")) return .prefix;
        if (std.mem.eql(u8, s, "scroll")) return .scroll;
        if (std.mem.eql(u8, s, "search")) return .search;
        if (std.mem.eql(u8, s, "locked")) return .locked;
        if (std.mem.eql(u8, s, "shared")) return .shared;
        // shared_except.normal, shared_except.locked, etc
        if (std.mem.startsWith(u8, s, "shared_except.")) {
            const rest = s["shared_except.".len..];
            if (std.mem.eql(u8, rest, "normal")) return .shared_except_normal;
            if (std.mem.eql(u8, rest, "locked")) return .shared_except_locked;
        }
        return null;
    }

    /// Check if a shared mode applies to the given active mode.
    pub fn appliesTo(binding_mode: Mode, active_mode: Mode) bool {
        return switch (binding_mode) {
            .shared => true,
            .shared_except_normal => active_mode != .normal,
            .shared_except_locked => active_mode != .locked,
            else => binding_mode == active_mode,
        };
    }
};

// ── Actions ─────────────────────────────────────────────────

pub const Action = enum(u8) {
    none = 0,

    // Pane
    pane_focus_next,
    pane_focus_prev,
    pane_focus_master,
    pane_set_master,
    pane_swap_next,
    pane_swap_prev,
    pane_close,
    pane_move_to_1,
    pane_move_to_2,
    pane_move_to_3,
    pane_move_to_4,
    pane_move_to_5,
    pane_move_to_6,
    pane_move_to_7,
    pane_move_to_8,
    pane_move_to_9,
    pane_move_to_0,

    // Split
    split_vertical,
    split_horizontal,

    // Workspace
    workspace_1,
    workspace_2,
    workspace_3,
    workspace_4,
    workspace_5,
    workspace_6,
    workspace_7,
    workspace_8,
    workspace_9,
    workspace_0,

    // Layout
    layout_cycle,

    // Zoom
    zoom_in,
    zoom_out,
    zoom_reset,
    zoom_toggle,

    // Resize
    resize_shrink_w,
    resize_grow_w,
    resize_shrink_h,
    resize_grow_h,

    // Mode transitions
    mode_normal,
    mode_prefix,
    mode_scroll,
    mode_search,
    mode_locked,

    // Session
    session_detach,

    // UI
    toggle_status_bar,

    // Clipboard
    copy_selection,
    paste_clipboard,

    // Scroll (for scroll mode)
    scroll_up_1,
    scroll_down_1,
    scroll_up_half,
    scroll_down_half,
    scroll_top,
    scroll_bottom,

    // Search (for search mode)
    search_next,
    search_prev,

    // Select (for scroll/copy mode)
    select_begin,

    // Send raw key through to PTY
    send_through,

    pub fn fromString(s: []const u8) ?Action {
        // Exact match table
        const map = .{
            .{ "pane:focus_next", Action.pane_focus_next },
            .{ "pane:focus_prev", Action.pane_focus_prev },
            .{ "pane:focus_master", Action.pane_focus_master },
            .{ "pane:set_master", Action.pane_set_master },
            .{ "pane:swap_next", Action.pane_swap_next },
            .{ "pane:swap_prev", Action.pane_swap_prev },
            .{ "pane:close", Action.pane_close },
            .{ "split:vertical", Action.split_vertical },
            .{ "split:horizontal", Action.split_horizontal },
            .{ "layout:cycle", Action.layout_cycle },
            .{ "zoom:in", Action.zoom_in },
            .{ "zoom:out", Action.zoom_out },
            .{ "zoom:reset", Action.zoom_reset },
            .{ "zoom:toggle", Action.zoom_toggle },
            .{ "resize:shrink_w", Action.resize_shrink_w },
            .{ "resize:grow_w", Action.resize_grow_w },
            .{ "resize:shrink_h", Action.resize_shrink_h },
            .{ "resize:grow_h", Action.resize_grow_h },
            .{ "resize:-2:0", Action.resize_shrink_w },
            .{ "resize:+2:0", Action.resize_grow_w },
            .{ "resize:0:-2", Action.resize_shrink_h },
            .{ "resize:0:+2", Action.resize_grow_h },
            .{ "mode:normal", Action.mode_normal },
            .{ "mode:prefix", Action.mode_prefix },
            .{ "mode:scroll", Action.mode_scroll },
            .{ "mode:search", Action.mode_search },
            .{ "mode:locked", Action.mode_locked },
            .{ "session:detach", Action.session_detach },
            .{ "ui:toggle_status_bar", Action.toggle_status_bar },
            .{ "copy:selection", Action.copy_selection },
            .{ "paste:clipboard", Action.paste_clipboard },
            .{ "scroll:up:1", Action.scroll_up_1 },
            .{ "scroll:down:1", Action.scroll_down_1 },
            .{ "scroll:up:half", Action.scroll_up_half },
            .{ "scroll:down:half", Action.scroll_down_half },
            .{ "scroll:top", Action.scroll_top },
            .{ "scroll:bottom", Action.scroll_bottom },
            .{ "search:next", Action.search_next },
            .{ "search:prev", Action.search_prev },
            .{ "select:begin", Action.select_begin },
            .{ "send:through", Action.send_through },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        // Parameterized: workspace:N, pane:move_to:N
        if (std.mem.startsWith(u8, s, "workspace:")) {
            const n = std.fmt.parseInt(u8, s["workspace:".len..], 10) catch return null;
            return switch (n) {
                1 => .workspace_1, 2 => .workspace_2, 3 => .workspace_3,
                4 => .workspace_4, 5 => .workspace_5, 6 => .workspace_6,
                7 => .workspace_7, 8 => .workspace_8, 9 => .workspace_9,
                0 => .workspace_0,
                else => null,
            };
        }
        if (std.mem.startsWith(u8, s, "pane:move_to:")) {
            const n = std.fmt.parseInt(u8, s["pane:move_to:".len..], 10) catch return null;
            return switch (n) {
                1 => .pane_move_to_1, 2 => .pane_move_to_2, 3 => .pane_move_to_3,
                4 => .pane_move_to_4, 5 => .pane_move_to_5, 6 => .pane_move_to_6,
                7 => .pane_move_to_7, 8 => .pane_move_to_8, 9 => .pane_move_to_9,
                0 => .pane_move_to_0,
                else => null,
            };
        }
        return null;
    }

    /// Get the workspace number (0-indexed) for workspace actions.
    pub fn workspaceIndex(self: Action) ?u8 {
        return switch (self) {
            .workspace_1 => 0, .workspace_2 => 1, .workspace_3 => 2,
            .workspace_4 => 3, .workspace_5 => 4, .workspace_6 => 5,
            .workspace_7 => 6, .workspace_8 => 7, .workspace_9 => 8,
            .workspace_0 => 9,
            else => null,
        };
    }

    /// Get workspace index for move-to actions.
    pub fn moveToIndex(self: Action) ?u8 {
        return switch (self) {
            .pane_move_to_1 => 0, .pane_move_to_2 => 1, .pane_move_to_3 => 2,
            .pane_move_to_4 => 3, .pane_move_to_5 => 4, .pane_move_to_6 => 5,
            .pane_move_to_7 => 6, .pane_move_to_8 => 7, .pane_move_to_9 => 8,
            .pane_move_to_0 => 9,
            else => null,
        };
    }
};

// ── Binding ─────────────────────────────────────────────────

pub const Binding = struct {
    mode: Mode,
    mods: Mods,
    key: u8, // ASCII char or named key code
    action: Action,
};

// ── Named key map ───────────────────────────────────────────

fn namedKey(name: []const u8) ?u8 {
    if (name.len == 1) return name[0];
    const map = .{
        .{ "space", @as(u8, ' ') },
        .{ "enter", @as(u8, '\r') },
        .{ "return", @as(u8, '\r') },
        .{ "esc", @as(u8, 0x1b) },
        .{ "escape", @as(u8, 0x1b) },
        .{ "tab", @as(u8, '\t') },
        .{ "backspace", @as(u8, 0x7f) },
        .{ "minus", @as(u8, '-') },
        .{ "equal", @as(u8, '=') },
        .{ "slash", @as(u8, '/') },
        .{ "backslash", @as(u8, '\\') },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

// ── Trigger parser ──────────────────────────────────────────

/// Parse a trigger string like "alt+j", "ctrl+shift+c", "ralt+h"
/// Returns (Mods, key) or null on parse error.
fn parseTrigger(trigger: []const u8) ?struct { mods: Mods, key: u8 } {
    var mods = Mods{};
    var remaining = trigger;

    // Strip inline comment
    if (std.mem.indexOf(u8, remaining, "#")) |idx| {
        remaining = std.mem.trim(u8, remaining[0..idx], " \t");
    }

    // Split by + and process modifiers, last token is the key
    var last_plus: usize = 0;
    var i: usize = 0;
    while (i < remaining.len) : (i += 1) {
        if (remaining[i] == '+') {
            const token = remaining[last_plus..i];
            if (std.mem.eql(u8, token, "alt")) {
                mods.alt = true;
            } else if (std.mem.eql(u8, token, "ralt")) {
                mods.alt = true;
                mods.ralt = true;
            } else if (std.mem.eql(u8, token, "ctrl")) {
                mods.ctrl = true;
            } else if (std.mem.eql(u8, token, "shift")) {
                mods.shift = true;
            } else if (std.mem.eql(u8, token, "super")) {
                mods.super_ = true;
            } else return null; // unknown modifier
            last_plus = i + 1;
        }
    }

    // Everything after the last + is the key name
    const key_name = remaining[last_plus..];
    if (key_name.len == 0) return null;
    const key = namedKey(key_name) orelse return null;

    return .{ .mods = mods, .key = key };
}

// ── Keybinds config ─────────────────────────────────────────

pub const MAX_BINDINGS = 256;

pub const Keybinds = struct {
    bindings: [MAX_BINDINGS]Binding = undefined,
    count: u16 = 0,

    /// Look up an action for the given mode, modifiers, and key.
    /// Checks mode-specific bindings first, then shared bindings.
    pub fn lookup(self: *const Keybinds, active_mode: Mode, mods: Mods, key: u8) ?Action {
        // 1. Exact mode match
        for (self.bindings[0..self.count]) |b| {
            if (b.mode == active_mode and mods.eql(b.mods) and b.key == key) {
                return if (b.action == .none) null else b.action;
            }
        }
        // 2. Shared/shared_except matches
        for (self.bindings[0..self.count]) |b| {
            if (b.mode != active_mode and b.mode.appliesTo(active_mode) and
                mods.eql(b.mods) and b.key == key)
            {
                return if (b.action == .none) null else b.action;
            }
        }
        return null;
    }

    /// Add a binding. Returns false if full.
    pub fn add(self: *Keybinds, mode: Mode, mods: Mods, key: u8, action: Action) bool {
        if (self.count >= MAX_BINDINGS) return false;
        // Overwrite existing binding for same mode+mods+key
        for (self.bindings[0..self.count]) |*b| {
            if (b.mode == mode and mods.eql(b.mods) and b.key == key) {
                b.action = action;
                return true;
            }
        }
        self.bindings[self.count] = .{ .mode = mode, .mods = mods, .key = key, .action = action };
        self.count += 1;
        return true;
    }

    /// Parse a single keybind line: "alt+j = pane:focus_next"
    /// The mode must be set by the caller (from section header).
    pub fn parseLine(self: *Keybinds, mode: Mode, line: []const u8) void {
        // Find = separator
        const eq_idx = std.mem.indexOf(u8, line, "=") orelse return;
        const lhs = std.mem.trim(u8, line[0..eq_idx], " \t");
        const rhs_raw = if (eq_idx + 1 < line.len) line[eq_idx + 1..] else "";
        // Strip inline comment from RHS
        var rhs = std.mem.trim(u8, rhs_raw, " \t");
        if (std.mem.indexOf(u8, rhs, "#")) |hash| {
            rhs = std.mem.trim(u8, rhs[0..hash], " \t");
        }

        const trigger = parseTrigger(lhs) orelse return;

        // Empty RHS = unbind
        if (rhs.len == 0) {
            _ = self.add(mode, trigger.mods, trigger.key, .none);
            return;
        }

        const action = Action.fromString(rhs) orelse return;
        _ = self.add(mode, trigger.mods, trigger.key, action);
    }

    /// Load defaults — the hardcoded binding set.
    pub fn loadDefaults(self: *Keybinds) void {
        self.count = 0;

        // ── Normal mode (Alt shortcuts) ─────────────────
        const n = Mode.normal;
        const A = Mods.ALT;
        const R = Mods.RALT;

        _ = self.add(n, A, 'j', .pane_focus_next);
        _ = self.add(n, A, 'k', .pane_focus_prev);
        _ = self.add(n, A, 'm', .pane_focus_master);
        _ = self.add(n, R, 'm', .pane_set_master);
        _ = self.add(n, R, 'j', .pane_swap_next);
        _ = self.add(n, R, 'k', .pane_swap_prev);
        _ = self.add(n, R, 'h', .resize_shrink_w);
        _ = self.add(n, R, 'l', .resize_grow_w);
        _ = self.add(n, A, 'c', .split_vertical);
        _ = self.add(n, R, 'c', .split_horizontal);
        _ = self.add(n, A, 'x', .pane_close);
        _ = self.add(n, A, 'z', .zoom_toggle);
        _ = self.add(n, A, ' ', .layout_cycle);
        _ = self.add(n, A, '/', .mode_search);
        _ = self.add(n, A, 'v', .mode_scroll);
        _ = self.add(n, A, 'd', .session_detach);
        _ = self.add(n, A, '=', .zoom_in);
        _ = self.add(n, A, '-', .zoom_out);
        _ = self.add(n, A, 'b', .toggle_status_bar);
        _ = self.add(n, A, '\\', .zoom_reset);
        _ = self.add(n, A, '\r', .split_vertical);

        // Alt+1-9 workspaces, RAlt+1-9 move pane
        for (0..9) |i| {
            const digit: u8 = @intCast('1' + i);
            const ws: Action = @enumFromInt(@intFromEnum(Action.workspace_1) + @as(u8, @intCast(i)));
            const mv: Action = @enumFromInt(@intFromEnum(Action.pane_move_to_1) + @as(u8, @intCast(i)));
            _ = self.add(n, A, digit, ws);
            _ = self.add(n, R, digit, mv);
        }
        // Alt+0 = workspace 10, RAlt+0 = move pane to workspace 10
        _ = self.add(n, A, '0', .workspace_0);
        _ = self.add(n, R, '0', .pane_move_to_0);

        // Ctrl+Space enters prefix mode
        _ = self.add(n, Mods.CTRL, ' ', .mode_prefix);

        // ── Prefix mode ─────────────────────────────────
        const p = Mode.prefix;
        const N = Mods.NONE;

        _ = self.add(p, N, 'c', .split_vertical);
        _ = self.add(p, N, '\\', .split_vertical);
        _ = self.add(p, N, '-', .split_horizontal);
        _ = self.add(p, N, 'x', .pane_close);
        _ = self.add(p, N, 'n', .pane_focus_next);
        _ = self.add(p, N, 'p', .pane_focus_prev);
        _ = self.add(p, N, ' ', .layout_cycle);
        _ = self.add(p, N, 'z', .zoom_toggle);
        _ = self.add(p, N, '/', .mode_search);
        _ = self.add(p, N, 'v', .mode_scroll);
        _ = self.add(p, N, 'd', .session_detach);
        _ = self.add(p, N, 0x1b, .mode_normal); // Esc

        for (0..9) |i| {
            const digit: u8 = @intCast('1' + i);
            const ws: Action = @enumFromInt(@intFromEnum(Action.workspace_1) + @as(u8, @intCast(i)));
            _ = self.add(p, N, digit, ws);
        }
        _ = self.add(p, N, '0', .workspace_0);

        // Resize in prefix mode (shifted H/J/K/L)
        _ = self.add(p, Mods.SHIFT, 'h', .resize_shrink_w);
        _ = self.add(p, Mods.SHIFT, 'l', .resize_grow_w);
        _ = self.add(p, Mods.SHIFT, 'k', .resize_shrink_h);
        _ = self.add(p, Mods.SHIFT, 'j', .resize_grow_h);

        // ── Scroll mode ─────────────────────────────────
        const sc = Mode.scroll;

        _ = self.add(sc, N, 'j', .scroll_down_1);
        _ = self.add(sc, N, 'k', .scroll_up_1);
        _ = self.add(sc, Mods.CTRL, 'd', .scroll_down_half);
        _ = self.add(sc, Mods.CTRL, 'u', .scroll_up_half);
        _ = self.add(sc, N, 'g', .scroll_top);
        _ = self.add(sc, Mods.SHIFT, 'g', .scroll_bottom);
        _ = self.add(sc, N, '/', .mode_search);
        _ = self.add(sc, N, 'v', .select_begin);
        _ = self.add(sc, N, 'y', .copy_selection);
        _ = self.add(sc, N, 'q', .mode_normal);
        _ = self.add(sc, N, 0x1b, .mode_normal); // Esc

        // ── Search mode ─────────────────────────────────
        const sr = Mode.search;

        _ = self.add(sr, N, '\r', .search_next); // Enter
        _ = self.add(sr, Mods.SHIFT, 'n', .search_prev);
        _ = self.add(sr, N, 0x1b, .mode_normal); // Esc

        // ── Shared ──────────────────────────────────────
        _ = self.add(.shared, Mods.CTRL_SHIFT, 'c', .copy_selection);
        _ = self.add(.shared, Mods.CTRL_SHIFT, 'v', .paste_clipboard);
    }
};

// ── Tests ───────────────────────────────────────────────────

test "parseTrigger basic" {
    const t1 = parseTrigger("alt+j").?;
    try std.testing.expect(t1.mods.alt);
    try std.testing.expect(!t1.mods.ctrl);
    try std.testing.expectEqual(@as(u8, 'j'), t1.key);

    const t2 = parseTrigger("ctrl+shift+c").?;
    try std.testing.expect(t2.mods.ctrl);
    try std.testing.expect(t2.mods.shift);
    try std.testing.expectEqual(@as(u8, 'c'), t2.key);

    const t3 = parseTrigger("ralt+h").?;
    try std.testing.expect(t3.mods.alt);
    try std.testing.expect(t3.mods.ralt);
    try std.testing.expectEqual(@as(u8, 'h'), t3.key);
}

test "parseTrigger named keys" {
    const t1 = parseTrigger("alt+space").?;
    try std.testing.expectEqual(@as(u8, ' '), t1.key);

    const t2 = parseTrigger("ctrl+space").?;
    try std.testing.expectEqual(@as(u8, ' '), t2.key);
    try std.testing.expect(t2.mods.ctrl);

    const t3 = parseTrigger("esc").?;
    try std.testing.expectEqual(@as(u8, 0x1b), t3.key);
}

test "Action.fromString" {
    try std.testing.expect(Action.fromString("pane:focus_next").? == .pane_focus_next);
    try std.testing.expect(Action.fromString("workspace:3").? == .workspace_3);
    try std.testing.expect(Action.fromString("workspace:0").? == .workspace_0);
    try std.testing.expect(Action.fromString("pane:move_to:5").? == .pane_move_to_5);
    try std.testing.expect(Action.fromString("pane:move_to:0").? == .pane_move_to_0);
    try std.testing.expect(Action.fromString("zoom:in").? == .zoom_in);
    try std.testing.expect(Action.fromString("mode:prefix").? == .mode_prefix);
    try std.testing.expect(Action.fromString("resize:-2:0").? == .resize_shrink_w);
    try std.testing.expect(Action.fromString("bogus") == null);
}

test "Keybinds defaults and lookup" {
    var kb = Keybinds{};
    kb.loadDefaults();

    // Normal mode: Alt+j = focus next
    try std.testing.expect(kb.lookup(.normal, Mods.ALT, 'j').? == .pane_focus_next);
    // Normal mode: Alt+1 = workspace 1
    try std.testing.expect(kb.lookup(.normal, Mods.ALT, '1').? == .workspace_1);
    // Prefix mode: c = split vertical
    try std.testing.expect(kb.lookup(.prefix, Mods.NONE, 'c').? == .split_vertical);
    // Shared: Ctrl+Shift+C = copy
    try std.testing.expect(kb.lookup(.normal, Mods.CTRL_SHIFT, 'c').? == .copy_selection);
    try std.testing.expect(kb.lookup(.scroll, Mods.CTRL_SHIFT, 'c').? == .copy_selection);
    // Unknown key returns null
    try std.testing.expect(kb.lookup(.normal, Mods.NONE, 'q') == null);
}

test "Keybinds parseLine" {
    var kb = Keybinds{};
    kb.parseLine(.normal, "alt+j = pane:focus_next");
    kb.parseLine(.normal, "ctrl+space = mode:prefix");
    kb.parseLine(.prefix, "x = pane:close");

    try std.testing.expect(kb.lookup(.normal, Mods.ALT, 'j').? == .pane_focus_next);
    try std.testing.expect(kb.lookup(.normal, Mods.CTRL, ' ').? == .mode_prefix);
    try std.testing.expect(kb.lookup(.prefix, Mods.NONE, 'x').? == .pane_close);
}

test "Keybinds unbind" {
    var kb = Keybinds{};
    kb.loadDefaults();
    // Alt+j is bound
    try std.testing.expect(kb.lookup(.normal, Mods.ALT, 'j') != null);
    // Unbind it
    kb.parseLine(.normal, "alt+j =");
    // Now returns null
    try std.testing.expect(kb.lookup(.normal, Mods.ALT, 'j') == null);
}

test "Mode.appliesTo" {
    try std.testing.expect(Mode.shared.appliesTo(.normal));
    try std.testing.expect(Mode.shared.appliesTo(.prefix));
    try std.testing.expect(Mode.shared.appliesTo(.scroll));
    try std.testing.expect(!Mode.shared_except_normal.appliesTo(.normal));
    try std.testing.expect(Mode.shared_except_normal.appliesTo(.prefix));
    try std.testing.expect(Mode.shared_except_locked.appliesTo(.normal));
    try std.testing.expect(!Mode.shared_except_locked.appliesTo(.locked));
}
