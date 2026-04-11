//! TuiInput: parse raw terminal bytes into structured key events for TUI mode.
//!
//! Handles ANSI escape sequence parsing from stdin in raw terminal mode:
//! - Alt+key detection (ESC + byte within timeout)
//! - CSI sequences (arrows, function keys, modifiers)
//! - Ctrl+key detection
//! - Raw input passthrough for regular typing
//!
//! Returns Actions that map to daemon protocol commands or raw bytes to forward.

const std = @import("std");
const daemon_proto = @import("../server/protocol.zig");
const compat = @import("../compat.zig");

pub const Action = union(enum) {
    /// Raw bytes to forward to daemon as active_input
    raw_input: struct { data: []const u8 },
    /// Multiplexer command to send to daemon
    command: daemon_proto.Command,
    /// Workspace switch (command + workspace index)
    workspace: u8,
    /// Mouse click at (col, row) — 0-indexed, relative to TUI screen
    mouse_click: struct { col: u16, row: u16, button: u8, release: bool },
    /// Detach from session
    detach,
    /// No action (incomplete sequence, need more bytes)
    none,
};

const State = enum {
    ground,
    escape,
    csi,
};

const Self = @This();

state: State = .ground,
/// Buffer for accumulating CSI parameters
csi_buf: [32]u8 = undefined,
csi_len: usize = 0,
/// Timestamp of last ESC byte (for Alt+key timeout)
esc_timestamp: i64 = 0,
/// When nested inside another teru, only use prefix key (no Alt shortcuts)
nested: bool = false,
/// Last mouse event (set by feed(), consumed by caller)
last_mouse: ?struct { col: u16, row: u16, button: u8, release: bool } = null,
/// Prefix key state (Ctrl+Space = 0x00)
prefix_active: bool = false,
prefix_timestamp: i64 = 0,
prefix_timeout_ms: i64 = 500,

pub fn init() Self {
    return .{};
}

/// Create a TuiInput that detects nesting automatically.
/// When nested inside another teru (TERM_PROGRAM=teru), Alt+key bindings
/// are disabled and only prefix commands (Ctrl+Space + key) are used.
pub fn initAutoDetect() Self {
    const nested = if (compat.getenv("TERM_PROGRAM")) |tp|
        std.mem.eql(u8, std.mem.sliceTo(tp, 0), "teru")
    else
        false;
    return .{ .nested = nested };
}

/// Process a chunk of raw input bytes.
/// Returns true if a detach was requested (caller should exit TUI mode).
pub fn feed(self: *Self, bytes: []const u8, daemon_fd: std.posix.fd_t) bool {
    var raw_start: usize = 0;
    var i: usize = 0;

    while (i < bytes.len) {
        const b = bytes[i];

        switch (self.state) {
            .ground => {
                // Ctrl+B (0x02) = TUI prefix key
                // Uses Ctrl+B (not Ctrl+Space) to avoid conflict with outer teru
                if (b == 0x02) {
                    if (i > raw_start) {
                        _ = daemon_proto.sendMessage(daemon_fd, .active_input, bytes[raw_start..i]);
                    }
                    self.prefix_active = true;
                    self.prefix_timestamp = @as(i64, @intCast(@divFloor(compat.monotonicNow(), 1_000_000)));
                    i += 1;
                    raw_start = i;
                    continue;
                }

                // If prefix is active, intercept next key as a command
                if (self.prefix_active) {
                    if (i > raw_start) {
                        _ = daemon_proto.sendMessage(daemon_fd, .active_input, bytes[raw_start..i]);
                    }
                    const action = self.handlePrefixKey(b);
                    self.prefix_active = false;
                    i += 1;
                    raw_start = i;
                    if (action == .detach) {
                        _ = daemon_proto.sendMessage(daemon_fd, .detach, &.{});
                        return true;
                    }
                    if (action != .none) {
                        self.dispatchAction(action, daemon_fd);
                    }
                    continue;
                }

                if (b == 0x1B) {
                    // Flush raw bytes before ESC
                    if (i > raw_start) {
                        _ = daemon_proto.sendMessage(daemon_fd, .active_input, bytes[raw_start..i]);
                    }
                    self.state = .escape;
                    self.esc_timestamp = @as(i64, @intCast(@divFloor(compat.monotonicNow(), 1_000_000)));
                    i += 1;
                    raw_start = i;
                    continue;
                } else if (b == 0x1C) {
                    // Ctrl+\ = detach
                    if (i > raw_start) {
                        _ = daemon_proto.sendMessage(daemon_fd, .active_input, bytes[raw_start..i]);
                    }
                    _ = daemon_proto.sendMessage(daemon_fd, .detach, &.{});
                    return true;
                } else {
                    // Regular byte — will be flushed as raw_input
                    i += 1;
                    continue;
                }
            },

            .escape => {
                if (b == '[') {
                    // CSI sequence start
                    self.state = .csi;
                    self.csi_len = 0;
                    i += 1;
                    continue;
                }

                // ESC + byte = Alt+key
                const action = self.handleAltKey(b);
                self.state = .ground;
                i += 1;
                raw_start = i;
                if (action == .detach) {
                    _ = daemon_proto.sendMessage(daemon_fd, .detach, &.{});
                    return true;
                }
                if (action == .none) {
                    // Unknown Alt+key — forward ESC + key to daemon
                    const esc_key = [2]u8{ 0x1b, b };
                    _ = daemon_proto.sendMessage(daemon_fd, .active_input, &esc_key);
                } else {
                    self.dispatchAction(action, daemon_fd);
                }
                continue;
            },

            .csi => {
                if (b >= 0x40 and b <= 0x7E) {
                    // CSI final byte — sequence complete
                    const action = self.handleCsi(b);
                    self.state = .ground;
                    i += 1;
                    switch (action) {
                        .none => {
                            // Unhandled CSI: reconstruct and forward
                            var csi_fwd: [40]u8 = undefined;
                            csi_fwd[0] = 0x1b;
                            csi_fwd[1] = '[';
                            const plen = @min(self.csi_len, csi_fwd.len - 3);
                            @memcpy(csi_fwd[2..][0..plen], self.csi_buf[0..plen]);
                            csi_fwd[2 + plen] = b;
                            _ = daemon_proto.sendMessage(daemon_fd, .active_input, csi_fwd[0 .. 3 + plen]);
                        },
                        .mouse_click => |mc| {
                            // Store for caller to handle (needs layout rects)
                            self.last_mouse = .{ .col = mc.col, .row = mc.row, .button = mc.button, .release = mc.release };
                        },
                        else => self.dispatchAction(action, daemon_fd),
                    }
                    raw_start = i;
                    continue;
                } else if (self.csi_len < self.csi_buf.len) {
                    // CSI intermediate/parameter byte
                    self.csi_buf[self.csi_len] = b;
                    self.csi_len += 1;
                    i += 1;
                    continue;
                } else {
                    // CSI buffer overflow — discard sequence
                    self.state = .ground;
                    i += 1;
                    raw_start = i;
                    continue;
                }
            },
        }
    }

    // Flush remaining raw bytes
    if (i > raw_start) {
        _ = daemon_proto.sendMessage(daemon_fd, .active_input, bytes[raw_start..i]);
    }

    // Check for incomplete ESC (timeout handling)
    if (self.state == .escape) {
        const now = @as(i64, @intCast(@divFloor(compat.monotonicNow(), 1_000_000)));
        if (now - self.esc_timestamp > 50) {
            // Standalone ESC — forward it
            _ = daemon_proto.sendMessage(daemon_fd, .active_input, "\x1b");
            self.state = .ground;
        }
    }
    return false;
}

/// Check if we have an incomplete escape sequence that has timed out.
/// Call this from the poll loop when poll returns 0 (timeout).
pub fn checkTimeout(self: *Self, daemon_fd: std.posix.fd_t) void {
    if (self.state == .escape) {
        const now = @as(i64, @intCast(@divFloor(compat.monotonicNow(), 1_000_000)));
        if (now - self.esc_timestamp > 50) {
            _ = daemon_proto.sendMessage(daemon_fd, .active_input, "\x1b");
            self.state = .ground;
        }
    }
    // Prefix timeout
    if (self.prefix_active) {
        const now = @as(i64, @intCast(@divFloor(compat.monotonicNow(), 1_000_000)));
        if (now - self.prefix_timestamp > self.prefix_timeout_ms) {
            self.prefix_active = false;
        }
    }
}

/// Returns true if in nested mode (prefix-only bindings).
pub fn isNested(self: *const Self) bool {
    return self.nested;
}

/// Returns true if prefix key is active (waiting for command key).
pub fn isPrefixActive(self: *const Self) bool {
    return self.prefix_active;
}

fn handleAltKey(self: *Self, key: u8) Action {
    // When nested inside another teru, don't intercept Alt+key —
    // let it pass through to the outer teru. Use prefix instead.
    if (self.nested) return .none;

    return switch (key) {
        // Alt+J = focus next
        'j' => .{ .command = .focus_next },
        // Alt+K = focus prev
        'k' => .{ .command = .focus_prev },
        // Alt+1-9 = workspace 1-9
        '1' => .{ .workspace = 0 },
        '2' => .{ .workspace = 1 },
        '3' => .{ .workspace = 2 },
        '4' => .{ .workspace = 3 },
        '5' => .{ .workspace = 4 },
        '6' => .{ .workspace = 5 },
        '7' => .{ .workspace = 6 },
        '8' => .{ .workspace = 7 },
        '9' => .{ .workspace = 8 },
        '0' => .{ .workspace = 9 },
        // Alt+Enter = split vertical (Enter = 0x0D)
        0x0D => .{ .command = .split_vertical },
        // Alt+X = close pane
        'x' => .{ .command = .close_pane },
        // Alt+Space = cycle layout
        ' ' => .{ .command = .cycle_layout },
        // Alt+Z = zoom toggle
        'z' => .{ .command = .zoom_toggle },
        // Alt+D = detach
        'd' => .detach,
        // Alt+M = focus master
        'm' => .{ .command = .focus_master },
        // Alt+N = swap next (RAlt emulation)
        'n' => .{ .command = .swap_next },
        // Alt+P = swap prev (RAlt emulation)
        'p' => .{ .command = .swap_prev },
        // Unknown Alt+key — forward as ESC + key
        else => .none,
    };
}

/// Handle key after prefix (Ctrl+Space + key).
/// These map to the same commands as teru's windowed prefix mode.
fn handlePrefixKey(_: *Self, key: u8) Action {
    return switch (key) {
        // Pane management
        'c', '\\' => .{ .command = .split_vertical },
        '-' => .{ .command = .split_horizontal },
        'x' => .{ .command = .close_pane },
        // Navigation
        'n' => .{ .command = .focus_next },
        'p' => .{ .command = .focus_prev },
        'j' => .{ .command = .focus_next },
        'k' => .{ .command = .focus_prev },
        // Layout
        ' ' => .{ .command = .cycle_layout },
        'z' => .{ .command = .zoom_toggle },
        // Workspace (1-9, 0)
        '1' => .{ .workspace = 0 },
        '2' => .{ .workspace = 1 },
        '3' => .{ .workspace = 2 },
        '4' => .{ .workspace = 3 },
        '5' => .{ .workspace = 4 },
        '6' => .{ .workspace = 5 },
        '7' => .{ .workspace = 6 },
        '8' => .{ .workspace = 7 },
        '9' => .{ .workspace = 8 },
        '0' => .{ .workspace = 9 },
        // Swap
        'J' => .{ .command = .swap_next },
        'K' => .{ .command = .swap_prev },
        // Master
        'm' => .{ .command = .focus_master },
        'M' => .{ .command = .set_master },
        // Session
        'd' => .detach,
        else => .none,
    };
}

fn handleCsi(self: *Self, final: u8) Action {
    const params = self.csi_buf[0..self.csi_len];

    // SGR mouse: ESC[<btn;col;rowM (press) or ESC[<btn;col;rowm (release)
    if ((final == 'M' or final == 'm') and params.len > 0 and params[0] == '<') {
        return self.parseSgrMouse(params[1..], final == 'm');
    }

    return switch (final) {
        // Arrow keys, Home/End, PgUp/PgDn — forward to pane
        'A', 'B', 'C', 'D', 'H', 'F', '~' => .none,
        else => .none,
    };
}

/// Parse SGR mouse parameters: "btn;col;row" (all 1-indexed from terminal)
fn parseSgrMouse(_: *Self, params: []const u8, release: bool) Action {
    // Split by ';' to get btn, col, row
    var parts: [3]u16 = .{ 0, 0, 0 };
    var part_idx: usize = 0;
    var num: u16 = 0;

    for (params) |ch| {
        if (ch == ';') {
            if (part_idx < 3) parts[part_idx] = num;
            part_idx += 1;
            num = 0;
        } else if (ch >= '0' and ch <= '9') {
            num = num *| 10 +| (ch - '0');
        }
    }
    if (part_idx < 3) parts[part_idx] = num;

    const button = @as(u8, @intCast(@min(parts[0], 255)));
    // SGR coordinates are 1-indexed, convert to 0-indexed
    const col = if (parts[1] > 0) parts[1] - 1 else 0;
    const row = if (parts[2] > 0) parts[2] - 1 else 0;

    return .{ .mouse_click = .{ .col = col, .row = row, .button = button, .release = release } };
}

fn dispatchAction(_: *Self, action: Action, daemon_fd: std.posix.fd_t) void {
    switch (action) {
        .command => |cmd| {
            const cmd_byte = [1]u8{@intFromEnum(cmd)};
            _ = daemon_proto.sendMessage(daemon_fd, .command, &cmd_byte);
        },
        .workspace => |ws| {
            const payload = [2]u8{ @intFromEnum(daemon_proto.Command.switch_workspace), ws };
            _ = daemon_proto.sendMessage(daemon_fd, .command, &payload);
        },
        .mouse_click => {
            // Mouse clicks are handled by the main loop (needs layout rects)
            // Not dispatched here — the caller checks for .mouse_click
        },
        .detach => {
            _ = daemon_proto.sendMessage(daemon_fd, .detach, &.{});
        },
        .raw_input => |ri| {
            _ = daemon_proto.sendMessage(daemon_fd, .active_input, ri.data);
        },
        .none => {},
    }
}

// ── Tests ────────────────────────────────────────────────────────

test "TuiInput: init" {
    const input = init();
    try std.testing.expectEqual(State.ground, input.state);
}

test "TuiInput: handleAltKey mappings" {
    var input = init();
    try std.testing.expectEqual(Action{ .command = .focus_next }, input.handleAltKey('j'));
    try std.testing.expectEqual(Action{ .command = .focus_prev }, input.handleAltKey('k'));
    try std.testing.expectEqual(Action{ .workspace = 0 }, input.handleAltKey('1'));
    try std.testing.expectEqual(Action{ .workspace = 9 }, input.handleAltKey('0'));
    try std.testing.expectEqual(Action{ .command = .close_pane }, input.handleAltKey('x'));
    try std.testing.expectEqual(Action{ .command = .cycle_layout }, input.handleAltKey(' '));
    try std.testing.expectEqual(Action{ .command = .zoom_toggle }, input.handleAltKey('z'));
    try std.testing.expect(input.handleAltKey('d') == .detach);
    try std.testing.expect(input.handleAltKey('Q') == .none);
}

test "TuiInput: ESC enters escape state" {
    var input = init();

    // Create a socketpair for the daemon fd
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return;
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    // Feed ESC followed by 'j' (Alt+J = focus_next)
    _ = input.feed("\x1bj", fds[0]);

    // After processing Alt+J, should be back in ground state
    try std.testing.expectEqual(State.ground, input.state);

    // Should have sent a command message
    var hdr: daemon_proto.Header = undefined;
    var buf: [daemon_proto.max_payload]u8 = undefined;
    if (daemon_proto.recvMessage(fds[1], &hdr, &buf)) |payload| {
        try std.testing.expectEqual(daemon_proto.Tag.command, hdr.tag);
        try std.testing.expect(payload.len >= 1);
        try std.testing.expectEqual(@as(u8, @intFromEnum(daemon_proto.Command.focus_next)), payload[0]);
    }
}

test "TuiInput: regular bytes forwarded as active_input" {
    var input = init();

    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return;
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    _ = input.feed("hello", fds[0]);

    var hdr: daemon_proto.Header = undefined;
    var buf: [daemon_proto.max_payload]u8 = undefined;
    if (daemon_proto.recvMessage(fds[1], &hdr, &buf)) |payload| {
        try std.testing.expectEqual(daemon_proto.Tag.active_input, hdr.tag);
        try std.testing.expectEqualStrings("hello", payload);
    }
}

test "TuiInput: workspace switch" {
    var input = init();

    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return;
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    // Alt+3 = workspace 2 (0-indexed)
    _ = input.feed("\x1b3", fds[0]);

    var hdr: daemon_proto.Header = undefined;
    var buf: [daemon_proto.max_payload]u8 = undefined;
    if (daemon_proto.recvMessage(fds[1], &hdr, &buf)) |payload| {
        try std.testing.expectEqual(daemon_proto.Tag.command, hdr.tag);
        try std.testing.expect(payload.len >= 2);
        try std.testing.expectEqual(@as(u8, @intFromEnum(daemon_proto.Command.switch_workspace)), payload[0]);
        try std.testing.expectEqual(@as(u8, 2), payload[1]); // workspace index 2
    }
}

test "TuiInput: CSI sequence (arrow key) stays none" {
    var input = init();
    const action = input.handleCsi('A'); // Up arrow
    try std.testing.expect(action == .none);
}
