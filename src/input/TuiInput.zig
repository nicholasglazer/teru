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
const log = @import("../log.zig");
const LeaderKey = @import("../config/LeaderKey.zig");
const Keybinds = @import("../config/Keybinds.zig");
const MuxLeader = @import("MuxLeader.zig");

pub const Action = union(enum) {
    /// Raw bytes to forward to daemon as active_input
    raw_input: struct { data: []const u8 },
    /// Multiplexer command to send to daemon
    command: daemon_proto.Command,
    /// Workspace switch (command + workspace index)
    workspace: u8,
    /// Move the focused pane to a workspace (move_to_workspace + index)
    move_to_workspace: u8,
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
/// When nested inside another teru. Selects the Ctrl+A prefix (the outer owns
/// Ctrl+B) and suppresses the inner status bar. Does NOT suppress Alt handling —
/// a teru outer forwards Alt after the OSC 9998 handshake (see handleAltKey);
/// in a plain non-teru terminal with TERU_NESTED=1, Alt is consumed by the inner.
nested: bool = false,
/// In nested mode the inner teru drops its own status bar by default (the
/// outer teru owns one). But under teruwm — or any non-teru host — there IS
/// no outer bar, so the multiplexer ends up with no panel at all. Setting
/// `TERU_NESTED_BAR=1` keeps the inner bar visible even when nested.
nested_bar: bool = false,
/// Last mouse event (set by feed(), consumed by caller)
last_mouse: ?struct { col: u16, row: u16, button: u8, release: bool } = null,
/// Prefix key state.
prefix_active: bool = false,
prefix_timestamp: i64 = 0,
prefix_timeout_ms: i64 = 500,
/// The prefix key byte. Ctrl+B (0x02) normally; Ctrl+A (0x01) when NESTED so a
/// teru-inside-teru can be driven without colliding with the outer teru, which
/// owns Ctrl+B and Alt. The outer doesn't grab Ctrl+A, so it passes through to
/// the inner — making the inner's prefix reachable.
prefix_byte: u8 = 0x02,
/// Doom-style leader (Alt+Space → which-key). Pure engine; the tree is
/// MuxLeader.root_group (set in init). State is client-side — over SSH the
/// daemon only ever sees the FINAL command, never the navigation keys.
leader: LeaderKey = .{},
/// Set whenever leader state changes, so the caller re-renders the HUD. The
/// caller consumes it via consumeRenderDirty().
render_dirty: bool = false,

/// Per-byte input trace — writes raw to stderr (redirect with 2>tui-debug.log).
/// GATED behind `TERU_LOG=debug`: the attaching client's stderr is the user's
/// terminal, so an ungated write here interleaves with the TUI on fd 1 and
/// visibly corrupts the screen — most violently under SGR mouse mode, where the
/// terminal streams a motion sequence per mouse move. Off by default; a no-op
/// after one cached env read, so it stays free on the hot input path.
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (log.activeLevel() != .debug) return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
}

fn freshLeader() LeaderKey {
    var lk = LeaderKey{};
    lk.root = &MuxLeader.root_group;
    return lk;
}

pub fn init() Self {
    return .{ .leader = freshLeader() };
}

/// Create a TuiInput that detects nesting automatically.
/// Nested = running inside another teru (or TERU_NESTED=1). When nested the
/// prefix becomes Ctrl+A (the outer owns Ctrl+B) and the inner drops its own
/// status bar. Alt is STILL handled when it reaches this process: a teru outer
/// forwards Alt+key after the OSC 9998 handshake; a non-teru terminal passes
/// ESC+key straight through, so Alt is consumed by the inner (use the Ctrl+A
/// prefix for any shell-bound Alt keys in that case).
///
/// Detection: `TERM_PROGRAM=teru` (set in a local teru's pane env) OR
/// `TERU_NESTED=1`. The env-var fallback exists because TERM_PROGRAM is NOT
/// forwarded across SSH, so the over-SSH nested case (local teru → ssh → remote
/// teru) needs an explicit signal: run the remote as `TERU_NESTED=1 teru -n …`.
pub fn initAutoDetect() Self {
    const term_is_teru = if (compat.getenv("TERM_PROGRAM")) |tp|
        std.mem.eql(u8, std.mem.sliceTo(tp, 0), "teru")
    else
        false;
    const nested = term_is_teru or (compat.getenv("TERU_NESTED") != null);
    // Keep the inner status bar visible when nested under a non-teru host
    // (teruwm, plain terminal) — opt-in, since teru-in-teru wants it dropped.
    const nested_bar = compat.getenv("TERU_NESTED_BAR") != null;
    // Nested: use Ctrl+A as the prefix (the outer teru owns Ctrl+B + Alt and
    // grabs them first; it does NOT grab Ctrl+A, so it forwards it to the inner).
    return .{ .nested = nested, .nested_bar = nested_bar, .prefix_byte = if (nested) 0x01 else 0x02, .leader = freshLeader() };
}

/// Process a chunk of raw input bytes.
/// Returns true if a detach was requested (caller should exit TUI mode).
pub fn feed(self: *Self, bytes: []const u8, daemon_fd: std.posix.fd_t) bool {
    debugLog("feed: {d} bytes:", .{bytes.len});
    for (bytes) |b| debugLog(" {x:0>2}", .{b});
    debugLog("\n", .{});

    var raw_start: usize = 0;
    var i: usize = 0;

    while (i < bytes.len) {
        const b = bytes[i];

        // Leader mode swallows every byte: navigate the which-key tree
        // client-side (no daemon round-trips), dispatching only the final
        // action. Esc / any unbound key dismisses. Runs before the state
        // machine so it captures everything while active.
        if (self.leader.active) {
            if (i > raw_start) {
                _ = daemon_proto.sendMessage(daemon_fd, .active_input, bytes[raw_start..i]);
            }
            const res = self.leader.feedKey(b, false);
            self.render_dirty = true;
            i += 1;
            raw_start = i;
            switch (res) {
                .redraw => {},
                .dismiss => self.leader.deactivate(),
                .run => |a| {
                    self.leader.deactivate();
                    const la = actionToTui(a);
                    if (la == .detach) {
                        _ = daemon_proto.sendMessage(daemon_fd, .detach, &.{});
                        return true;
                    }
                    if (la != .none) self.dispatchAction(la, daemon_fd);
                },
            }
            continue;
        }

        switch (self.state) {
            .ground => {
                // Prefix key (Ctrl+B normally, Ctrl+A when nested — see prefix_byte).
                if (b == self.prefix_byte) {
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

                // Alt+Space opens the leader / which-key (unless a prefix is
                // mid-flight). Supersedes the old Alt+Space=cycle_layout, which
                // is now reachable as leader SPC.
                if (b == ' ' and !self.prefix_active) {
                    self.leader.activate();
                    self.render_dirty = true;
                    self.state = .ground;
                    i += 1;
                    raw_start = i;
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
                            // Store for the caller to handle (it needs layout rects).
                            // Record PRESS events only: a press+release pair can arrive
                            // in ONE feed() (a fast click, or byte-batching over SSH), and
                            // because last_mouse is a single slot the release would clobber
                            // the press before the caller reads it — losing the click
                            // (focus never moved). Releases drive nothing in the TUI client
                            // today (focus happens on press), so drop them here.
                            if (!mc.release) {
                                self.last_mouse = .{ .col = mc.col, .row = mc.row, .button = mc.button, .release = mc.release };
                            }
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

/// How many milliseconds (max) the poll loop should wait before calling
/// `checkTimeout`. Returns -1 when no timer is pending (block forever).
/// Lets callers replace fixed-cadence polling with a deadline-driven poll.
pub fn nextTimeoutMs(self: *const Self) i32 {
    var min_remaining: i64 = -1;
    const now_ms = @as(i64, @intCast(@divFloor(compat.monotonicNow(), 1_000_000)));
    if (self.state == .escape) {
        const r = 50 - (now_ms - self.esc_timestamp);
        if (r <= 0) return 0;
        if (min_remaining < 0 or r < min_remaining) min_remaining = r;
    }
    if (self.prefix_active) {
        const r = @as(i64, @intCast(self.prefix_timeout_ms)) - (now_ms - self.prefix_timestamp);
        if (r <= 0) return 0;
        if (min_remaining < 0 or r < min_remaining) min_remaining = r;
    }
    if (min_remaining < 0) return -1;
    if (min_remaining > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(min_remaining);
}

/// Returns true if in nested mode (prefix-only bindings).
pub fn isNested(self: *const Self) bool {
    return self.nested;
}

/// Returns true if prefix key is active (waiting for command key).
pub fn isPrefixActive(self: *const Self) bool {
    return self.prefix_active;
}

/// Returns true if the status bar should be drawn even while nested
/// (`TERU_NESTED_BAR=1`). Use with `isNested()` to decide bar visibility.
pub fn isNestedBar(self: *const Self) bool {
    return self.nested_bar;
}

fn handleAltKey(_: *Self, key: u8) Action {
    // Note: when nested, the outer teru only delivers Alt+key to us if it has
    // chosen to FORWARD it (OSC 9998 handshake). If it forwards, we act on it
    // (drive the remote with the same Alt shortcuts as the local teru); if it
    // doesn't, we never see Alt here. So we handle Alt the same whether nested or
    // not — there's no longer a reason to short-circuit on `nested`.
    return switch (key) {
        // Alt+J = focus next
        'j' => .{ .command = .focus_next },
        // Alt+K = focus prev
        'k' => .{ .command = .focus_prev },
        // Alt+H / Alt+L = shrink / grow master (must be intercepted — otherwise
        // they leak into the pane as ESC+h / ESC+l = readline kill-word/downcase).
        'h' => .{ .command = .resize_shrink },
        'l' => .{ .command = .resize_grow },
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
        // Alt+N / Alt+P = swap next / prev (RAlt emulation)
        'n' => .{ .command = .swap_next },
        'p' => .{ .command = .swap_prev },
        // Alt+Shift+J / Alt+Shift+K = swap next / prev (xmonad Mod+Shift+j/k).
        // Shift makes xkb deliver the uppercase letter, so we match on it here.
        'J' => .{ .command = .swap_next },
        'K' => .{ .command = .swap_prev },
        // Alt+Shift+M = swap focused <-> master (xmonad Mod+Shift+m)
        'M' => .{ .command = .swap_master },
        // Alt+, / Alt+. = IncMasterN -/+ (xmonad Mod+,/.)
        ',' => .{ .command = .master_count_inc },
        '.' => .{ .command = .master_count_dec },
        // Alt+Shift+1..0 = move focused pane to workspace 1..10 (xmonad
        // Mod+Shift+N). On a US layout Shift+digit is the symbol above it.
        '!' => .{ .move_to_workspace = 0 },
        '@' => .{ .move_to_workspace = 1 },
        '#' => .{ .move_to_workspace = 2 },
        '$' => .{ .move_to_workspace = 3 },
        '%' => .{ .move_to_workspace = 4 },
        '^' => .{ .move_to_workspace = 5 },
        '&' => .{ .move_to_workspace = 6 },
        '*' => .{ .move_to_workspace = 7 },
        '(' => .{ .move_to_workspace = 8 },
        ')' => .{ .move_to_workspace = 9 },
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
        'M' => .{ .command = .swap_master },
        // IncMasterN (panes in the master area)
        ',' => .{ .command = .master_count_inc },
        '.' => .{ .command = .master_count_dec },
        // Rotate the non-master region; focus stays put
        'o' => .{ .command = .rotate_slaves_down },
        'O' => .{ .command = .rotate_slaves_up },
        // Reset the workspace to the default tiling
        'r' => .{ .command = .reset_layout },
        // Session
        'd' => .detach,
        else => .none,
    };
}

fn handleCsi(self: *Self, final: u8) Action {
    const params = self.csi_buf[0..self.csi_len];

    debugLog("CSI final=0x{x:0>2} params_len={d} params:", .{ final, self.csi_len });
    for (params) |p| debugLog(" {x:0>2}", .{p});
    debugLog("\n", .{});

    // SGR mouse: ESC[<btn;col;rowM (press) or ESC[<btn;col;rowm (release)
    if ((final == 'M' or final == 'm') and params.len > 0 and params[0] == '<') {
        debugLog("SGR mouse detected!\n", .{});
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
        .move_to_workspace => |ws| {
            const payload = [2]u8{ @intFromEnum(daemon_proto.Command.move_to_workspace), ws };
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

/// Map a canonical `Keybinds.Action` (what the shared leader tree targets) to a
/// TUI client Action (a daemon command / workspace / detach). This is the
/// per-binary execution layer: the leader speaks the shared vocabulary, the TUI
/// client translates to `daemon_proto.Command`. Actions the TUI can't dispatch
/// map to `.none` (no-op).
fn actionToTui(a: Keybinds.Action) Action {
    if (a.workspaceIndex()) |idx| return .{ .workspace = idx };
    if (a.moveToIndex()) |idx| return .{ .move_to_workspace = idx };
    return switch (a) {
        .session_detach => .detach,
        .pane_focus_next => .{ .command = .focus_next },
        .pane_focus_prev => .{ .command = .focus_prev },
        .pane_focus_master => .{ .command = .focus_master },
        .pane_set_master => .{ .command = .set_master },
        .pane_swap_next => .{ .command = .swap_next },
        .pane_swap_prev => .{ .command = .swap_prev },
        .pane_swap_master => .{ .command = .swap_master },
        .pane_rotate_slaves_up => .{ .command = .rotate_slaves_up },
        .pane_rotate_slaves_down => .{ .command = .rotate_slaves_down },
        .master_count_inc => .{ .command = .master_count_inc },
        .master_count_dec => .{ .command = .master_count_dec },
        .layout_cycle => .{ .command = .cycle_layout },
        .layout_reset => .{ .command = .reset_layout },
        .zoom_toggle => .{ .command = .zoom_toggle },
        .resize_shrink_w => .{ .command = .resize_shrink },
        .resize_grow_w => .{ .command = .resize_grow },
        .pane_close, .window_close => .{ .command = .close_pane },
        .split_vertical => .{ .command = .split_vertical },
        .split_horizontal => .{ .command = .split_horizontal },
        else => .none,
    };
}

/// Whether the leader/which-key overlay is open (caller draws the HUD band).
pub fn leaderActive(self: *const Self) bool {
    return self.leader.active;
}

/// Consume the "leader state changed, please re-render" flag.
pub fn consumeRenderDirty(self: *Self) bool {
    const d = self.render_dirty;
    self.render_dirty = false;
    return d;
}

test "TuiInput: Alt+Space opens leader; root 'd' detaches; descend dispatches" {
    var fds: [2]std.posix.fd_t = undefined;
    _ = std.c.pipe(@ptrCast(&fds));
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var input = init();
    try std.testing.expect(!input.leaderActive());
    // Alt+Space = ESC + ' '
    _ = input.feed("\x1b ", fds[1]);
    try std.testing.expect(input.leaderActive());
    try std.testing.expect(input.consumeRenderDirty());
    // 'd' at root = detach → feed returns true
    const detached = input.feed("d", fds[1]);
    try std.testing.expect(detached);
    try std.testing.expect(!input.leaderActive());
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

test "TuiInput: nested input still handles Alt (outer forwards it via OSC 9998)" {
    // When nested, the outer teru forwards Alt+key to us as ESC+key only if it
    // chose to; if it forwards, we must ACT on it (not pass it back to the pane).
    var input = Self{ .nested = true, .prefix_byte = 0x01 };
    try std.testing.expectEqual(Action{ .command = .focus_next }, input.handleAltKey('j'));
    try std.testing.expectEqual(Action{ .workspace = 2 }, input.handleAltKey('3'));
    try std.testing.expectEqual(Action{ .command = .cycle_layout }, input.handleAltKey(' '));
}

test "TuiInput: batched mouse press+release in one feed keeps the press" {
    // Regression: a left click delivered as press THEN release in a single feed()
    // (fast click / SSH byte-batching) must still surface a PRESS to the caller —
    // the release must not clobber the press in the single last_mouse slot, or the
    // click is silently lost and focus never moves.
    var input = init();
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return;
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    // ESC[<0;50;20M  (press)  immediately followed by  ESC[<0;50;20m  (release)
    _ = input.feed("\x1b[<0;50;20M\x1b[<0;50;20m", fds[0]);

    try std.testing.expect(input.last_mouse != null);
    try std.testing.expect(!input.last_mouse.?.release); // it's the PRESS, not the release
    try std.testing.expectEqual(@as(u16, 49), input.last_mouse.?.col); // 50 → 0-indexed 49
    try std.testing.expectEqual(@as(u16, 19), input.last_mouse.?.row);
    try std.testing.expectEqual(@as(u8, 0), input.last_mouse.?.button);
}
