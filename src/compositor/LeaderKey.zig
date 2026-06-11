//! Doom-Emacs-style leader key + which-key hint for teruwm.
//!
//! `Super+Space` enters leader mode; the top bar turns into a which-key hint
//! showing the available keys for the current node. Keys either descend into a
//! mnemonic GROUP (`w` → +window, `s` → +session, …) — which re-renders the
//! hint for that group — or fire an ACTION and exit. `Esc` (or any unbound key)
//! dismisses.
//!
//! Pure by design: `feedKey` resolves a key to a `Result` (descend / run an
//! action / dismiss) and the caller in ServerInput dispatches the action
//! through `executeAction`. That keeps this module free of a Server dependency
//! (no import cycle) and trivially testable.
//!
//! Phase 1 renders a single-line grouped hint into the top bar (mirrors the
//! launcher). A multi-line floating popup is a later upgrade; the keymap tree
//! and dispatch don't change when that lands.

const std = @import("std");
const teru = @import("teru");
const Ui = teru.Ui;
const SoftwareRenderer = teru.render.SoftwareRenderer;
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

const window_group = [_]Entry{
    .{ .key = 'n', .label = "new", .target = .{ .action = .spawn_terminal } },
    .{ .key = 'x', .label = "close", .target = .{ .action = .pane_close } },
    .{ .key = 'j', .label = "next", .target = .{ .action = .pane_focus_next } },
    .{ .key = 'k', .label = "prev", .target = .{ .action = .pane_focus_prev } },
    .{ .key = 'm', .label = "master", .target = .{ .action = .pane_set_master } },
    .{ .key = 's', .label = "swap-master", .target = .{ .action = .pane_swap_master } },
    .{ .key = 'f', .label = "float", .target = .{ .action = .float_toggle } },
    .{ .key = 'o', .label = "output", .target = .{ .action = .focus_output_next } },
};

const session_group = [_]Entry{
    .{ .key = 's', .label = "save", .target = .{ .action = .session_save } },
    .{ .key = 'r', .label = "restore", .target = .{ .action = .session_restore } },
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
    .{ .key = 's', .label = "status", .target = .{ .action = .toggle_status_bar } },
};

pub const root_group = [_]Entry{
    .{ .key = 'w', .label = "+window", .target = .{ .group = &window_group } },
    .{ .key = 's', .label = "+session", .target = .{ .group = &session_group } },
    .{ .key = 'c', .label = "+capture", .target = .{ .group = &capture_group } },
    .{ .key = 'b', .label = "+bar", .target = .{ .group = &bar_group } },
    .{ .key = ' ', .label = "layout", .target = .{ .action = .layout_cycle } },
    .{ .key = 'z', .label = "zoom", .target = .{ .action = .zoom_toggle } },
    .{ .key = 'f', .label = "fullscreen", .target = .{ .action = .fullscreen_toggle } },
    .{ .key = 'n', .label = "new-term", .target = .{ .action = .spawn_terminal } },
    .{ .key = 'p', .label = "launcher", .target = .{ .action = .launcher_toggle } },
};

// ── State ────────────────────────────────────────────────────────────────

active: bool = false,
/// Current node — root or a descended sub-group.
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
    self.node = &root_group;
    self.crumb = "LEADER";
}

pub fn deactivate(self: *LeaderKey) void {
    self.active = false;
    self.node = &root_group;
    self.crumb = "LEADER";
}

/// Feed a normalized key (lowercased ASCII; space = ' '; Esc = 0x1b) while in
/// leader mode. Returns what the caller should do.
pub fn feedKey(self: *LeaderKey, key: u32) Result {
    if (key == 0x1b) return .dismiss; // Esc

    // Digits at the ROOT switch workspaces (1..9, 0) — the universal shortcut.
    if (self.node.ptr == (&root_group).ptr and key >= '0' and key <= '9') {
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

    for (self.node) |e| {
        if (e.key != key) continue;
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

// ── Which-key hint render (single line, into the top bar) ─────────────────

/// Render the current node as a one-line `crumb  key label  key label …` hint
/// into the bar's framebuffer. Mirrors Launcher.render: clear bg, orange
/// separator, blit chars; keys in the accent colour, labels in fg.
pub fn render(self: *const LeaderKey, cpu: *SoftwareRenderer) void {
    const s = &cpu.scheme;
    const cw: usize = cpu.cell_width;
    const fb_w: usize = cpu.width;
    const bar_h: usize = cpu.height;
    const y: usize = 2;

    const bg = s.ansi[0];
    const total = @min(fb_w * bar_h, cpu.framebuffer.len);
    teru.compat.memsetU32(cpu.framebuffer[0..total], bg);
    if (fb_w > 0 and total >= fb_w) teru.compat.memsetU32(cpu.framebuffer[0..fb_w], s.cursor);

    var x: usize = 4;
    const put = struct {
        fn s_(c: *SoftwareRenderer, str: []const u8, px: *usize, color: u32, cwid: usize, w: usize) void {
            for (str) |ch| {
                if (px.* + cwid >= w) return;
                if (ch >= 32 and ch <= 126) Ui.blitCharAt(c, ch, px.*, 2, color);
                px.* += cwid;
            }
        }
    }.s_;

    // Breadcrumb (e.g. "LEADER" / "+window") in the accent colour, then a gap.
    put(cpu, self.crumb, &x, s.cursor, cw, fb_w);
    x += cw * 2;

    for (self.node) |e| {
        if (x + cw * 4 >= fb_w) break;
        // key
        var kb: [1]u8 = .{if (e.key == ' ') 0 else e.key};
        if (e.key == ' ') {
            put(cpu, "SPC", &x, s.cursor, cw, fb_w);
        } else {
            put(cpu, kb[0..1], &x, s.cursor, cw, fb_w);
        }
        x += cw; // gap between key and label
        put(cpu, e.label, &x, s.fg, cw, fb_w);
        x += cw * 2; // gap between entries
    }
    // Trailing universal hints.
    if (self.node.ptr == (&root_group).ptr and x + cw * 12 < fb_w) {
        put(cpu, "1-9 ws", &x, s.ansi[8], cw, fb_w);
        x += cw * 2;
    }
    if (x + cw * 4 < fb_w) put(cpu, "ESC", &x, s.ansi[8], cw, fb_w);
    _ = y;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "LeaderKey: descend into a group then fire an action" {
    var lk = LeaderKey{};
    lk.activate();
    try std.testing.expect(lk.active);

    // 'w' descends into +window (redraw, still active).
    try std.testing.expect(lk.feedKey('w') == .redraw);
    try std.testing.expectEqualStrings("+window", lk.crumb);

    // 'x' inside +window runs pane_close.
    const r = lk.feedKey('x');
    try std.testing.expect(r == .run and r.run == .pane_close);
}

test "LeaderKey: root digit switches workspace; Esc + unbound dismiss" {
    var lk = LeaderKey{};
    lk.activate();
    const r = lk.feedKey('3');
    try std.testing.expect(r == .run and r.run == .workspace_3);

    lk.activate();
    try std.testing.expect(lk.feedKey(0x1b) == .dismiss); // Esc
    lk.activate();
    try std.testing.expect(lk.feedKey('Q') == .dismiss); // unbound
}

test "LeaderKey: root direct action (layout on SPC)" {
    var lk = LeaderKey{};
    lk.activate();
    const r = lk.feedKey(' ');
    try std.testing.expect(r == .run and r.run == .layout_cycle);
}
