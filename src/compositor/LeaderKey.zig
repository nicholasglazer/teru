//! Doom-Emacs-style leader key + which-key menu for teruwm.
//!
//! `Super+Space` (rebindable) enters leader mode; LeaderPanel draws a bottom
//! overlay HUD listing the keys for the current node. Keys either descend into
//! a mnemonic GROUP (`w` → +window, `l` → +layout, …) — which re-renders the
//! hint for that group — or fire an ACTION and exit. `Esc` (or any unbound key)
//! dismisses.
//!
//! Pure by design: `feedKey` resolves a key to a `Result` (descend / run an
//! action / dismiss) and the caller in ServerInput dispatches the action
//! through `executeAction`. That keeps this module free of a Server dependency
//! (no import cycle) and trivially testable.
//!
//! The keymap tree is a `[]const Entry` node. By default `root` points at the
//! comptime `root_group` below; when the user defines `[leader]` sections in
//! `~/.config/teruwm/config`, ServerConfig builds a runtime tree (LeaderConfig)
//! and repoints `root` at it. feedKey/atRoot operate on whichever `[]const
//! Entry` they're handed, so the dispatch logic is identical either way.

const std = @import("std");
const teru = @import("teru");
const Action = teru.Keybinds.Action;

const LeaderKey = @This();

/// One which-key row: a key, a short label, and what it targets.
pub const Entry = struct {
    key: u8,
    label: []const u8,
    target: Target,
};

pub const Target = union(enum) {
    /// Fire this action and leave leader mode.
    action: Action,
    /// Descend into a sub-group (re-renders the hint for it).
    group: []const Entry,
};

// ── The B-style keymap tree (mnemonic groups) ────────────────────────────
// Built from teruwm's *actually handled* actions (ServerInput.executeAction).
// Capital keys (J/K/M/O/T/R) require Shift — feedKey is shift-aware.

const window_group = [_]Entry{
    .{ .key = 'n', .label = "new", .target = .{ .action = .spawn_terminal } },
    .{ .key = 'x', .label = "close", .target = .{ .action = .window_close } },
    .{ .key = 'j', .label = "focus-next", .target = .{ .action = .pane_focus_next } },
    .{ .key = 'k', .label = "focus-prev", .target = .{ .action = .pane_focus_prev } },
    .{ .key = 'J', .label = "swap-next", .target = .{ .action = .pane_swap_next } },
    .{ .key = 'K', .label = "swap-prev", .target = .{ .action = .pane_swap_prev } },
    .{ .key = 'm', .label = "focus-master", .target = .{ .action = .pane_focus_master } },
    .{ .key = 'M', .label = "promote", .target = .{ .action = .pane_set_master } },
    .{ .key = 'f', .label = "float", .target = .{ .action = .float_toggle } },
    .{ .key = 'o', .label = "focus-output", .target = .{ .action = .focus_output_next } },
    .{ .key = 'O', .label = "move-output", .target = .{ .action = .move_to_output_next } },
};

const layout_group = [_]Entry{
    .{ .key = ' ', .label = "cycle", .target = .{ .action = .layout_cycle } },
    .{ .key = '0', .label = "reset", .target = .{ .action = .layout_reset } },
    .{ .key = 'i', .label = "master+", .target = .{ .action = .master_count_inc } },
    .{ .key = 'd', .label = "master-", .target = .{ .action = .master_count_dec } },
    .{ .key = 'h', .label = "shrink", .target = .{ .action = .resize_shrink_w } },
    .{ .key = 'l', .label = "grow", .target = .{ .action = .resize_grow_w } },
    .{ .key = 's', .label = "swap-master", .target = .{ .action = .pane_swap_master } },
    .{ .key = 'z', .label = "zoom", .target = .{ .action = .zoom_toggle } },
};

// Move the focused pane to workspace N. Digits are ordinary keys OFF the root
// (the digit→workspace shortcut only fires at root), so 1..9,0 are safe here.
const move_group = [_]Entry{
    .{ .key = '1', .label = "ws-1", .target = .{ .action = .pane_move_to_1 } },
    .{ .key = '2', .label = "ws-2", .target = .{ .action = .pane_move_to_2 } },
    .{ .key = '3', .label = "ws-3", .target = .{ .action = .pane_move_to_3 } },
    .{ .key = '4', .label = "ws-4", .target = .{ .action = .pane_move_to_4 } },
    .{ .key = '5', .label = "ws-5", .target = .{ .action = .pane_move_to_5 } },
    .{ .key = '6', .label = "ws-6", .target = .{ .action = .pane_move_to_6 } },
    .{ .key = '7', .label = "ws-7", .target = .{ .action = .pane_move_to_7 } },
    .{ .key = '8', .label = "ws-8", .target = .{ .action = .pane_move_to_8 } },
    .{ .key = '9', .label = "ws-9", .target = .{ .action = .pane_move_to_9 } },
    .{ .key = '0', .label = "ws-10", .target = .{ .action = .pane_move_to_0 } },
};

const scratchpad_group = [_]Entry{
    .{ .key = 't', .label = "term-BR", .target = .{ .action = .scratchpad_0 } },
    .{ .key = 'T', .label = "term-SR", .target = .{ .action = .scratchpad_1 } },
};

const capture_group = [_]Entry{
    .{ .key = 's', .label = "screen", .target = .{ .action = .screenshot } },
    .{ .key = 'a', .label = "area", .target = .{ .action = .screenshot_area } },
    .{ .key = 'p', .label = "pane", .target = .{ .action = .screenshot_pane } },
    .{ .key = 'r', .label = "record", .target = .{ .action = .screen_record } },
};

const bar_group = [_]Entry{
    .{ .key = 't', .label = "top", .target = .{ .action = .bar_toggle_top } },
    .{ .key = 'b', .label = "bottom", .target = .{ .action = .bar_toggle_bottom } },
};

const system_group = [_]Entry{
    .{ .key = 'r', .label = "reload", .target = .{ .action = .config_reload } },
    .{ .key = 'R', .label = "restart", .target = .{ .action = .compositor_restart } },
    .{ .key = 'q', .label = "quit", .target = .{ .action = .compositor_quit } },
    .{ .key = 's', .label = "save", .target = .{ .action = .session_save } },
    .{ .key = 'l', .label = "load", .target = .{ .action = .session_restore } },
};

pub const root_group = [_]Entry{
    .{ .key = ' ', .label = "layout", .target = .{ .action = .layout_cycle } },
    .{ .key = 'z', .label = "zoom", .target = .{ .action = .zoom_toggle } },
    .{ .key = 'f', .label = "fullscreen", .target = .{ .action = .fullscreen_toggle } },
    .{ .key = 'n', .label = "new-term", .target = .{ .action = .spawn_terminal } },
    .{ .key = 'p', .label = "launcher", .target = .{ .action = .launcher_toggle } },
    .{ .key = 'w', .label = "+window", .target = .{ .group = &window_group } },
    .{ .key = 'l', .label = "+layout", .target = .{ .group = &layout_group } },
    .{ .key = 'm', .label = "+move", .target = .{ .group = &move_group } },
    .{ .key = 's', .label = "+scratchpad", .target = .{ .group = &scratchpad_group } },
    .{ .key = 'c', .label = "+capture", .target = .{ .group = &capture_group } },
    .{ .key = 'b', .label = "+bar", .target = .{ .group = &bar_group } },
    .{ .key = 'x', .label = "+system", .target = .{ .group = &system_group } },
};

// ── State ────────────────────────────────────────────────────────────────

active: bool = false,
/// The root node. Defaults to the comptime tree; ServerConfig repoints this at
/// a runtime tree when the user configures `[leader]` sections.
root: []const Entry = &root_group,
/// Current node — `root` or a descended sub-group.
node: []const Entry = &root_group,
/// Breadcrumb label for the hint ("LEADER" or e.g. "+window").
crumb: []const u8 = "LEADER",

pub const Result = union(enum) {
    /// Key descended into a group / was a no-op — re-render the hint.
    redraw,
    /// Fire this action, then leave leader mode.
    run: Action,
    /// Leave leader mode (Esc or an unbound key) — restore the normal bar.
    dismiss,
};

pub fn activate(self: *LeaderKey) void {
    self.active = true;
    self.node = self.root;
    self.crumb = "LEADER";
}

pub fn deactivate(self: *LeaderKey) void {
    self.active = false;
    self.node = self.root;
    self.crumb = "LEADER";
}

/// Feed a normalized key (lowercased ASCII; space = ' '; Esc = 0x1b) plus the
/// Shift state, while in leader mode. Returns what the caller should do. Shift
/// promotes a letter to its uppercase entry key (so `Shift+j` matches a 'J'
/// entry distinctly from 'j') — digits and symbols are unaffected.
pub fn feedKey(self: *LeaderKey, key: u32, shift: bool) Result {
    if (key == 0x1b) return .dismiss; // Esc

    // Digits at the ROOT switch workspaces (1..9, 0) — the universal shortcut.
    // (Inside a sub-group, digits are ordinary entry keys: +move, +layout reset.)
    if (self.atRoot() and key >= '0' and key <= '9') {
        const ws: Action = switch (key) {
            '1' => .workspace_1,
            '2' => .workspace_2,
            '3' => .workspace_3,
            '4' => .workspace_4,
            '5' => .workspace_5,
            '6' => .workspace_6,
            '7' => .workspace_7,
            '8' => .workspace_8,
            '9' => .workspace_9,
            else => .workspace_0,
        };
        return .{ .run = ws };
    }

    // Shift'd letter → uppercase entry key (J/K/M/O/T/R …).
    const ek: u32 = if (shift and key >= 'a' and key <= 'z') key - 32 else key;

    for (self.node) |e| {
        if (e.key != ek) continue;
        switch (e.target) {
            .action => |a| return .{ .run = a },
            .group => |g| {
                self.node = g;
                self.crumb = e.label;
                return .redraw;
            },
        }
    }
    return .dismiss; // unbound key → dismiss (Doom behaviour)
}

/// True when the current node is the root (digits switch workspaces there).
/// Rendering lives in LeaderPanel, which reads `node`/`crumb`/this helper.
pub fn atRoot(self: *const LeaderKey) bool {
    return self.node.ptr == self.root.ptr;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "LeaderKey: descend into a group then fire an action" {
    var lk = LeaderKey{};
    lk.activate();
    try std.testing.expect(lk.active);

    // 'w' descends into +window (redraw, still active).
    try std.testing.expect(lk.feedKey('w', false) == .redraw);
    try std.testing.expectEqualStrings("+window", lk.crumb);

    // 'x' inside +window runs window_close (the real bound close).
    const r = lk.feedKey('x', false);
    try std.testing.expect(r == .run and r.run == .window_close);
}

test "LeaderKey: Shift promotes a letter to its uppercase entry" {
    var lk = LeaderKey{};
    lk.activate();
    try std.testing.expect(lk.feedKey('w', false) == .redraw);
    // Shift+j inside +window = swap-next (distinct from plain j = focus-next).
    const shifted = lk.feedKey('j', true);
    try std.testing.expect(shifted == .run and shifted.run == .pane_swap_next);

    lk.activate();
    _ = lk.feedKey('w', false);
    const plain = lk.feedKey('j', false);
    try std.testing.expect(plain == .run and plain.run == .pane_focus_next);
}

test "LeaderKey: root digit switches workspace; Esc + unbound dismiss" {
    var lk = LeaderKey{};
    lk.activate();
    const r = lk.feedKey('3', false);
    try std.testing.expect(r == .run and r.run == .workspace_3);

    lk.activate();
    try std.testing.expect(lk.feedKey(0x1b, false) == .dismiss); // Esc
    lk.activate();
    try std.testing.expect(lk.feedKey('Q', false) == .dismiss); // unbound (raw uppercase)
}

test "LeaderKey: digits are ordinary entry keys off-root (+move)" {
    var lk = LeaderKey{};
    lk.activate();
    try std.testing.expect(lk.feedKey('m', false) == .redraw); // descend +move
    try std.testing.expectEqualStrings("+move", lk.crumb);
    const r = lk.feedKey('3', false); // 3 → move pane to workspace 3
    try std.testing.expect(r == .run and r.run == .pane_move_to_3);
}

test "LeaderKey: root direct action (layout on SPC)" {
    var lk = LeaderKey{};
    lk.activate();
    const r = lk.feedKey(' ', false);
    try std.testing.expect(r == .run and r.run == .layout_cycle);
}
