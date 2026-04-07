const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const compat = @import("../compat.zig");
const Pty = @import("../pty/pty.zig").Pty;
const Grid = @import("Grid.zig");
const VtParser = @import("VtParser.zig");
const Scrollback = @import("../persist/Scrollback.zig");

/// A Pane bundles a PTY + Grid + VtParser + Scrollback into a single manageable unit.
/// Each pane is an independent terminal session with its own shell process.
const Pane = @This();

pub const SpawnConfig = struct {
    shell: ?[]const u8 = null,
    scrollback_lines: u32 = 10000,
    term: ?[]const u8 = null,
    tab_width: u8 = 8,
    cursor_shape: Grid.CursorShape = .block,
};

pty: Pty,
grid: Grid,
vt: VtParser,
id: u64,
scrollback: Scrollback,
scroll_offset: u32 = 0,
scroll_pixel: i32 = 0, // sub-cell pixel offset for smooth scrolling (0..cell_height-1)

pub fn init(allocator: Allocator, rows: u16, cols: u16, id: u64, spawn_config: SpawnConfig) !Pane {
    var grid = try Grid.init(allocator, rows, cols);
    errdefer grid.deinit(allocator);
    grid.tab_width = spawn_config.tab_width;
    grid.cursor_shape = spawn_config.cursor_shape;

    var sb = Scrollback.init(allocator, .{
        .keyframe_interval = 100,
        .max_lines = spawn_config.scrollback_lines,
    });
    grid.scrollback = &sb; // will be re-linked in linkVt after move

    var pty = try Pty.spawn(.{
        .rows = rows,
        .cols = cols,
        .shell = spawn_config.shell,
        .term = spawn_config.term,
    });
    errdefer pty.deinit();

    // Set PTY master to non-blocking for event-loop polling
    // (Windows ConPTY uses PeekNamedPipe instead — no fcntl needed)
    if (builtin.os.tag != .windows) {
        const flags = std.c.fcntl(pty.master, posix.F.GETFL);
        if (flags < 0) return error.FcntlFailed;
        _ = std.c.fcntl(pty.master, posix.F.SETFL, flags | compat.O_NONBLOCK);
    }

    // VtParser needs a *Grid pointer. Since Pane will be moved by
    // ArrayList.append, we set grid to undefined here. Caller MUST
    // call linkVt() after the Pane is in its final memory location.
    return .{
        .pty = pty,
        .grid = grid,
        .vt = VtParser.initEmpty(),
        .id = id,
        .scrollback = sb,
    };
}

/// Patch the VtParser's grid pointer and allocator to this Pane's grid.
/// MUST be called after the Pane is in its final memory location
/// (after ArrayList.append or similar move).
pub fn linkVt(self: *Pane, allocator: Allocator) void {
    self.vt.grid = &self.grid;
    self.vt.allocator = allocator;
    self.vt.response_fd = self.pty.master;
    // Re-link scrollback pointer after Pane was moved by ArrayList
    self.grid.scrollback = &self.scrollback;
}

pub fn deinit(self: *Pane, allocator: Allocator) void {
    self.pty.deinit();
    self.grid.scrollback = null; // detach before freeing
    self.scrollback.deinit();
    self.grid.deinit(allocator);
}

/// Read available data from the PTY and feed it through the VT parser.
/// Returns the number of bytes read (0 if nothing available).
pub fn readAndProcess(self: *Pane, buf: []u8) !usize {
    const n = self.pty.read(buf) catch |err| switch (err) {
        error.WouldBlock => return 0,
        else => return err,
    };
    if (n > 0) {
        self.vt.feed(buf[0..n]);
        self.grid.dirty = true;
    }
    return n;
}

/// Resize this pane's grid and PTY to new dimensions.
pub fn resize(self: *Pane, allocator: Allocator, rows: u16, cols: u16) !void {
    try self.grid.resize(allocator, rows, cols);
    self.pty.resize(rows, cols);
}

/// Check if the pane's shell process is still alive.
pub fn isAlive(self: *const Pane) bool {
    return self.pty.isAlive();
}

// ── Tests ────────────────────────────────────────────────────────

test "Pane init and deinit" {
    // This test spawns a real PTY, so it verifies the full integration.
    const allocator = std.testing.allocator;

    var pane = try Pane.init(allocator, 24, 80, 1, .{});
    defer pane.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), pane.id);
    try std.testing.expectEqual(@as(u16, 24), pane.grid.rows);
    try std.testing.expectEqual(@as(u16, 80), pane.grid.cols);
    try std.testing.expect(pane.pty.master >= 0);
    try std.testing.expect(pane.pty.child_pid != null);
}

test "Pane readAndProcess returns 0 on empty" {
    const allocator = std.testing.allocator;

    var pane = try Pane.init(allocator, 24, 80, 42, .{});
    defer pane.deinit(allocator);

    // Immediately after spawn, there may or may not be data.
    // The important thing is it doesn't error.
    var buf: [4096]u8 = undefined;
    _ = try pane.readAndProcess(&buf);
}

test "Pane resize" {
    const allocator = std.testing.allocator;

    var pane = try Pane.init(allocator, 24, 80, 7, .{});
    defer pane.deinit(allocator);

    try pane.resize(allocator, 40, 120);
    try std.testing.expectEqual(@as(u16, 40), pane.grid.rows);
    try std.testing.expectEqual(@as(u16, 120), pane.grid.cols);
}
