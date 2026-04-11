//! TuiScreen: double-buffered character cell array for TUI rendering.
//!
//! Maintains two cell buffers (current + previous). On flush(), diffs them
//! and emits only changed cells as ANSI escape sequences. This minimizes
//! bandwidth over SSH — typically <1KB per frame for incremental updates.
//!
//! Zero allocations in the render hot path. All buffers pre-allocated at
//! init or resize.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Grid = @import("../core/Grid.zig");
const Color = Grid.Color;
const Attrs = Grid.Attrs;

pub const TuiCell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    fn eql(a: TuiCell, b: TuiCell) bool {
        return a.char == b.char and
            std.meta.eql(a.fg, b.fg) and
            std.meta.eql(a.bg, b.bg) and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }
};

const Self = @This();

cells: []TuiCell,
prev: []TuiCell,
width: u16,
height: u16,
/// Pre-allocated output buffer for ANSI sequences.
output_buf: []u8,
output_len: usize = 0,
/// Track if full redraw is needed (after resize, init).
full_dirty: bool = true,

pub fn init(allocator: Allocator, rows: u16, cols: u16) !Self {
    const size: usize = @as(usize, rows) * @as(usize, cols);
    const cells = try allocator.alloc(TuiCell, size);
    const prev = try allocator.alloc(TuiCell, size);
    // 128KB output buffer — enough for a full 200x50 screen with true color
    const output_buf = try allocator.alloc(u8, 131072);
    @memset(cells, TuiCell{});
    @memset(prev, TuiCell{ .char = 0 }); // force initial full draw (differs from cells)
    return .{
        .cells = cells,
        .prev = prev,
        .width = cols,
        .height = rows,
        .output_buf = output_buf,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    allocator.free(self.cells);
    allocator.free(self.prev);
    allocator.free(self.output_buf);
}

/// Clear the current buffer to blank cells.
pub fn clear(self: *Self) void {
    @memset(self.cells, TuiCell{});
}

/// Stamp a Grid's visible cells into the screen at the given position.
/// `offset_row` and `offset_col` are character positions in the screen.
pub fn stamp(self: *Self, grid: *const Grid, offset_row: u16, offset_col: u16, stamp_rows: u16, stamp_cols: u16) void {
    const w: usize = self.width;
    const gr = grid.rows;
    const gc = grid.cols;
    const sr: usize = stamp_rows;
    const sc: usize = stamp_cols;

    for (0..@min(sr, gr)) |row| {
        const screen_row = @as(usize, offset_row) + row;
        if (screen_row >= self.height) break;
        for (0..@min(sc, gc)) |col| {
            const screen_col = @as(usize, offset_col) + col;
            if (screen_col >= w) break;
            const grid_cell = grid.cellAtConst(@intCast(row), @intCast(col));
            self.cells[screen_row * w + screen_col] = .{
                .char = grid_cell.char,
                .fg = grid_cell.fg,
                .bg = grid_cell.bg,
                .attrs = grid_cell.attrs,
            };
        }
    }
}

/// Set a single character at (row, col) with given colors/attrs.
pub fn setCell(self: *Self, row: u16, col: u16, char: u21, fg: Color, bg: Color, attrs: Attrs) void {
    if (row >= self.height or col >= self.width) return;
    self.cells[@as(usize, row) * self.width + col] = .{
        .char = char,
        .fg = fg,
        .bg = bg,
        .attrs = attrs,
    };
}

/// Draw a horizontal line of box-drawing characters.
pub fn drawHLine(self: *Self, row: u16, col_start: u16, col_end: u16, fg: Color) void {
    if (row >= self.height) return;
    var c = col_start;
    while (c < col_end and c < self.width) : (c += 1) {
        self.setCell(row, c, 0x2500, fg, .default, .{}); // ─
    }
}

/// Draw a vertical line of box-drawing characters.
pub fn drawVLine(self: *Self, col: u16, row_start: u16, row_end: u16, fg: Color) void {
    if (col >= self.width) return;
    var r = row_start;
    while (r < row_end and r < self.height) : (r += 1) {
        self.setCell(r, col, 0x2502, fg, .default, .{}); // │
    }
}

/// Diff current vs previous buffer, emit ANSI escape sequences for changed cells.
/// Returns the number of bytes written to stdout.
pub fn flush(self: *Self, stdout_fd: i32) usize {
    var p: usize = 0;
    const buf = self.output_buf;
    const w: usize = self.width;

    // Hide cursor during rendering
    p = appendStr(buf, p, "\x1b[?25l");

    var last_row: usize = 0xFFFF;
    var last_col: usize = 0xFFFF;
    var last_fg: Color = .default;
    var last_bg: Color = .default;
    var last_attrs: Attrs = .{};
    var need_sgr_reset = true;

    for (0..self.height) |row| {
        for (0..w) |col| {
            const idx = row * w + col;
            const cell = self.cells[idx];

            // Skip unchanged cells (unless full dirty)
            if (!self.full_dirty and cell.eql(self.prev[idx])) continue;

            // Flush buffer if getting full (leave room for worst-case cell: ~60 bytes)
            if (p + 80 > buf.len) {
                writeAllFd(stdout_fd, buf[0..p]);
                p = 0;
            }

            // Cursor positioning: emit CSI row;col H
            if (row != last_row or col != last_col + 1) {
                // Need explicit cursor move
                p = appendCursorPos(buf, p, @intCast(row + 1), @intCast(col + 1));
            }
            last_row = row;
            last_col = col;

            // SGR: reset if attrs changed
            const attrs_byte = @as(u8, @bitCast(cell.attrs));
            if (need_sgr_reset or attrs_byte != @as(u8, @bitCast(last_attrs))) {
                p = appendStr(buf, p, "\x1b[0m");
                // Re-apply attrs
                if (cell.attrs.bold) p = appendStr(buf, p, "\x1b[1m");
                if (cell.attrs.dim) p = appendStr(buf, p, "\x1b[2m");
                if (cell.attrs.italic) p = appendStr(buf, p, "\x1b[3m");
                if (cell.attrs.underline) p = appendStr(buf, p, "\x1b[4m");
                if (cell.attrs.inverse) p = appendStr(buf, p, "\x1b[7m");
                if (cell.attrs.strikethrough) p = appendStr(buf, p, "\x1b[9m");
                last_attrs = cell.attrs;
                // Force re-emit colors after reset
                last_fg = .default;
                last_bg = .default;
                need_sgr_reset = false;
            }

            // Foreground color
            if (!std.meta.eql(cell.fg, last_fg)) {
                p = encodeSgrColor(buf, p, cell.fg, false);
                last_fg = cell.fg;
            }

            // Background color
            if (!std.meta.eql(cell.bg, last_bg)) {
                p = encodeSgrColor(buf, p, cell.bg, true);
                last_bg = cell.bg;
            }

            // Character (UTF-8 encode)
            if (cell.char < 0x80) {
                if (p < buf.len) {
                    buf[p] = if (cell.char < 0x20) ' ' else @intCast(cell.char);
                    p += 1;
                }
            } else {
                p = appendUtf8(buf, p, cell.char);
            }
        }
    }

    // Reset SGR at end
    p = appendStr(buf, p, "\x1b[0m");

    // Show cursor
    p = appendStr(buf, p, "\x1b[?25h");

    // Write all accumulated output in one syscall
    if (p > 0) {
        writeAllFd(stdout_fd, buf[0..p]);
    }

    // Swap: current becomes previous
    @memcpy(self.prev, self.cells);
    self.full_dirty = false;
    self.output_len = p;
    return p;
}

/// Position the hardware cursor (for the active pane's cursor).
pub fn setCursorPosition(_: *Self, row: u16, col: u16, stdout_fd: i32) void {
    var buf: [24]u8 = undefined;
    // Show cursor + position it
    const p1 = appendStr(&buf, 0, "\x1b[?25h");
    const p2 = appendCursorPos(&buf, p1, row + 1, col + 1);
    writeAllFd(stdout_fd, buf[0..p2]);
}

/// Resize both buffers. Marks full dirty.
pub fn resize(self: *Self, allocator: Allocator, rows: u16, cols: u16) !void {
    const size: usize = @as(usize, rows) * @as(usize, cols);
    // Allocate new buffers before freeing old ones (safe on alloc failure)
    const new_cells = try allocator.alloc(TuiCell, size);
    const new_prev = allocator.alloc(TuiCell, size) catch {
        allocator.free(new_cells);
        return error.OutOfMemory;
    };
    allocator.free(self.cells);
    allocator.free(self.prev);
    self.cells = new_cells;
    self.prev = new_prev;
    @memset(self.cells, TuiCell{});
    @memset(self.prev, TuiCell{ .char = 0 });
    self.width = cols;
    self.height = rows;
    self.full_dirty = true;
}

// ── ANSI encoding helpers ────────────────────────────────────────

fn appendStr(buf: []u8, pos: usize, s: []const u8) usize {
    if (pos + s.len > buf.len) return pos;
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

fn appendCursorPos(buf: []u8, pos: usize, row: u16, col: u16) usize {
    // \x1b[{row};{col}H — 1-based, max "\x1b[65535;65535H" = 16 bytes
    if (pos + 16 > buf.len) return pos;
    const written = std.fmt.bufPrint(buf[pos..][0..16], "\x1b[{d};{d}H", .{ row, col }) catch return pos;
    return pos + written.len;
}

fn encodeSgrColor(buf: []u8, pos: usize, color: Color, is_bg: bool) usize {
    var p = pos;
    switch (color) {
        .default => {
            const seq = if (is_bg) "\x1b[49m" else "\x1b[39m";
            p = appendStr(buf, p, seq);
        },
        .indexed => |idx| {
            if (idx < 8) {
                const base: u8 = if (is_bg) '4' else '3';
                if (p + 5 <= buf.len) {
                    buf[p] = 0x1b;
                    buf[p + 1] = '[';
                    buf[p + 2] = base;
                    buf[p + 3] = '0' + idx;
                    buf[p + 4] = 'm';
                    p += 5;
                }
            } else if (p + 12 <= buf.len) {
                // 256-color: \x1b[38;5;Nm or \x1b[48;5;Nm
                const written = if (is_bg)
                    std.fmt.bufPrint(buf[p..][0..12], "\x1b[48;5;{d}m", .{idx}) catch return p
                else
                    std.fmt.bufPrint(buf[p..][0..12], "\x1b[38;5;{d}m", .{idx}) catch return p;
                p += written.len;
            }
        },
        .rgb => |c| {
            if (p + 20 <= buf.len) {
                const written = if (is_bg)
                    std.fmt.bufPrint(buf[p..][0..20], "\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch return p
                else
                    std.fmt.bufPrint(buf[p..][0..20], "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch return p;
                p += written.len;
            }
        },
    }
    return p;
}

fn appendUtf8(buf: []u8, pos: usize, cp: u21) usize {
    if (pos + 4 > buf.len) return pos;
    var out: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &out) catch return pos;
    @memcpy(buf[pos..][0..len], out[0..len]);
    return pos + len;
}

fn writeAllFd(fd: i32, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.c.write(fd, data[written..].ptr, data.len - written);
        if (rc <= 0) return;
        written += @intCast(rc);
    }
}

// ── Tests ────────────────────────────────────────────────────────

test "TuiScreen: init and deinit" {
    const allocator = std.testing.allocator;
    var screen = try init(allocator, 24, 80);
    defer screen.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 24), screen.height);
    try std.testing.expectEqual(@as(u16, 80), screen.width);
    try std.testing.expectEqual(@as(usize, 24 * 80), screen.cells.len);
}

test "TuiScreen: setCell and clear" {
    const allocator = std.testing.allocator;
    var screen = try init(allocator, 10, 10);
    defer screen.deinit(allocator);

    screen.setCell(5, 3, 'A', .default, .default, .{});
    try std.testing.expectEqual(@as(u21, 'A'), screen.cells[5 * 10 + 3].char);

    screen.clear();
    try std.testing.expectEqual(@as(u21, ' '), screen.cells[5 * 10 + 3].char);
}

test "TuiScreen: setCell out of bounds" {
    const allocator = std.testing.allocator;
    var screen = try init(allocator, 10, 10);
    defer screen.deinit(allocator);

    // Should not crash
    screen.setCell(100, 100, 'X', .default, .default, .{});
}

test "TuiScreen: stamp from Grid" {
    const allocator = std.testing.allocator;
    var screen = try init(allocator, 24, 80);
    defer screen.deinit(allocator);

    var grid = try Grid.init(allocator, 10, 10);
    defer grid.deinit(allocator);

    // Set a character in the grid
    grid.cellAt(0, 0).char = 'Z';
    grid.cellAt(0, 0).fg = .{ .indexed = 1 };

    screen.stamp(&grid, 2, 5, 10, 10);

    const cell = screen.cells[2 * 80 + 5];
    try std.testing.expectEqual(@as(u21, 'Z'), cell.char);
    try std.testing.expectEqual(Color{ .indexed = 1 }, cell.fg);
}

test "TuiScreen: flush produces ANSI output" {
    const allocator = std.testing.allocator;
    var screen = try init(allocator, 4, 4);
    defer screen.deinit(allocator);

    screen.setCell(0, 0, 'H', .default, .default, .{});
    screen.setCell(0, 1, 'i', .default, .default, .{});

    // Create a socketpair to capture output
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return; // skip if not available

    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const bytes_written = screen.flush(fds[0]);
    try std.testing.expect(bytes_written > 0);

    // Read what was written
    var read_buf: [4096]u8 = undefined;
    const n = std.c.read(fds[1], &read_buf, read_buf.len);
    try std.testing.expect(n > 0);

    // Should contain cursor hide, cursor positioning, H, i, cursor show
    const output = read_buf[0..@intCast(n)];
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[?25l") != null); // cursor hide
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[?25h") != null); // cursor show
    try std.testing.expect(std.mem.indexOf(u8, output, "H") != null);
}

test "TuiScreen: diff renders only changes" {
    const allocator = std.testing.allocator;
    var screen = try init(allocator, 4, 4);
    defer screen.deinit(allocator);

    screen.setCell(0, 0, 'A', .default, .default, .{});

    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return;
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    // First flush: full dirty, should be large
    const first = screen.flush(fds[0]);

    // Drain the socket
    var drain: [8192]u8 = undefined;
    _ = std.c.read(fds[1], &drain, drain.len);

    // No changes: flush should be minimal (just cursor hide/show)
    const second = screen.flush(fds[0]);
    try std.testing.expect(second < first);

    // Change one cell: flush should be small
    screen.setCell(2, 2, 'B', .default, .default, .{});
    _ = std.c.read(fds[1], &drain, drain.len); // drain previous
    const third = screen.flush(fds[0]);
    try std.testing.expect(third < first);
    try std.testing.expect(third > second);
}

test "TuiCell: eql" {
    const a = TuiCell{ .char = 'A', .fg = .default, .bg = .default, .attrs = .{} };
    const b = TuiCell{ .char = 'A', .fg = .default, .bg = .default, .attrs = .{} };
    const c = TuiCell{ .char = 'B', .fg = .default, .bg = .default, .attrs = .{} };
    const d = TuiCell{ .char = 'A', .fg = .{ .indexed = 1 }, .bg = .default, .attrs = .{} };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
}

test "appendCursorPos" {
    var buf: [24]u8 = undefined;
    const p = appendCursorPos(&buf, 0, 1, 1);
    try std.testing.expectEqualStrings("\x1b[1;1H", buf[0..p]);

    const p2 = appendCursorPos(&buf, 0, 24, 80);
    try std.testing.expectEqualStrings("\x1b[24;80H", buf[0..p2]);

    // Large terminal (>999 cols)
    const p3 = appendCursorPos(&buf, 0, 1000, 2000);
    try std.testing.expectEqualStrings("\x1b[1000;2000H", buf[0..p3]);
}

test "encodeSgrColor: default" {
    var buf: [16]u8 = undefined;
    const p = encodeSgrColor(&buf, 0, .default, false);
    try std.testing.expectEqualStrings("\x1b[39m", buf[0..p]);

    const p2 = encodeSgrColor(&buf, 0, .default, true);
    try std.testing.expectEqualStrings("\x1b[49m", buf[0..p2]);
}

test "encodeSgrColor: indexed basic" {
    var buf: [16]u8 = undefined;
    const p = encodeSgrColor(&buf, 0, .{ .indexed = 1 }, false);
    try std.testing.expectEqualStrings("\x1b[31m", buf[0..p]); // red foreground
}

test "encodeSgrColor: rgb" {
    var buf: [32]u8 = undefined;
    const p = encodeSgrColor(&buf, 0, .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } }, false);
    try std.testing.expectEqualStrings("\x1b[38;2;255;128;0m", buf[0..p]);
}
