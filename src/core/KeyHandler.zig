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
    // Normalize Ctrl+letter (0x01-0x1A) to plain letter.
    // If user holds Ctrl while pressing the command key (e.g., Ctrl still
    // held after prefix), xkbcommon sends Ctrl+V (0x16) instead of 'v'.
    const key = if (cmd >= 1 and cmd <= 26) cmd + 0x60 else cmd;
    switch (key) {
        'c' => {
            // Spawn new pane
            const id = mux.spawnPane(grid_rows, grid_cols) catch return .none;
            if (mux.getPaneById(id)) |pane| {
                // Graph registration failure is non-fatal: pane works without tracking
                _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.pty.child_pid }) catch {};
            }
            hooks.fire(.spawn);
        },
        'x' => {
            // Close active pane
            if (mux.getActivePane()) |pane| {
                const id = pane.id;
                mux.closePane(id);
                hooks.fire(.close);
                // If no panes left, exit
                if (mux.panes.items.len == 0) {
                    running.* = false;
                }
            }
        },
        'n' => mux.focusNext(),
        'p' => mux.focusPrev(),
        ' ' => mux.cycleLayout(),
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
            // Zoom: toggle active pane between current layout and monocle
            mux.toggleZoom();
        },
        'H' => mux.resizeActive(-2, 0),   // shrink width
        'L' => mux.resizeActive(2, 0),    // grow width
        'K' => mux.resizeActive(0, -2),   // shrink height
        'J' => mux.resizeActive(0, 2),    // grow height
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
