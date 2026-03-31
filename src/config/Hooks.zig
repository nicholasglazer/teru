//! Plugin hook system for teru.
//!
//! Lightweight hook mechanism that executes external commands on terminal
//! events. Hooks are defined in teru.conf as key=value pairs:
//!
//!   hook_on_spawn = notify-send "teru" "New pane spawned"
//!   hook_on_close = ~/.config/teru/hooks/on-close.sh
//!
//! Each hook fires asynchronously (fork+exec, fire-and-forget). The parent
//! process does not wait for the child, so hooks cannot block the terminal.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const compat = @import("../compat.zig");
const Hooks = @This();

// ── Hook events ───────────────────────────────────────────────────

pub const HookEvent = enum {
    spawn,
    close,
    agent_start,
    session_save,
};

// ── Fields ────────────────────────────────────────────────────────

on_spawn: ?[:0]const u8 = null,
on_close: ?[:0]const u8 = null,
on_agent_start: ?[:0]const u8 = null,
on_session_save: ?[:0]const u8 = null,
allocator: Allocator,

// ── Public API ────────────────────────────────────────────────────

pub fn init(allocator: Allocator) Hooks {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Hooks) void {
    if (self.on_spawn) |s| self.allocator.free(s);
    if (self.on_close) |s| self.allocator.free(s);
    if (self.on_agent_start) |s| self.allocator.free(s);
    if (self.on_session_save) |s| self.allocator.free(s);
    self.on_spawn = null;
    self.on_close = null;
    self.on_agent_start = null;
    self.on_session_save = null;
}

/// Set a hook command from a config value (allocates a sentinel-terminated copy).
pub fn setHook(self: *Hooks, event: HookEvent, value: []const u8) void {
    const field = self.fieldPtr(event);
    // Free any previous value
    if (field.*) |prev| self.allocator.free(prev);
    field.* = self.allocator.dupeZ(u8, value) catch null;
}

/// Execute a hook command asynchronously (fork+exec, don't wait).
/// If the hook is null, this is a no-op.
pub fn fire(self: *const Hooks, hook: HookEvent) void {
    const cmd = switch (hook) {
        .spawn => self.on_spawn,
        .close => self.on_close,
        .agent_start => self.on_agent_start,
        .session_save => self.on_session_save,
    } orelse return;

    const argv = [_:null]?[*:0]const u8{
        "/bin/sh",
        "-c",
        cmd,
    };
    compat.forkExec(&argv);
}

// ── Internal ──────────────────────────────────────────────────────

fn fieldPtr(self: *Hooks, event: HookEvent) *?[:0]const u8 {
    return switch (event) {
        .spawn => &self.on_spawn,
        .close => &self.on_close,
        .agent_start => &self.on_agent_start,
        .session_save => &self.on_session_save,
    };
}

// ── Tests ─────────────────────────────────────────────────────────

test "init returns null hooks" {
    const allocator = std.testing.allocator;
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();

    try std.testing.expectEqual(@as(?[:0]const u8, null), hooks.on_spawn);
    try std.testing.expectEqual(@as(?[:0]const u8, null), hooks.on_close);
    try std.testing.expectEqual(@as(?[:0]const u8, null), hooks.on_agent_start);
    try std.testing.expectEqual(@as(?[:0]const u8, null), hooks.on_session_save);
}

test "setHook stores command" {
    const allocator = std.testing.allocator;
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();

    hooks.setHook(.spawn, "echo spawned");
    try std.testing.expect(hooks.on_spawn != null);
    try std.testing.expectEqualStrings("echo spawned", hooks.on_spawn.?);
}

test "setHook overwrites previous value" {
    const allocator = std.testing.allocator;
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();

    hooks.setHook(.close, "echo first");
    hooks.setHook(.close, "echo second");
    try std.testing.expectEqualStrings("echo second", hooks.on_close.?);
}

test "fire with null hook is no-op" {
    const allocator = std.testing.allocator;
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();

    // Should not crash or hang — all hooks are null
    hooks.fire(.spawn);
    hooks.fire(.close);
    hooks.fire(.agent_start);
    hooks.fire(.session_save);
}

test "deinit frees allocated hooks" {
    const allocator = std.testing.allocator;
    var hooks = Hooks.init(allocator);

    hooks.setHook(.spawn, "echo spawn");
    hooks.setHook(.close, "echo close");
    hooks.setHook(.agent_start, "echo agent");
    hooks.setHook(.session_save, "echo save");

    hooks.deinit();

    try std.testing.expectEqual(@as(?[:0]const u8, null), hooks.on_spawn);
    try std.testing.expectEqual(@as(?[:0]const u8, null), hooks.on_close);
    try std.testing.expectEqual(@as(?[:0]const u8, null), hooks.on_agent_start);
    try std.testing.expectEqual(@as(?[:0]const u8, null), hooks.on_session_save);
}

test "fire executes command asynchronously" {
    const allocator = std.testing.allocator;
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();

    // Use 'true' — a shell built-in that exits 0 immediately
    hooks.setHook(.spawn, "true");
    hooks.fire(.spawn);

    // Brief wait for the forked child to run. Cannot use io.sleep() here
    // because the fire() call forks a child process — the parent's io
    // handle is not valid across fork boundaries. nanosleep is correct
    // for this test-only wait.
    const req = std.os.linux.timespec{ .sec = 0, .nsec = 10_000_000 }; // 10ms
    _ = std.os.linux.nanosleep(&req, null);
}
