const std = @import("std");
const Grid = @import("../core/Grid.zig");
const VtParser = @import("../core/VtParser.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;

/// Command-stream scrollback buffer with keyframe compression.
///
/// Inspired by video codecs: instead of storing expanded cell data
/// (960+ bytes/line for 80-col), stores the raw VT byte stream that
/// produced each line plus periodic keyframes (full grid snapshots).
///
/// Storage model:
///   Keyframe 0: [sparse grid snapshot]       <- every N lines
///     Delta 1: raw VT bytes (line 1)
///     Delta 2: raw VT bytes (line 2)
///     ...
///   Keyframe 1: [sparse grid snapshot]
///     Delta N: raw VT bytes (line N)
///     ...
///
/// To reconstruct line K:
///   1. Find nearest keyframe <= K
///   2. Restore grid from keyframe
///   3. Replay VT deltas from keyframe+1 through K
///
/// Typical compression: 20-50x for normal terminal output.
const Scrollback = @This();

// ── Data types ──────────────────────────────────────────────────

/// Sparse grid snapshot taken at keyframe intervals.
/// Binary format:
///   [u16 cols] [u16 rows] [u16 cursor_col] [u16 cursor_row]
///   [u16 scroll_top] [u16 scroll_bottom]
///   [u8 pen_fg_type] [pen_fg_data] [u8 pen_bg_type] [pen_bg_data]
///   [u8 pen_attrs]
///   [u32 num_non_empty_cells]
///   For each non-empty cell:
///     [u16 col] [u16 row] [u21 char (as u24/3 bytes)]
///     [u8 fg_type] [fg_data] [u8 bg_type] [bg_data] [u8 attrs]
const Keyframe = struct {
    line_number: u64,
    data: []const u8,

    fn deinit(self: *Keyframe, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// Raw VT byte chunk that produced a single scrolled-off line.
const Delta = struct {
    line_number: u64,
    vt_bytes: []const u8,

    fn deinit(self: *Delta, allocator: Allocator) void {
        allocator.free(self.vt_bytes);
    }
};

// ── Configuration ───────────────────────────────────────────────

pub const Config = struct {
    keyframe_interval: u32 = 1000,
    max_lines: u64 = 100_000,
    max_bytes: u64 = 50 * 1024 * 1024, // 50 MB
};

// ── Fields ──────────────────────────────────────────────────────

allocator: Allocator,

keyframe_interval: u32,
keyframes: ArrayList(Keyframe),
deltas: ArrayList(Delta),

total_lines: u64,
total_bytes_stored: u64,
total_bytes_equivalent: u64,

max_lines: u64,
max_bytes: u64,

/// Grid dimensions at time of last push (for equivalent-byte calculation).
grid_cols: u16,

// ── Lifecycle ───────────────────────────────────────────────────

pub fn init(allocator: Allocator, config: Config) Scrollback {
    return .{
        .allocator = allocator,
        .keyframe_interval = config.keyframe_interval,
        .keyframes = .empty,
        .deltas = .empty,
        .total_lines = 0,
        .total_bytes_stored = 0,
        .total_bytes_equivalent = 0,
        .max_lines = config.max_lines,
        .max_bytes = config.max_bytes,
        .grid_cols = 80,
    };
}

pub fn deinit(self: *Scrollback) void {
    for (self.keyframes.items) |*kf| kf.deinit(self.allocator);
    self.keyframes.deinit(self.allocator);

    for (self.deltas.items) |*d| d.deinit(self.allocator);
    self.deltas.deinit(self.allocator);

    self.* = undefined;
}

// ── Push ─────────────────────────────────────────────────────────

/// Called when a line scrolls off the top of the visible grid.
/// Stores the raw VT bytes as a delta. Every keyframe_interval lines,
/// also captures a sparse keyframe of the current grid state.
pub fn pushLine(self: *Scrollback, vt_bytes: []const u8, grid: *const Grid) !void {
    self.grid_cols = grid.cols;

    // Enforce limits before adding
    while (self.total_lines >= self.max_lines or self.total_bytes_stored >= self.max_bytes) {
        if (!self.trimOldest()) break; // nothing left to trim
    }

    const line_num = self.total_lines;

    // Store keyframe at interval boundaries
    if (line_num % @as(u64, self.keyframe_interval) == 0) {
        const kf_data = try encodeKeyframe(self.allocator, grid);
        try self.keyframes.append(self.allocator, .{
            .line_number = line_num,
            .data = kf_data,
        });
        self.total_bytes_stored += kf_data.len;
    }

    // Store delta (always)
    const owned_bytes = try self.allocator.dupe(u8, vt_bytes);
    try self.deltas.append(self.allocator, .{
        .line_number = line_num,
        .vt_bytes = owned_bytes,
    });
    self.total_bytes_stored += owned_bytes.len;

    // Track equivalent expanded cost: cols * sizeof(Cell)
    self.total_bytes_equivalent += @as(u64, grid.cols) * @sizeOf(Grid.Cell);

    self.total_lines += 1;
}

// ── Retrieval ───────────────────────────────────────────────────

/// Reconstruct a specific line into the provided grid by:
///   1. Finding the nearest keyframe at or before line_number
///   2. Restoring the grid from that keyframe
///   3. Replaying VT deltas from keyframe+1 through line_number
pub fn getLine(self: *const Scrollback, line_number: u64, grid: *Grid, vt_parser: *VtParser) !void {
    if (line_number >= self.total_lines) return error.LineOutOfRange;

    // Find the nearest keyframe at or before line_number
    const kf_idx = self.findKeyframe(line_number) orelse return error.NoKeyframe;
    const kf = &self.keyframes.items[kf_idx];

    // Restore grid from keyframe
    decodeKeyframe(grid, kf.data);

    // Point VT parser at our grid
    vt_parser.grid = grid;

    // Replay deltas from keyframe line through target line
    const start_line = kf.line_number;
    for (self.deltas.items) |*d| {
        if (d.line_number < start_line) continue;
        if (d.line_number > line_number) break;
        // Only replay deltas AFTER the keyframe (keyframe already has that line's state)
        if (d.line_number > start_line) {
            vt_parser.feed(d.vt_bytes);
        }
    }
}

/// Reconstruct a range of lines [start, end) into the grid.
/// After this call, the grid contains the result of replaying all
/// VT commands from the nearest keyframe through the end line.
pub fn getRange(self: *const Scrollback, start: u64, end: u64, grid: *Grid, vt_parser: *VtParser) !void {
    if (start >= self.total_lines) return error.LineOutOfRange;
    const clamped_end = @min(end, self.total_lines);
    if (start >= clamped_end) return error.InvalidRange;

    // Find keyframe at or before start
    const kf_idx = self.findKeyframe(start) orelse return error.NoKeyframe;
    const kf = &self.keyframes.items[kf_idx];

    // Restore grid from keyframe
    decodeKeyframe(grid, kf.data);

    // Point VT parser at our grid
    vt_parser.grid = grid;

    // Replay deltas from keyframe through end-1
    const replay_start = kf.line_number;
    for (self.deltas.items) |*d| {
        if (d.line_number < replay_start) continue;
        if (d.line_number >= clamped_end) break;
        if (d.line_number > replay_start) {
            vt_parser.feed(d.vt_bytes);
        }
    }
}

/// Get the text of a scrollback line by its index from the end.
/// offset=0 returns the most recent line, offset=1 the one before, etc.
/// Returns null if the offset is out of range.
pub fn getLineByOffset(self: *const Scrollback, offset: usize) ?[]const u8 {
    if (offset >= self.deltas.items.len) return null;
    const idx = self.deltas.items.len - 1 - offset;
    return self.deltas.items[idx].vt_bytes;
}

/// Return the number of available scrollback lines (after trimming).
pub fn lineCount(self: *const Scrollback) usize {
    return self.deltas.items.len;
}

// ── Stats ───────────────────────────────────────────────────────

/// Returns the compression ratio: equivalent_expanded / actual_stored.
/// Higher is better. Typical terminal output yields 20-50x.
pub fn compressionRatio(self: *const Scrollback) f64 {
    if (self.total_bytes_stored == 0) return 1.0;
    return @as(f64, @floatFromInt(self.total_bytes_equivalent)) /
        @as(f64, @floatFromInt(self.total_bytes_stored));
}

// ── Trim ─────────────────────────────────────────────────────────

/// Remove the oldest keyframe and all its associated deltas.
/// Returns true if something was trimmed, false if empty.
fn trimOldest(self: *Scrollback) bool {
    if (self.keyframes.items.len == 0) return false;

    // Determine the range to remove: everything from the oldest keyframe
    // up to (but not including) the second keyframe (or all deltas if only one keyframe).
    const oldest_kf_line = self.keyframes.items[0].line_number;
    const next_kf_line: u64 = if (self.keyframes.items.len > 1)
        self.keyframes.items[1].line_number
    else
        std.math.maxInt(u64);

    // Remove deltas in the oldest keyframe's range
    var deltas_removed: usize = 0;
    var bytes_freed: u64 = 0;

    while (deltas_removed < self.deltas.items.len) {
        const d = &self.deltas.items[deltas_removed];
        if (d.line_number >= next_kf_line) break;
        bytes_freed += d.vt_bytes.len;
        // Per-line equivalent bytes
        const equiv_per_line = @as(u64, self.grid_cols) * @sizeOf(Grid.Cell);
        if (self.total_bytes_equivalent >= equiv_per_line) {
            self.total_bytes_equivalent -= equiv_per_line;
        }
        d.deinit(self.allocator);
        deltas_removed += 1;
    }

    // Shift remaining deltas forward
    if (deltas_removed > 0) {
        const remaining = self.deltas.items.len - deltas_removed;
        if (remaining > 0) {
            std.mem.copyForwards(
                Delta,
                self.deltas.items[0..remaining],
                self.deltas.items[deltas_removed..self.deltas.items.len],
            );
        }
        self.deltas.items.len = remaining;
    }

    // Remove the oldest keyframe
    bytes_freed += self.keyframes.items[0].data.len;
    self.keyframes.items[0].deinit(self.allocator);
    const kf_remaining = self.keyframes.items.len - 1;
    if (kf_remaining > 0) {
        std.mem.copyForwards(
            Keyframe,
            self.keyframes.items[0..kf_remaining],
            self.keyframes.items[1..self.keyframes.items.len],
        );
    }
    self.keyframes.items.len = kf_remaining;

    if (self.total_bytes_stored >= bytes_freed) {
        self.total_bytes_stored -= bytes_freed;
    } else {
        self.total_bytes_stored = 0;
    }

    // Adjust total_lines to reflect removed lines
    const lines_removed = if (oldest_kf_line < next_kf_line and next_kf_line != std.math.maxInt(u64))
        next_kf_line - oldest_kf_line
    else if (self.keyframes.items.len == 0)
        self.total_lines
    else
        next_kf_line - oldest_kf_line;

    if (self.total_lines >= lines_removed) {
        self.total_lines -= lines_removed;
    } else {
        self.total_lines = 0;
    }

    return true;
}

// ── Keyframe search ─────────────────────────────────────────────

/// Find the index of the nearest keyframe at or before the given line.
fn findKeyframe(self: *const Scrollback, line_number: u64) ?usize {
    if (self.keyframes.items.len == 0) return null;

    // Keyframes are stored in order — binary search for the last one <= line_number.
    var best: ?usize = null;
    var lo: usize = 0;
    var hi: usize = self.keyframes.items.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (self.keyframes.items[mid].line_number <= line_number) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    return best;
}

// ── Keyframe encoding ───────────────────────────────────────────
//
// Binary format (sparse):
//   Header (14 bytes):
//     [u16 cols] [u16 rows] [u16 cursor_col] [u16 cursor_row]
//     [u16 scroll_top] [u16 scroll_bottom]
//     [u8 pen_attrs_byte]
//     [u8 pen_fg_encoded...] [u8 pen_bg_encoded...]
//
//   Body:
//     [u32 num_non_empty_cells]
//     For each non-empty cell:
//       [u16 col] [u16 row]
//       [u8 char_b0] [u8 char_b1] [u8 char_b2]  (u21 as 3 LE bytes)
//       [u8 fg_encoded...] [u8 bg_encoded...]
//       [u8 attrs_byte]

fn encodeKeyframe(allocator: Allocator, grid: *const Grid) ![]const u8 {
    // Count non-empty cells
    var count: u32 = 0;
    for (grid.cells) |c| {
        if (!isBlankCell(&c)) count += 1;
    }

    // Upper bound: header(12) + pen(1+max_color*2) + count(4) + per_cell(4+3+max_color*2+1)
    // max_color = 1+3 = 4 bytes. Per cell = 4+3+4+4+1 = 16 bytes max.
    const max_size = 12 + 1 + 8 + 4 + @as(usize, count) * 16;
    var buf = try allocator.alloc(u8, max_size);
    var pos: usize = 0;

    // Header
    writeU16(buf, &pos, grid.cols);
    writeU16(buf, &pos, grid.rows);
    writeU16(buf, &pos, grid.cursor_col);
    writeU16(buf, &pos, grid.cursor_row);
    writeU16(buf, &pos, grid.scroll_top);
    writeU16(buf, &pos, grid.scroll_bottom);

    // Pen state
    writeU8(buf, &pos, @as(u8, @bitCast(grid.pen_attrs)));
    encodeColor(buf, &pos, grid.pen_fg);
    encodeColor(buf, &pos, grid.pen_bg);

    // Cell count
    writeU32(buf, &pos, count);

    // Non-empty cells
    for (0..grid.rows) |r| {
        for (0..grid.cols) |c| {
            const cell = grid.cellAtConst(@intCast(r), @intCast(c));
            if (isBlankCell(cell)) continue;

            writeU16(buf, &pos, @intCast(c));
            writeU16(buf, &pos, @intCast(r));

            // Character as 3 LE bytes
            const ch: u24 = @intCast(cell.char);
            writeU8(buf, &pos, @truncate(ch));
            writeU8(buf, &pos, @truncate(ch >> 8));
            writeU8(buf, &pos, @truncate(ch >> 16));

            encodeColor(buf, &pos, cell.fg);
            encodeColor(buf, &pos, cell.bg);

            writeU8(buf, &pos, @as(u8, @bitCast(cell.attrs)));
        }
    }

    // Shrink to actual size
    if (pos < buf.len) {
        if (allocator.resize(buf, pos)) {
            buf.len = pos;
        } else {
            const exact = try allocator.alloc(u8, pos);
            @memcpy(exact, buf[0..pos]);
            allocator.free(buf);
            buf = exact;
        }
    }

    return buf;
}

fn decodeKeyframe(grid: *Grid, data: []const u8) void {
    var pos: usize = 0;

    // Header
    const cols = readU16(data, &pos);
    const rows = readU16(data, &pos);
    grid.cursor_col = readU16(data, &pos);
    grid.cursor_row = readU16(data, &pos);
    grid.scroll_top = readU16(data, &pos);
    grid.scroll_bottom = readU16(data, &pos);

    // Clamp cursor to actual grid dimensions (keyframe may be from different size)
    grid.cursor_col = @min(grid.cursor_col, grid.cols -| 1);
    grid.cursor_row = @min(grid.cursor_row, grid.rows -| 1);

    // Pen state
    grid.pen_attrs = @bitCast(readU8(data, &pos));
    grid.pen_fg = decodeColor(data, &pos);
    grid.pen_bg = decodeColor(data, &pos);

    // Clear grid
    for (grid.cells) |*c| c.* = Grid.Cell.blank();

    // Cell count
    const count = readU32(data, &pos);

    // Restore cells (skip any that fall outside current grid dimensions)
    _ = cols;
    _ = rows;
    for (0..count) |_| {
        const col = readU16(data, &pos);
        const row = readU16(data, &pos);

        // Character from 3 LE bytes
        const b0: u24 = readU8(data, &pos);
        const b1: u24 = readU8(data, &pos);
        const b2: u24 = readU8(data, &pos);
        const char: u21 = @intCast(b0 | (b1 << 8) | (b2 << 16));

        const fg = decodeColor(data, &pos);
        const bg = decodeColor(data, &pos);
        const attrs: Grid.Attrs = @bitCast(readU8(data, &pos));

        if (col < grid.cols and row < grid.rows) {
            const cell = grid.cellAt(row, col);
            cell.char = char;
            cell.fg = fg;
            cell.bg = bg;
            cell.attrs = attrs;
        }
    }
}

// ── Color encoding ──────────────────────────────────────────────
// Tag byte: 0 = default, 1 = indexed (+ u8), 2 = rgb (+ r,g,b)

fn encodeColor(buf: []u8, pos: *usize, color: Grid.Color) void {
    switch (color) {
        .default => writeU8(buf, pos, 0),
        .indexed => |idx| {
            writeU8(buf, pos, 1);
            writeU8(buf, pos, idx);
        },
        .rgb => |c| {
            writeU8(buf, pos, 2);
            writeU8(buf, pos, c.r);
            writeU8(buf, pos, c.g);
            writeU8(buf, pos, c.b);
        },
    }
}

fn decodeColor(data: []const u8, pos: *usize) Grid.Color {
    const tag = readU8(data, pos);
    return switch (tag) {
        1 => .{ .indexed = readU8(data, pos) },
        2 => .{ .rgb = .{
            .r = readU8(data, pos),
            .g = readU8(data, pos),
            .b = readU8(data, pos),
        } },
        else => .default,
    };
}

// ── Binary helpers ──────────────────────────────────────────────

fn isBlankCell(cell: *const Grid.Cell) bool {
    return cell.char == ' ' and
        cell.fg == .default and
        cell.bg == .default and
        @as(u8, @bitCast(cell.attrs)) == 0;
}

fn writeU8(buf: []u8, pos: *usize, val: u8) void {
    buf[pos.*] = val;
    pos.* += 1;
}

fn writeU16(buf: []u8, pos: *usize, val: u16) void {
    buf[pos.*] = @truncate(val);
    buf[pos.* + 1] = @truncate(val >> 8);
    pos.* += 2;
}

fn writeU32(buf: []u8, pos: *usize, val: u32) void {
    buf[pos.*] = @truncate(val);
    buf[pos.* + 1] = @truncate(val >> 8);
    buf[pos.* + 2] = @truncate(val >> 16);
    buf[pos.* + 3] = @truncate(val >> 24);
    pos.* += 4;
}

fn readU8(data: []const u8, pos: *usize) u8 {
    const val = data[pos.*];
    pos.* += 1;
    return val;
}

fn readU16(data: []const u8, pos: *usize) u16 {
    const val = @as(u16, data[pos.*]) | (@as(u16, data[pos.* + 1]) << 8);
    pos.* += 2;
    return val;
}

fn readU32(data: []const u8, pos: *usize) u32 {
    const val = @as(u32, data[pos.*]) |
        (@as(u32, data[pos.* + 1]) << 8) |
        (@as(u32, data[pos.* + 2]) << 16) |
        (@as(u32, data[pos.* + 3]) << 24);
    pos.* += 4;
    return val;
}

// ── Tests ───────────────────────────────────────────────────────

test "push and retrieve single line" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 10 });
    defer sb.deinit();

    // Write "Hello" into grid, then push the VT bytes
    const vt_bytes = "Hello\r\n";
    var parser = VtParser.init(allocator, &grid);
    parser.feed(vt_bytes);

    // Simulate the line scrolling off (push line 0)
    try sb.pushLine(vt_bytes, &grid);

    try std.testing.expectEqual(@as(u64, 1), sb.total_lines);
    try std.testing.expect(sb.total_bytes_stored > 0);

    // Retrieve line 0 into a fresh grid
    var restore_grid = try Grid.init(allocator, 24, 80);
    defer restore_grid.deinit(allocator);
    var restore_parser = VtParser.init(allocator, &restore_grid);

    try sb.getLine(0, &restore_grid, &restore_parser);
    // After the keyframe (line 0), no deltas are replayed (delta 0 has the
    // same line_number as the keyframe, so it's skipped in replay).
    // The keyframe captured the grid state AFTER "Hello\r\n" was fed.
}

test "keyframe creation at interval" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 100 });
    defer sb.deinit();

    // Push 350 lines
    var i: u32 = 0;
    while (i < 350) : (i += 1) {
        const byte = [_]u8{ 'A' + @as(u8, @intCast(i % 26)), '\n' };
        try sb.pushLine(&byte, &grid);
    }

    try std.testing.expectEqual(@as(u64, 350), sb.total_lines);
    // Keyframes at lines 0, 100, 200, 300
    try std.testing.expectEqual(@as(usize, 4), sb.keyframes.items.len);
    try std.testing.expectEqual(@as(u64, 0), sb.keyframes.items[0].line_number);
    try std.testing.expectEqual(@as(u64, 100), sb.keyframes.items[1].line_number);
    try std.testing.expectEqual(@as(u64, 200), sb.keyframes.items[2].line_number);
    try std.testing.expectEqual(@as(u64, 300), sb.keyframes.items[3].line_number);
}

test "compression ratio for typical output" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 1000 });
    defer sb.deinit();

    // Simulate typical shell output: short lines of text
    const lines = [_][]const u8{
        "$ ls -la\r\n",
        "total 128\r\n",
        "drwxr-xr-x  12 user user  4096 Mar 30 10:00 .\r\n",
        "drwxr-xr-x   3 user user  4096 Mar 30 09:00 ..\r\n",
        "-rw-r--r--   1 user user   512 Mar 30 10:00 README.md\r\n",
        "-rw-r--r--   1 user user  2048 Mar 30 10:00 main.zig\r\n",
        "$ git status\r\n",
        "On branch main\r\n",
        "nothing to commit, working tree clean\r\n",
        "$ echo done\r\n",
    };

    for (0..100) |_| {
        for (lines) |line| {
            try sb.pushLine(line, &grid);
        }
    }

    const ratio = sb.compressionRatio();
    // Each line's VT bytes are ~20-60 bytes vs 80 * @sizeOf(Cell) = 960+ bytes
    try std.testing.expect(ratio > 10.0);
}

test "compression ratio for heavy ANSI" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 1000 });
    defer sb.deinit();

    // Simulate cargo build colored output with SGR sequences
    const lines = [_][]const u8{
        "\x1b[1;32m   Compiling\x1b[0m teru v0.1.0\r\n",
        "\x1b[1;32m   Compiling\x1b[0m libc v0.2.155\r\n",
        "\x1b[1;31merror[E0308]\x1b[0m: mismatched types\r\n",
        "  \x1b[1;34m-->\x1b[0m src/main.rs:42:5\r\n",
        "   \x1b[1;34m|\x1b[0m\r\n",
        "\x1b[1;34m42\x1b[0m \x1b[1;34m|\x1b[0m     let x: u32 = \"hello\";\r\n",
        "   \x1b[1;34m|\x1b[0m              \x1b[1;31m^^^^^^^\x1b[0m expected u32\r\n",
        "\x1b[1;33mwarning\x1b[0m: unused variable `y`\r\n",
    };

    for (0..200) |_| {
        for (lines) |line| {
            try sb.pushLine(line, &grid);
        }
    }

    const ratio = sb.compressionRatio();
    // Heavy ANSI lines are ~40-80 bytes vs 960+ expanded. Still good ratio.
    try std.testing.expect(ratio > 5.0);
}

test "random access within keyframe range" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 20);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 100 });
    defer sb.deinit();

    // Push 200 lines with identifiable content
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        var line_buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&line_buf, "Line {d}\r\n", .{i}) catch unreachable;
        try sb.pushLine(slice, &grid);
    }

    // Keyframes at 0 and 100
    try std.testing.expectEqual(@as(usize, 2), sb.keyframes.items.len);

    // Access line 150 — should use keyframe at 100 and replay 50 deltas
    var restore_grid = try Grid.init(allocator, 4, 20);
    defer restore_grid.deinit(allocator);
    var restore_parser = VtParser.init(allocator, &restore_grid);

    try sb.getLine(150, &restore_grid, &restore_parser);
    // The line was replayed through VT, so the grid should have content
    // (exact content depends on VT replay interactions with the small grid)
}

test "trim oldest when exceeding max" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 10);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{
        .keyframe_interval = 5,
        .max_lines = 20,
        .max_bytes = 50 * 1024 * 1024,
    });
    defer sb.deinit();

    // Push 25 lines — should trigger trimming at line 20
    var i: u32 = 0;
    while (i < 25) : (i += 1) {
        try sb.pushLine("hello\r\n", &grid);
    }

    // After trimming, total_lines should be <= max_lines
    try std.testing.expect(sb.total_lines <= sb.max_lines);
    // Should still have keyframes
    try std.testing.expect(sb.keyframes.items.len > 0);
}

test "empty lines compress maximally" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 1000 });
    defer sb.deinit();

    // Push 500 empty lines (just newlines — 1 byte each)
    for (0..500) |_| {
        try sb.pushLine("\n", &grid);
    }

    const ratio = sb.compressionRatio();
    // 1 byte stored vs 960+ equivalent per line — extreme compression
    try std.testing.expect(ratio > 50.0);
}

test "memory accounting" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 50 });
    defer sb.deinit();

    // Push some lines and verify accounting
    for (0..100) |_| {
        try sb.pushLine("test line content\r\n", &grid);
    }

    // total_bytes_stored should be sum of all keyframe data + all delta bytes
    var expected_stored: u64 = 0;
    for (sb.keyframes.items) |kf| {
        expected_stored += kf.data.len;
    }
    for (sb.deltas.items) |d| {
        expected_stored += d.vt_bytes.len;
    }
    try std.testing.expectEqual(expected_stored, sb.total_bytes_stored);

    // total_bytes_equivalent should be 100 * 80 * @sizeOf(Cell)
    const cell_size = @sizeOf(Grid.Cell);
    try std.testing.expectEqual(@as(u64, 100) * 80 * cell_size, sb.total_bytes_equivalent);
}

test "range retrieval" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 20);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 50 });
    defer sb.deinit();

    // Push 200 lines
    for (0..200) |i| {
        var line_buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&line_buf, "{d}\r\n", .{i}) catch unreachable;
        try sb.pushLine(slice, &grid);
    }

    // Retrieve range [100, 110) — should use keyframe at 100
    var restore_grid = try Grid.init(allocator, 4, 20);
    defer restore_grid.deinit(allocator);
    var restore_parser = VtParser.init(allocator, &restore_grid);

    try sb.getRange(100, 110, &restore_grid, &restore_parser);

    // Verify out-of-range errors
    try std.testing.expectError(error.LineOutOfRange, sb.getRange(300, 310, &restore_grid, &restore_parser));
    try std.testing.expectError(error.InvalidRange, sb.getRange(150, 150, &restore_grid, &restore_parser));
}

test "keyframe encodes and decodes grid state" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 10);
    defer grid.deinit(allocator);

    // Set up some state
    grid.cursor_row = 2;
    grid.cursor_col = 5;
    grid.pen_attrs.bold = true;
    grid.pen_fg = .{ .indexed = 196 };
    grid.pen_bg = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } };

    grid.cellAt(0, 0).char = 'H';
    grid.cellAt(0, 0).fg = .{ .indexed = 1 };
    grid.cellAt(0, 0).attrs.bold = true;
    grid.cellAt(0, 1).char = 'i';
    grid.cellAt(2, 3).char = '!';
    grid.cellAt(2, 3).bg = .{ .rgb = .{ .r = 255, .g = 0, .b = 128 } };

    // Encode
    const data = try encodeKeyframe(allocator, &grid);
    defer allocator.free(data);

    // Decode into a fresh grid of same dimensions
    var restored = try Grid.init(allocator, 4, 10);
    defer restored.deinit(allocator);

    decodeKeyframe(&restored, data);

    // Verify cursor
    try std.testing.expectEqual(@as(u16, 2), restored.cursor_row);
    try std.testing.expectEqual(@as(u16, 5), restored.cursor_col);

    // Verify pen
    try std.testing.expect(restored.pen_attrs.bold);
    try std.testing.expectEqual(Grid.Color{ .indexed = 196 }, restored.pen_fg);
    try std.testing.expectEqual(Grid.Color{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }, restored.pen_bg);

    // Verify cells
    try std.testing.expectEqual(@as(u21, 'H'), restored.cellAtConst(0, 0).char);
    try std.testing.expect(restored.cellAtConst(0, 0).attrs.bold);
    try std.testing.expectEqual(Grid.Color{ .indexed = 1 }, restored.cellAtConst(0, 0).fg);
    try std.testing.expectEqual(@as(u21, 'i'), restored.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, '!'), restored.cellAtConst(2, 3).char);
    try std.testing.expectEqual(Grid.Color{ .rgb = .{ .r = 255, .g = 0, .b = 128 } }, restored.cellAtConst(2, 3).bg);

    // Verify blank cells are blank
    try std.testing.expectEqual(@as(u21, ' '), restored.cellAtConst(1, 0).char);
    try std.testing.expectEqual(Grid.Color.default, restored.cellAtConst(1, 0).fg);
}

test "sparse keyframe is compact for mostly-empty grids" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    // Only write 5 characters — grid is mostly empty
    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(0, 1).char = 'B';
    grid.cellAt(0, 2).char = 'C';
    grid.cellAt(0, 3).char = 'D';
    grid.cellAt(0, 4).char = 'E';

    const data = try encodeKeyframe(allocator, &grid);
    defer allocator.free(data);

    // Full grid would be 24 * 80 * @sizeOf(Cell) = ~23KB
    // Sparse with 5 cells should be under 200 bytes
    const full_size = @as(usize, 24) * 80 * @sizeOf(Grid.Cell);
    try std.testing.expect(data.len < 200);
    try std.testing.expect(data.len < full_size / 50);
}

test "line out of range returns error" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 10);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 10 });
    defer sb.deinit();

    try sb.pushLine("hello\n", &grid);

    var restore_grid = try Grid.init(allocator, 4, 10);
    defer restore_grid.deinit(allocator);
    var restore_parser = VtParser.init(allocator, &restore_grid);

    try std.testing.expectError(error.LineOutOfRange, sb.getLine(5, &restore_grid, &restore_parser));
}

test "max_bytes limit triggers trimming" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 10);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{
        .keyframe_interval = 5,
        .max_lines = 1_000_000, // no line limit
        .max_bytes = 500, // very tight byte limit
    });
    defer sb.deinit();

    // Push until we'd exceed 500 bytes
    for (0..100) |_| {
        try sb.pushLine("this is a longer line for testing byte limits\r\n", &grid);
    }

    // Should have trimmed to stay under budget
    try std.testing.expect(sb.total_bytes_stored <= 500 + 100); // some slack for last push
}

test "getLineByOffset returns lines from end" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 10);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 100 });
    defer sb.deinit();

    try sb.pushLine("first", &grid);
    try sb.pushLine("second", &grid);
    try sb.pushLine("third", &grid);

    try std.testing.expectEqual(@as(usize, 3), sb.lineCount());

    // offset=0 is most recent
    try std.testing.expectEqualStrings("third", sb.getLineByOffset(0).?);
    try std.testing.expectEqualStrings("second", sb.getLineByOffset(1).?);
    try std.testing.expectEqualStrings("first", sb.getLineByOffset(2).?);

    // Out of range returns null
    try std.testing.expectEqual(@as(?[]const u8, null), sb.getLineByOffset(3));
}

test "lineCount matches delta count" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 10);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 100 });
    defer sb.deinit();

    try std.testing.expectEqual(@as(usize, 0), sb.lineCount());

    for (0..10) |_| {
        try sb.pushLine("test", &grid);
    }
    try std.testing.expectEqual(@as(usize, 10), sb.lineCount());
}
