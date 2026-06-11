//! teru's (terminal/multiplexer) default leader/which-key tree — the keymap
//! the shared `LeaderKey` engine walks in the TUI client (`Alt+Space`). Built
//! from actions the TUI client can dispatch to the daemon (see
//! TuiInput.actionToTui). SSH-survival flavored: `d` detach is at the root so
//! "how do I get out of this" is one chord away.
//!
//! Targets the canonical `Keybinds.Action` vocabulary (shared with teruwm and
//! the keybind config); the TUI client maps each Action → daemon command. The
//! tree is config-overridable via teru.conf `[leader]` (future) — and since
//! binding is by CHARACTER (terminals transmit the layout-applied char, never a
//! scancode), the keys here are the characters you press, whatever your layout.

const LeaderKey = @import("../config/LeaderKey.zig");
const Entry = LeaderKey.Entry;

const pane_group = [_]Entry{
    .{ .key = 'c', .label = "split-v", .target = .{ .action = .split_vertical } },
    .{ .key = 'v', .label = "split-v", .target = .{ .action = .split_vertical } },
    .{ .key = '-', .label = "split-h", .target = .{ .action = .split_horizontal } },
    .{ .key = 'x', .label = "close", .target = .{ .action = .pane_close } },
    .{ .key = 'j', .label = "focus-next", .target = .{ .action = .pane_focus_next } },
    .{ .key = 'k', .label = "focus-prev", .target = .{ .action = .pane_focus_prev } },
    .{ .key = 'J', .label = "swap-next", .target = .{ .action = .pane_swap_next } },
    .{ .key = 'K', .label = "swap-prev", .target = .{ .action = .pane_swap_prev } },
    .{ .key = 'g', .label = "focus-master", .target = .{ .action = .pane_focus_master } },
    .{ .key = 'M', .label = "swap-master", .target = .{ .action = .pane_swap_master } },
};

const layout_group = [_]Entry{
    .{ .key = ' ', .label = "cycle", .target = .{ .action = .layout_cycle } },
    .{ .key = 'r', .label = "reset", .target = .{ .action = .layout_reset } },
    .{ .key = 'i', .label = "master+", .target = .{ .action = .master_count_inc } },
    .{ .key = 'd', .label = "master-", .target = .{ .action = .master_count_dec } },
    .{ .key = 'h', .label = "shrink", .target = .{ .action = .resize_shrink_w } },
    .{ .key = 'l', .label = "grow", .target = .{ .action = .resize_grow_w } },
};

// Move the focused pane to workspace N. Digits are ordinary keys OFF the root.
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

pub const root_group = [_]Entry{
    .{ .key = 'd', .label = "detach", .target = .{ .action = .session_detach } },
    .{ .key = ' ', .label = "layout", .target = .{ .action = .layout_cycle } },
    .{ .key = 'z', .label = "zoom", .target = .{ .action = .zoom_toggle } },
    .{ .key = 'n', .label = "new", .target = .{ .action = .split_vertical } },
    .{ .key = 'p', .label = "+pane", .target = .{ .group = &pane_group } },
    .{ .key = 'l', .label = "+layout", .target = .{ .group = &layout_group } },
    .{ .key = 'm', .label = "+move", .target = .{ .group = &move_group } },
};

test "MuxLeader: tree drives the shared engine + detach reachable" {
    const std = @import("std");
    var lk = LeaderKey{};
    lk.root = &root_group;
    lk.activate();
    // root 'd' = detach (the SSH-survival exit)
    var r = lk.feedKey('d', false);
    try std.testing.expect(r == .run and r.run == .session_detach);
    // descend +pane, Shift+j = swap-next
    lk.activate();
    try std.testing.expect(lk.feedKey('p', false) == .redraw);
    r = lk.feedKey('j', true);
    try std.testing.expect(r == .run and r.run == .pane_swap_next);
    // +move digit
    lk.activate();
    _ = lk.feedKey('m', false);
    r = lk.feedKey('2', false);
    try std.testing.expect(r == .run and r.run == .pane_move_to_2);
}
