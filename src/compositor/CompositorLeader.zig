//! teruwm's default leader/which-key tree — the comptime keymap the shared
//! `teru.LeaderKey` engine walks when the user hasn't defined `[leader]`
//! sections in `~/.config/teruwm/config`. Built ONLY from actions teruwm
//! actually handles (ServerInput.executeAction). Capital keys (J/K/M/O/T/R)
//! require Shift — the engine's feedKey is shift-aware.
//!
//! The terminal binary (teru) supplies its own tree; this one is
//! compositor-specific (float, screenshots, bar toggles, scratchpads, …).

const teru = @import("teru");
const Entry = teru.LeaderKey.Entry;

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

test "CompositorLeader: tree drives the shared engine (descend + Shift)" {
    const std = @import("std");
    var lk = teru.LeaderKey{};
    lk.root = &root_group;
    lk.activate();
    try std.testing.expect(lk.feedKey('w', false) == .redraw); // +window
    const r = lk.feedKey('j', true); // Shift+j → swap-next
    try std.testing.expect(r == .run and r.run == .pane_swap_next);
}
