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
    /// Working directory for the spawned child. Null = inherit parent cwd.
    /// Used by session restore and `[workspace.N] cwd = …` to resume each
    /// pane where it left off.
    cwd: ?[]const u8 = null,
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

/// Shared scroll math — single source of truth for both TUI and compositor paths.
/// Positive pixel_delta moves toward older scrollback (increases offset).
/// Returns true if scroll state changed (caller must mark dirty + render).
pub fn scrollBy(self: *Pane, pixel_delta: i32, cell_height: u32, max_offset: u32) bool {
    const ch: i32 = @intCast(cell_height);
    var new_pixel = self.scroll_pixel + pixel_delta;
    var new_offset: i32 = @intCast(@min(self.scroll_offset, @as(u32, std.math.maxInt(i32))));
    const max_offset_i32: i32 = @intCast(@min(max_offset, @as(u32, std.math.maxInt(i32))));

    while (new_pixel >= ch) {
        new_pixel -= ch;
        new_offset += 1;
    }
    while (new_pixel < 0) {
        new_pixel += ch;
        new_offset -= 1;
    }

    if (new_offset < 0) {
        new_offset = 0;
        new_pixel = 0;
    }
    if (new_offset > max_offset_i32) {
        new_offset = max_offset_i32;
        new_pixel = 0;
    }

    const changed = new_offset != @as(i32, @intCast(self.scroll_offset)) or new_pixel != self.scroll_pixel;
    self.scroll_offset = @intCast(new_offset);
    self.scroll_pixel = new_pixel;
    return changed;
}

/// Map a pointer axis (scroll) event to a scrollback pixel delta for `scrollBy`.
/// Pure — no `self`, so it's unit-testable without a live PTY/compositor.
///
/// `discrete` is the wl_pointer high-resolution wheel step (1/120ths of a
/// notch; 0 for touchpad / continuous scroll). A notched wheel moves a fixed
/// `wheel_lines` per notch — crisp and predictable. A touchpad tracks the
/// finger proportionally via the continuous `delta` (× `factor`). The old
/// compositor path applied a fixed 3 lines PER libinput event, and a touchpad
/// fires dozens of events per gesture — that's the runaway "too sensitive"
/// scroll. `sign` (+1/-1) carries the natural/invert convention the caller
/// resolves from config. Returns pixels (sign = intended scrollback direction);
/// 0 means "no scroll".
pub fn axisScrollPixels(
    delta: f64,
    discrete: i32,
    cell_height: u32,
    sign: i32,
    wheel_lines: u32,
    factor: f32,
) i32 {
    if (delta == 0) return 0;
    const ch: i32 = @intCast(@max(@as(u32, 1), cell_height));
    if (discrete != 0) {
        // Notched wheel: N notches × wheel_lines. delta_discrete shares the
        // sign of delta; the v8 hi-res unit is 1/120th of a notch.
        const notches: i32 = @divTrunc(discrete, 120);
        const n: i32 = if (notches != 0) notches else (if (delta > 0) @as(i32, 1) else -1);
        return sign * n * @as(i32, @intCast(@max(@as(u32, 1), wheel_lines))) * ch;
    }
    // Touchpad / continuous: proportional to finger travel (1:1 × factor).
    const scaled: f64 = delta * @as(f64, factor);
    var px: i32 = @intFromFloat(@round(scaled));
    if (px == 0) px = if (delta > 0) 1 else -1; // never swallow a tiny flick
    return sign * px;
}

/// Touchpad / continuous scroll step with FRACTIONAL accumulation. Adds the
/// scaled delta to `frac` (a per-pane carry), returns the whole-pixel amount to
/// scroll now, and leaves the sub-pixel remainder in `frac` for next time.
///
/// Why not just round each event (axisScrollPixels): rounding a tiny delta to a
/// ±1px floor turns a touchpad's near-rest SENSOR NOISE (tiny alternating-sign
/// deltas) into a 1-2px back-and-forth JITTER, which looks awful during slow
/// scrolling. Accumulating instead: noise cancels (alternating deltas sum to
/// ~0, `frac` stays put, returns 0), while a genuine slow drag accumulates to
/// 1px over a few events — smooth, no floor. `sign` carries natural/invert.
pub fn fractionalScrollStep(frac: *f64, delta: f64, factor: f32, sign: i32) i32 {
    frac.* += delta * @as(f64, factor);
    const whole = @trunc(frac.*);
    frac.* -= whole;
    return sign * @as(i32, @intFromFloat(whole));
}

/// Drag-select auto-scroll decision. `ly` is the pane-local content Y in
/// pixels (0 = top content row); `content_h` is the visible content height in
/// pixels. Returns how a held drag that has run past an edge should auto-scroll:
///   dir = +1 → cursor above the top   → scroll into older history
///   dir = -1 → cursor below the bottom → scroll toward the live tail
///   dir =  0 → cursor inside viewport  → normal motion handling owns it
/// `steps` (lines/frame) grows gently with how far past the edge the cursor is
/// (1 at the edge … 6 when dragged far past), so a parked cursor keeps moving.
pub fn dragEdgeScroll(ly: i32, content_h: i32, cell_height: u32) struct { dir: i32, steps: i32 } {
    const ch: i32 = @intCast(@max(@as(u32, 1), cell_height));
    if (ly < 0) return .{ .dir = 1, .steps = 1 + @min(@divTrunc(-ly, ch), 5) };
    if (ly >= content_h) return .{ .dir = -1, .steps = 1 + @min(@divTrunc(ly - content_h, ch), 5) };
    return .{ .dir = 0, .steps = 0 };
}

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
        .cwd = spawn_config.cwd,
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

/// Create a pane by attaching to an existing PTY fd (for compositor restart).
/// The shell is already running — no fork, no spawn.
pub fn initWithPty(allocator: Allocator, rows: u16, cols: u16, id: u64, spawn_config: SpawnConfig, pty: Pty) !Pane {
    var grid = try Grid.init(allocator, rows, cols);
    var sb = Scrollback.init(allocator, .{
        .keyframe_interval = 100,
        .max_lines = spawn_config.scrollback_lines,
    });
    grid.scrollback = &sb;

    // Set PTY master to non-blocking
    if (builtin.os.tag != .windows) {
        const flags = std.c.fcntl(pty.master, posix.F.GETFL);
        if (flags >= 0) {
            _ = std.c.fcntl(pty.master, posix.F.SETFL, flags | compat.O_NONBLOCK);
        }
    }

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
    }) catch |e| {
        // The old PTY was already deinit'd above, so on failure the pane has
        // no live shell until the next liveness sweep retries closePane →
        // respawnShell. Log it instead of failing silently.
        std.log.scoped(.core).err("respawnShell failed: {s} (pane has no shell until next retry)", .{@errorName(e)});
        return;
    };

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
        debugLogPty(buf[0..n]);
        self.vt.feed(buf[0..n]);
        self.grid.dirty = true;
    }
    return n;
}

// ── Debug: raw PTY capture ───────────────────────────────────────
// Set TERUWM_PTY_LOG=/path to append every byte a pane receives from its
// PTY (before the parser sees it) to that file. Off by default (one cached
// env check, then a single null-pointer branch per read). Used to capture
// the exact byte stream behind the redraw-triggered "textis" shell-render
// bug, which only manifests in long-lived live sessions: reproduce with one
// shell open, then replay the file through VtParser to find the corruption.
var pty_log_path: ?[]const u8 = null;
var pty_log_checked: bool = false;
fn debugLogPty(bytes: []const u8) void {
    if (!pty_log_checked) {
        pty_log_checked = true;
        pty_log_path = compat.getenv("TERUWM_PTY_LOG");
    }
    const path = pty_log_path orelse return;
    var pbuf: [256:0]u8 = undefined;
    if (path.len >= pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const f = std.c.fopen(&pbuf, "ab") orelse return;
    _ = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
    _ = std.c.fclose(f);
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

/// Recover from an ORPHANED alt screen. If the pane is on the alt buffer but
/// the PTY foreground process group is just the pane's own shell — i.e. NO
/// program is running — then whatever entered the alt screen exited without
/// sending the leave sequence (`ESC[?1049l`): an SSH session dropped on a
/// broken pipe, or a TUI was SIGKILL'd. The dead frame would otherwise show
/// through beneath the recovered shell prompt (the "I closed it but still see
/// it" overlap). Leave the alt screen so the shell gets a clean main screen.
///
/// Tight + safe: a live full-screen app is ALWAYS the foreground job, so
/// `foreground == shell` while on the alt screen can only mean "orphaned".
/// Cheap: the `alt_screen` short-circuit skips the TIOCGPGRP syscall in the
/// common (not-on-alt) case. Returns true if it acted (the caller schedules a
/// repaint — switchToMainScreen already marks the grid fully dirty).
pub fn reconcileAltScreen(self: *Pane) bool {
    if (!self.vt.alt_screen) return false;
    const fg = self.foregroundPid() orelse return false;
    const shell = self.childPid() orelse return false;
    if (fg != shell) return false; // a foreground program is running — legit alt screen
    self.vt.forceLeaveAltScreen();
    return true;
}

/// The pid of the pane's PTY foreground process group — the program actually
/// running (a TUI/agent like `claude`, `vim`, `htop`), or the login shell when
/// the pane is idle. Falls back to the child shell pid. Session save uses this
/// (not `childPid`) so a restored pane re-launches the running command rather
/// than just the bare shell.
pub fn foregroundPid(self: *const Pane) ?i32 {
    return switch (self.backend) {
        .local => |*p| p.foregroundPid(),
        .remote => null,
    };
}

/// The command line of the pane's foreground process, read from /proc with the
/// NUL-separated argv joined by spaces. A *login* shell is exec'd with a
/// leading-dash argv[0] (`-fish`, `-bash`); that form has no PATH entry, so
/// re-launching it via execvp / `sh -c` on restore would ENOENT and silently
/// drop the pane — strip the single leading dash so the saved command stays
/// restorable (it comes back as a non-login shell, the correct fallback).
/// Used by both session-save paths (teruwm + the teru multiplexer).
pub fn foregroundCmdline(self: *const Pane, buf: []u8) []const u8 {
    const pid = self.foregroundPid() orelse return "";
    const cmd = compat.readProcCmdline(@intCast(pid), buf);
    if (cmd.len > 1 and cmd[0] == '-') return cmd[1..];
    return cmd;
}

/// The working directory of the pane's foreground process (Linux only; empty
/// string elsewhere or on error). Restores each pane where its app was running.
pub fn foregroundCwd(self: *const Pane, buf: []u8) []const u8 {
    if (builtin.os.tag != .linux) return "";
    const pid = self.foregroundPid() orelse return "";
    var proc_path: [64:0]u8 = undefined;
    const path = std.fmt.bufPrint(&proc_path, "/proc/{d}/cwd", .{pid}) catch return "";
    proc_path[path.len] = 0;
    const rc = std.c.readlink(&proc_path, buf.ptr, buf.len);
    if (rc > 0) return buf[0..@intCast(rc)];
    return "";
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

test "axisScrollPixels: notched wheel is fixed lines-per-notch, ignores delta magnitude" {
    // sign=-1 (TUI default: scroll-down → newer), 3 lines/notch, cell_height 16.
    // One notch down (delta>0, discrete=120) → -3 lines = -48 px.
    try std.testing.expectEqual(@as(i32, -48), Pane.axisScrollPixels(15.0, 120, 16, -1, 3, 1.0));
    // A huge wheel delta still moves exactly one notch — magnitude is ignored.
    try std.testing.expectEqual(@as(i32, -48), Pane.axisScrollPixels(99.0, 120, 16, -1, 3, 1.0));
    // Two notches up (delta<0, discrete=-240) → +6 lines = +96 px.
    try std.testing.expectEqual(@as(i32, 96), Pane.axisScrollPixels(-30.0, -240, 16, -1, 3, 1.0));
    // invert flips the direction.
    try std.testing.expectEqual(@as(i32, 48), Pane.axisScrollPixels(15.0, 120, 16, 1, 3, 1.0));
}

test "axisScrollPixels: touchpad is proportional to finger travel, not fixed lines" {
    // discrete=0 → continuous. A small flick of 10 units → 10 px (× factor), not 3 lines.
    try std.testing.expectEqual(@as(i32, -10), Pane.axisScrollPixels(10.0, 0, 16, -1, 3, 1.0));
    // factor scales sensitivity.
    try std.testing.expectEqual(@as(i32, -5), Pane.axisScrollPixels(10.0, 0, 16, -1, 3, 0.5));
    // A sub-pixel delta never gets swallowed — at least one px, still sign-mapped
    // (delta>0 with the default invert=-1 → -1 px, same direction as a big delta).
    try std.testing.expectEqual(@as(i32, -1), Pane.axisScrollPixels(0.2, 0, 16, -1, 3, 0.1));
    try std.testing.expectEqual(@as(i32, 1), Pane.axisScrollPixels(0.2, 0, 16, 1, 3, 0.1));
    // Zero delta → no scroll.
    try std.testing.expectEqual(@as(i32, 0), Pane.axisScrollPixels(0.0, 0, 16, -1, 3, 1.0));
}

test "fractionalScrollStep: noise cancels, slow drag accumulates, no jitter" {
    // Near-rest sensor noise: alternating tiny ± deltas must NET ZERO motion
    // (this is the 1-2px back-and-forth jitter the floor caused).
    var frac: f64 = 0;
    var moved: i32 = 0;
    var k: usize = 0;
    while (k < 20) : (k += 1) {
        const d: f64 = if (k % 2 == 0) 0.3 else -0.3;
        moved += Pane.fractionalScrollStep(&frac, d, 1.0, -1);
    }
    try std.testing.expectEqual(@as(i32, 0), moved); // noise produced NO net scroll

    // A steady slow drag accumulates to whole pixels over a few events.
    frac = 0;
    var total: i32 = 0;
    k = 0;
    while (k < 10) : (k += 1) total += Pane.fractionalScrollStep(&frac, 0.5, 1.0, -1);
    // 10 × 0.5 = 5 px of travel, sign -1 → -5 (≈, within the carried remainder).
    try std.testing.expect(total == -5 or total == -4);

    // factor scales; a big delta moves immediately.
    frac = 0;
    try std.testing.expectEqual(@as(i32, -8), Pane.fractionalScrollStep(&frac, 16.0, 0.5, -1));
}

test "dragEdgeScroll: inside viewport is a no-op; edges scroll the right way" {
    const rows_px: i32 = 24 * 16; // 24-row pane, 16px cells → 384px content height
    // Cursor well inside the viewport → no auto-scroll.
    try std.testing.expectEqual(@as(i32, 0), Pane.dragEdgeScroll(100, rows_px, 16).dir);
    // Just past the bottom → toward the live tail (dir -1), 1 line.
    const below = Pane.dragEdgeScroll(rows_px + 1, rows_px, 16);
    try std.testing.expectEqual(@as(i32, -1), below.dir);
    try std.testing.expectEqual(@as(i32, 1), below.steps);
    // Above the top → into history (dir +1), accelerating with distance.
    const above = Pane.dragEdgeScroll(-100, rows_px, 16);
    try std.testing.expectEqual(@as(i32, 1), above.dir);
    try std.testing.expectEqual(@as(i32, 6), above.steps); // 100/16=6 → 1+min(6,5)=6
    // Far past the bottom is capped at 6 lines/frame.
    try std.testing.expectEqual(@as(i32, 6), Pane.dragEdgeScroll(rows_px + 9999, rows_px, 16).steps);
}
