//! Doom-Emacs-style leader / which-key DISPATCHER — shared by teruwm (the
//! compositor) and teru (the terminal/multiplexer). Pure: it walks a
//! `[]const Entry` keymap tree and resolves a key to a `Result` (descend a
//! group / run an action / dismiss). It owns no rendering and no I/O, so each
//! binary supplies its own:
//!   - keymap TREE (compositor actions vs terminal actions) via `root`,
//!   - dispatch SINK (executeAction) for `Result.run`,
//!   - RENDERER (wlr scene buffer pixels in teruwm; ANSI cells in teru's TUI).
//!
//! Trees live with their consumer (compositor: CompositorLeader.zig; terminal:
//! its own tree), or are built at runtime from `[leader]` config. This module
//! is just the engine.

const std = @import("std");
const Keybinds = @import("Keybinds.zig");
const Action = Keybinds.Action;

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

/// Shared empty default so `root`/`node` start equal (atRoot true) before a
/// binary assigns its real tree.
const empty: []const Entry = &.{};

// ── State ────────────────────────────────────────────────────────────────

active: bool = false,
/// The root node. A binary (or config build) MUST point this at its tree;
/// until then the menu is empty (any key dismisses — harmless).
root: []const Entry = empty,
/// Current node — `root` or a descended sub-group.
node: []const Entry = empty,
/// Breadcrumb label for the hint ("LEADER" or e.g. "+window").
crumb: []const u8 = "LEADER",

pub const Result = union(enum) {
    /// Key descended into a group / was a no-op — re-render the hint.
    redraw,
    /// Fire this action, then leave leader mode.
    run: Action,
    /// Leave leader mode (Esc or an unbound key) — restore the normal UI.
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
/// Shift state, while in leader mode. Shift promotes a letter to its uppercase
/// entry key (so `Shift+j` matches a 'J' entry distinctly from 'j'); digits and
/// symbols are unaffected. Returns what the caller should do.
pub fn feedKey(self: *LeaderKey, key: u32, shift: bool) Result {
    if (key == 0x1b) return .dismiss; // Esc

    // Digits at the ROOT switch workspaces (1..9, 0) — the universal shortcut.
    // (Inside a sub-group, digits are ordinary entry keys.)
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
pub fn atRoot(self: *const LeaderKey) bool {
    return self.node.ptr == self.root.ptr;
}

// ── Tests (engine only — uses a tiny inline tree, not any binary's) ────────

test "LeaderKey: descend, run, shift, digit, dismiss" {
    const sub = [_]Entry{
        .{ .key = 'x', .label = "close", .target = .{ .action = .window_close } },
        .{ .key = 'J', .label = "swap-next", .target = .{ .action = .pane_swap_next } },
        .{ .key = '0', .label = "reset", .target = .{ .action = .layout_reset } },
    };
    const root = [_]Entry{
        .{ .key = 'w', .label = "+win", .target = .{ .group = &sub } },
        .{ .key = ' ', .label = "layout", .target = .{ .action = .layout_cycle } },
    };
    var lk = LeaderKey{};
    lk.root = &root;
    lk.activate();
    try std.testing.expect(lk.atRoot());

    // root direct action
    var r = lk.feedKey(' ', false);
    try std.testing.expect(r == .run and r.run == .layout_cycle);

    // descend then run
    lk.activate();
    try std.testing.expect(lk.feedKey('w', false) == .redraw);
    try std.testing.expect(!lk.atRoot());
    try std.testing.expectEqualStrings("+win", lk.crumb);
    r = lk.feedKey('x', false);
    try std.testing.expect(r == .run and r.run == .window_close);

    // Shift promotes j→J (distinct entry); digit off-root is an ordinary key
    lk.activate();
    _ = lk.feedKey('w', false);
    r = lk.feedKey('j', true);
    try std.testing.expect(r == .run and r.run == .pane_swap_next);
    lk.activate();
    _ = lk.feedKey('w', false);
    r = lk.feedKey('0', false); // off-root digit → entry, not workspace
    try std.testing.expect(r == .run and r.run == .layout_reset);

    // root digit switches workspace; Esc + unbound dismiss
    lk.activate();
    r = lk.feedKey('3', false);
    try std.testing.expect(r == .run and r.run == .workspace_3);
    lk.activate();
    try std.testing.expect(lk.feedKey(0x1b, false) == .dismiss);
    lk.activate();
    try std.testing.expect(lk.feedKey('Z', false) == .dismiss);
}
