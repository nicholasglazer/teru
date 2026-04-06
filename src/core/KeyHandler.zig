//! Multiplexer key command handling.
//!
//! Contains the prefix-key state machine and mux command dispatch.
//! Extracted from main.zig for modularity — the event loop calls
//! into these helpers rather than inlining the logic.

const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const Multiplexer = @import("Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Hooks = @import("../config/Hooks.zig");
const compat = @import("../compat.zig");

// ── Prefix key state ─────────────────────────────────────────────

pub const PrefixState = struct {
    awaiting: bool = false,
    timestamp_ns: i128 = 0,
    timeout_ns: i128 = 500_000_000, // configurable via prefix_timeout_ms

    pub fn activate(self: *PrefixState) void {
        self.awaiting = true;
        self.timestamp_ns = compat.nanoTimestamp();
    }

    pub fn isExpired(self: *const PrefixState) bool {
        if (!self.awaiting) return false;
        const elapsed = compat.nanoTimestamp() - self.timestamp_ns;
        return elapsed > self.timeout_ns;
    }

    pub fn reset(self: *PrefixState) void {
        self.awaiting = false;
    }
};

// ── Mux command result ──────────────────────────────────────────

/// Action returned by handleMuxCommand for the caller to act on.
pub const MuxAction = enum {
    none,
    enter_search,
    enter_vi_mode,
    panes_changed,
    split_horizontal,
    split_vertical,
    close_pane,
    zoom_in,
    zoom_out,
};

// ── Mux command dispatch ─────────────────────────────────────────

fn writeMsg(msg: []const u8) void {
    _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
}

/// Handle a multiplexer command after the prefix key (Ctrl+Space).
/// Returns an action the caller should handle (e.g., entering search mode).
pub fn handleMuxCommand(
    cmd: u8,
    mux: *Multiplexer,
    graph: *ProcessGraph,
    hooks: *const Hooks,
    running: *bool,
    grid_rows: u16,
    grid_cols: u16,
    io: Io,
    prefix_byte: u8,
) MuxAction {
    _ = grid_rows;
    _ = grid_cols;
    // Normalize Ctrl+letter (0x01-0x1A) to plain letter.
    // If user holds Ctrl while pressing the command key (e.g., Ctrl still
    // held after prefix), xkbcommon sends Ctrl+V (0x16) instead of 'v'.
    const key = if (cmd >= 1 and cmd <= 26) cmd + 0x60 else cmd;
    switch (key) {
        'c', '\\' => return .split_vertical,
        '-' => return .split_horizontal,
        'x' => {
            // Close active pane
            if (mux.getActivePane()) |pane| {
                const id = pane.id;
                mux.closePane(id);
                hooks.fire(.close);
                if (mux.panes.items.len == 0) {
                    running.* = false;
                    return .none;
                }
            }
            return .panes_changed;
        },
        'n' => mux.focusNext(),
        'p' => mux.focusPrev(),
        ' ' => {
            mux.cycleLayout();
            return .panes_changed;
        },
        'd' => {
            // Detach: save session and exit
            const path = "/tmp/teru-session.bin";
            const pane_n = mux.panes.items.len;
            mux.saveSession(graph, path, io) catch {
                writeMsg("[teru] Session save failed, exiting anyway\n");
                running.* = false;
                return .none;
            };
            hooks.fire(.session_save);
            var dbuf: [256]u8 = undefined;
            const dmsg = std.fmt.bufPrint(&dbuf, "[teru] Session saved to {s} ({d} panes)\n[teru] Note: processes are not preserved. Use --attach to restore layout.\n", .{ path, pane_n }) catch "[teru] Session saved\n";
            writeMsg(dmsg);
            running.* = false;
        },
        '/' => {
            // Enter search mode (caller handles the UI)
            return .enter_search;
        },
        '1'...'9' => {
            // Switch workspace (1-based → 0-based)
            mux.switchWorkspace(cmd - '1');
        },
        'v' => return .enter_vi_mode,
        'z' => {
            mux.toggleZoom();
            return .panes_changed;
        },
        'H' => {
            mux.resizeActive(-2, 0);
            return .panes_changed;
        },
        'L' => {
            mux.resizeActive(2, 0);
            return .panes_changed;
        },
        'K' => {
            mux.resizeActive(0, -2);
            return .panes_changed;
        },
        'J' => {
            mux.resizeActive(0, 2);
            return .panes_changed;
        },
        else => {
            // Unknown command; forward the prefix + key to active pane
            if (mux.getActivePane()) |pane| {
                const pfx = [1]u8{prefix_byte};
                _ = pane.pty.write(&pfx) catch {};
                const byte = [1]u8{cmd};
                _ = pane.pty.write(&byte) catch {};
            }
        },
    }
    return .none;
}

// ── Global shortcuts (Alt+key, no prefix required) ──────────────

const kc = @import("../platform/types.zig").keycodes;

/// Handle global Alt+key shortcuts (no prefix required).
/// Digits use platform keycodes (layout-independent for number row).
/// Letters use keysyms so they match the active layout (QWERTY/Dvorak/etc).
///
///   Alt+1-9         — switch workspace
///   RAlt+1-9        — move active pane to workspace
///   Alt+j / Alt+k   — focus next / prev pane
///   RAlt+j / RAlt+k — swap pane next / prev
///   Alt+c           — new pane (vertical split)
///   RAlt+c          — new pane (horizontal split)
///   Alt+x           — close active pane
///   Alt+m           — focus master pane
///   RAlt+m          — mark active pane as master
///   Alt+-           — zoom out (decrease font size)
///   Alt+=           — zoom in (increase font size)
///
/// Returns null if the key should pass through to the PTY.
pub fn handleGlobalKey(keycode: u32, modifiers: u32, key_char: u8, alt_enabled: bool, ralt: bool, mux: *Multiplexer) ?MuxAction {
    if (!alt_enabled or modifiers & kc.ALT_MASK == 0) return null;

    // Alt+1-9: switch workspace / RAlt+1-9: move pane to workspace
    if (kc.digitToWorkspace(keycode)) |target_ws| {
        if (ralt) _ = mux.movePaneToWorkspace(target_ws) else mux.switchWorkspace(target_ws);
        return .panes_changed;
    }

    // Letter/symbol shortcuts use keysym (matches active layout: Dvorak, QWERTY, etc)
    return switch (key_char) {
        'j' => { if (ralt) mux.swapPaneNext() else mux.focusNext(); return .panes_changed; },
        'k' => { if (ralt) mux.swapPanePrev() else mux.focusPrev(); return .panes_changed; },
        'c' => if (ralt) .split_horizontal else .split_vertical,
        'x' => .close_pane,
        'm' => { if (ralt) mux.setMaster() else mux.focusMaster(); return .panes_changed; },
        '-' => .zoom_out,
        '=' => .zoom_in,
        else => null,
    };
}

// ── Tests ────────────────────────────────────────────────────────

test "PrefixState init is inactive" {
    const ps = PrefixState{};
    try std.testing.expect(!ps.awaiting);
    try std.testing.expect(!ps.isExpired());
}

test "PrefixState activate and reset" {
    var ps = PrefixState{};
    ps.activate();
    try std.testing.expect(ps.awaiting);
    try std.testing.expect(!ps.isExpired()); // just activated, not expired
    ps.reset();
    try std.testing.expect(!ps.awaiting);
}

test "handleGlobalKey returns null when disabled or no Alt" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(10, kc.ALT_MASK, 'j', false, false, &mux) == null);
    try std.testing.expect(handleGlobalKey(10, 0, 'j', true, false, &mux) == null);
    try std.testing.expect(handleGlobalKey(99, kc.ALT_MASK, 'q', true, false, &mux) == null);
}

test "handleGlobalKey Alt+digit switches workspace" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    const digit3_kc: u32 = comptime blk: {
        var k: u32 = 0;
        while (k < 256) : (k += 1) {
            if (kc.digitToWorkspace(k)) |ws| {
                if (ws == 2) break :blk k;
            }
        }
        unreachable;
    };
    const action = handleGlobalKey(digit3_kc, kc.ALT_MASK, '3', true, false, &mux);
    try std.testing.expect(action != null);
    try std.testing.expect(action.? == .panes_changed);
    try std.testing.expectEqual(@as(u8, 2), mux.active_workspace);
}

test "handleGlobalKey Alt+j/k focuses panes" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'j', true, false, &mux).? == .panes_changed);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'k', true, false, &mux).? == .panes_changed);
}

test "handleGlobalKey Alt+-/= zooms" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, '-', true, false, &mux).? == .zoom_out);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, '=', true, false, &mux).? == .zoom_in);
}

test "handleGlobalKey Alt+c splits" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'c', true, false, &mux).? == .split_vertical);
}

test "handleGlobalKey RAlt+j/k swaps panes" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'j', true, true, &mux).? == .panes_changed);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'k', true, true, &mux).? == .panes_changed);
}

test "handleGlobalKey RAlt+m marks master, Alt+m focuses" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'm', true, true, &mux).? == .panes_changed);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'm', true, false, &mux).? == .panes_changed);
}
