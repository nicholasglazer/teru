const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const compat = @import("../compat.zig");
const pty_mod = @import("../pty/pty.zig");
const Pty = pty_mod.Pty;
const RemotePty = pty_mod.RemotePty;
const Grid = @import("Grid.zig");
const VtParser = @import("VtParser.zig");
const Scrollback = @import("../persist/Scrollback.zig");
const proto = @import("../server/protocol.zig");

/// A Pane bundles a PTY backend + Grid + VtParser + Scrollback into a single unit.
/// The backend is either a local PTY (owns the process) or a remote PTY (daemon IPC).
const Pane = @This();

pub const SpawnConfig = struct {
    shell: ?[]const u8 = null,
    scrollback_lines: u32 = 10000,
    term: ?[]const u8 = null,
    tab_width: u8 = 8,
    cursor_shape: Grid.CursorShape = .block,
    /// Pre-built argv for -e exec (first pane only, then cleared).
    exec_argv: ?[*:null]const ?[*:0]const u8 = null,
};

/// PTY backend: local process or daemon IPC stream.
pub const Backend = union(enum) {
    local: Pty,
    remote: RemotePty,
};

backend: Backend,
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
        .exec_argv = spawn_config.exec_argv,
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
        .backend = .{ .local = pty },
        .grid = grid,
        .vt = VtParser.initEmpty(),
        .id = id,
        .scrollback = sb,
    };
}

/// Create a pane backed by a daemon IPC stream (no local PTY).
pub fn initRemote(allocator: Allocator, rows: u16, cols: u16, id: u64, ipc_fd: posix.fd_t, spawn_config: SpawnConfig) !Pane {
    var grid = try Grid.init(allocator, rows, cols);
    errdefer grid.deinit(allocator);
    grid.tab_width = spawn_config.tab_width;
    grid.cursor_shape = spawn_config.cursor_shape;

    var sb = Scrollback.init(allocator, .{
        .keyframe_interval = 100,
        .max_lines = spawn_config.scrollback_lines,
    });
    grid.scrollback = &sb;

    return .{
        .backend = .{ .remote = .{ .ipc_fd = ipc_fd, .pane_id = id } },
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
    switch (self.backend) {
        .local => |*p| {
            self.vt.response_fd = p.master;
            self.vt.response_fn = null;
        },
        .remote => {
            self.vt.response_fd = -1;
            self.vt.response_fn = remoteResponse;
            self.vt.response_ctx = @ptrCast(self);
        },
    }
    self.grid.scrollback = &self.scrollback;
}

/// VtParser response callback for remote panes: send DA1/DSR responses through IPC.
fn remoteResponse(data: []const u8, ctx: ?*anyopaque) void {
    const pane: *Pane = @ptrCast(@alignCast(ctx orelse return));
    _ = pane.ptyWrite(data) catch {};
}

pub fn deinit(self: *Pane, allocator: Allocator) void {
    switch (self.backend) {
        .local => |*p| p.deinit(),
        .remote => |*r| r.deinit(),
    }
    self.grid.scrollback = null;
    self.scrollback.deinit();
    self.grid.deinit(allocator);
}

/// Kill the current shell process and spawn a fresh one in the same pane.
/// Resets the grid and VT parser. Used for immortal panes that cannot be closed.
pub fn respawnShell(self: *Pane, allocator: Allocator, spawn_config: SpawnConfig) void {
    const rows = self.grid.rows;
    const cols = self.grid.cols;

    // Kill existing PTY
    switch (self.backend) {
        .local => |*p| p.deinit(),
        .remote => return, // remote panes can't respawn locally
    }

    // Reset grid (clear all cells, cursor to 0,0)
    self.grid.clearScreen(2); // mode 2 = clear entire screen
    self.grid.cursor_row = 0;
    self.grid.cursor_col = 0;
    self.vt = VtParser.initEmpty();
    self.scroll_offset = 0;
    self.scroll_pixel = 0;

    // Spawn new PTY
    const pty = Pty.spawn(.{
        .rows = rows,
        .cols = cols,
        .shell = spawn_config.shell,
        .term = spawn_config.term,
        .exec_argv = null, // never carry over exec_argv on respawn
    }) catch return; // silently fail — better than crashing the compositor

    // Set non-blocking
    if (builtin.os.tag != .windows) {
        const flags = std.c.fcntl(pty.master, posix.F.GETFL);
        if (flags >= 0) {
            _ = std.c.fcntl(pty.master, posix.F.SETFL, flags | compat.O_NONBLOCK);
        }
    }

    self.backend = .{ .local = pty };
    self.linkVt(allocator);
    self.grid.dirty = true;
}

/// Read available data from the PTY and feed it through the VT parser.
/// Returns the number of bytes read (0 if nothing available).
pub fn readAndProcess(self: *Pane, buf: []u8) !usize {
    const n = self.ptyRead(buf) catch |err| switch (err) {
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
    self.ptyResize(rows, cols);
}

/// Check if the pane's shell process is still alive.
pub fn isAlive(self: *const Pane) bool {
    return self.ptyIsAlive();
}

// ── Unified PTY accessors ────────────────────────────────────────

pub fn ptyRead(self: *Pane, buf: []u8) !usize {
    return switch (self.backend) {
        .local => |*p| p.read(buf),
        .remote => |*r| r.read(buf),
    };
}

pub fn ptyWrite(self: *const Pane, data: []const u8) !usize {
    return switch (self.backend) {
        .local => |p| p.write(data),
        .remote => |r| r.write(data),
    };
}

pub fn ptyResize(self: *Pane, rows: u16, cols: u16) void {
    switch (self.backend) {
        .local => |*p| p.resize(rows, cols),
        .remote => |*r| r.resize(rows, cols),
    }
}

pub fn ptyIsAlive(self: *const Pane) bool {
    return switch (self.backend) {
        .local => |p| p.isAlive(),
        .remote => |r| r.isAlive(),
    };
}

pub fn ptyMasterFd(self: *const Pane) posix.fd_t {
    return switch (self.backend) {
        .local => |p| p.master,
        .remote => |r| r.ipc_fd,
    };
}

pub fn childPid(self: *const Pane) ?i32 {
    return switch (self.backend) {
        .local => |p| p.child_pid,
        .remote => null,
    };
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
    try std.testing.expect(pane.backend.local.master >= 0);
    try std.testing.expect(pane.backend.local.child_pid != null);
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
