//! Text selection state for mouse-driven copy.
//!
//! Tracks a rectangular selection range over the character grid.
//! Handles both forward and backward selections (start can be after end).
//! Extracts selected text with newlines at row boundaries and trailing
//! space trimming.

const std = @import("std");
const Grid = @import("Grid.zig");
const Scrollback = @import("../persist/Scrollback.zig");

const Selection = @This();

active: bool = false,
start_row: u16 = 0,
start_col: u16 = 0,
end_row: u16 = 0,
end_col: u16 = 0,
/// Scroll offset at selection start. When > 0, rows 0..scroll_offset-1
/// reference scrollback lines, and rows >= scroll_offset reference grid rows.
scroll_offset: u32 = 0,

/// Begin a new selection at the given grid cell.
pub fn begin(self: *Selection, row: u16, col: u16) void {
    self.active = true;
    self.start_row = row;
    self.start_col = col;
    self.end_row = row;
    self.end_col = col;
}

/// Begin a new selection with scroll offset context.
pub fn beginScrolled(self: *Selection, row: u16, col: u16, offset: u32) void {
    self.begin(row, col);
    self.scroll_offset = offset;
}

/// Update the selection endpoint (called during drag).
pub fn update(self: *Selection, row: u16, col: u16) void {
    if (!self.active) return;
    self.end_row = row;
    self.end_col = col;
}

/// Finish the selection (mouse release). Selection remains visible
/// until explicitly cleared.
pub fn finish(self: *Selection) void {
    // Keep active=true so the highlight remains visible.
    // The selection is "done" in the sense that dragging has stopped.
    _ = self;
}

/// Select the word at (row, col). Expands left and right until a
/// delimiter character is hit.
pub fn selectWord(self: *Selection, grid: *const Grid, row: u16, col: u16, delimiters: []const u8) void {
    // Expand left
    var left: u16 = col;
    while (left > 0) {
        const ch = grid.cellAtConst(row, left -| 1).char;
        if (ch < 128 and isDelimiter(@intCast(ch), delimiters)) break;
        left -= 1;
    }
    // Expand right
    var right: u16 = col;
    while (right + 1 < grid.cols) {
        const ch = grid.cellAtConst(row, right + 1).char;
        if (ch < 128 and isDelimiter(@intCast(ch), delimiters)) break;
        right += 1;
    }
    self.active = true;
    self.start_row = row;
    self.start_col = left;
    self.end_row = row;
    self.end_col = right;
}

fn isDelimiter(ch: u8, delimiters: []const u8) bool {
    for (delimiters) |d| {
        if (ch == d) return true;
    }
    return false;
}

/// Clear the selection entirely.
pub fn clear(self: *Selection) void {
    self.active = false;
    self.start_row = 0;
    self.start_col = 0;
    self.end_row = 0;
    self.end_col = 0;
    self.scroll_offset = 0;
}

/// Normalize selection to (first_row, first_col) .. (last_row, last_col)
/// so that first <= last in reading order.
fn normalized(self: *const Selection) struct { r0: u16, c0: u16, r1: u16, c1: u16 } {
    if (self.start_row < self.end_row or
        (self.start_row == self.end_row and self.start_col <= self.end_col))
    {
        return .{ .r0 = self.start_row, .c0 = self.start_col, .r1 = self.end_row, .c1 = self.end_col };
    }
    return .{ .r0 = self.end_row, .c0 = self.end_col, .r1 = self.start_row, .c1 = self.start_col };
}

/// Check if a cell at (row, col) is within the selection.
/// Handles both forward and backward selections.
pub fn isSelected(self: *const Selection, row: u16, col: u16) bool {
    if (!self.active) return false;

    const n = self.normalized();

    // Before selection start
    if (row < n.r0) return false;
    // After selection end
    if (row > n.r1) return false;

    // Single-row selection
    if (n.r0 == n.r1) {
        return col >= n.c0 and col <= n.c1;
    }

    // Multi-row: first row starts at c0, last row ends at c1, middle rows fully selected
    if (row == n.r0) return col >= n.c0;
    if (row == n.r1) return col <= n.c1;
    return true; // middle row
}

/// Extract selected text from the grid into buf.
/// Returns the number of bytes written. Adds newlines between rows.
/// Trims trailing spaces per line.
pub fn getText(self: *const Selection, grid: *const Grid, buf: []u8) usize {
    if (!self.active) return 0;

    const n = self.normalized();
    var pos: usize = 0;

    var row = n.r0;
    while (row <= n.r1) : (row += 1) {
        const col_start: u16 = if (row == n.r0) n.c0 else 0;
        const col_end: u16 = if (row == n.r1) n.c1 else grid.cols -| 1;

        // Collect the row's characters into a temporary line buffer,
        // then trim trailing spaces before copying to output.
        var line_len: usize = 0;
        var line_buf: [2048]u8 = undefined;

        var col = col_start;
        while (col <= col_end and col < grid.cols) : (col += 1) {
            const cell = grid.cellAtConst(row, col);
            line_len = appendUtf8(&line_buf, line_len, cell.char);
        }

        // Trim trailing spaces
        while (line_len > 0 and line_buf[line_len - 1] == ' ') {
            line_len -= 1;
        }

        // Copy trimmed line to output buffer
        if (pos + line_len > buf.len) {
            // Partial copy: fill what we can
            const avail = buf.len - pos;
            @memcpy(buf[pos..][0..avail], line_buf[0..avail]);
            return buf.len;
        }
        @memcpy(buf[pos..][0..line_len], line_buf[0..line_len]);
        pos += line_len;

        // Add newline between rows (not after the last)
        if (row < n.r1) {
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }
        }
    }

    return pos;
}

/// Extract selected text, reading from scrollback for rows in the
/// scroll region and from the grid for visible rows.
pub fn getTextWithScrollback(self: *const Selection, grid: *const Grid, sb: ?*const Scrollback, buf: []u8) usize {
    if (!self.active) return 0;
    if (self.scroll_offset == 0 or sb == null) return self.getText(grid, buf);

    const n = self.normalized();
    var pos: usize = 0;
    const so = self.scroll_offset;

    var row = n.r0;
    while (row <= n.r1) : (row += 1) {
        const col_start: u16 = if (row == n.r0) n.c0 else 0;
        const col_end: u16 = if (row == n.r1) n.c1 else grid.cols -| 1;

        var line_buf: [2048]u8 = undefined;
        var line_len: usize = 0;

        if (row < so) {
            // This row is in scrollback
            const sb_offset = so - 1 - @as(u32, row);
            if (sb.?.getLineByOffset(sb_offset)) |text| {
                // Strip SGR sequences, extract plain text, respect col range
                line_len = stripSgrToColumns(text, col_start, col_end, &line_buf);
            }
        } else {
            // This row is in the grid (shifted by scroll_offset)
            const grid_row: u16 = @intCast(@as(u32, row) - so);
            if (grid_row < grid.rows) {
                var col = col_start;
                while (col <= col_end and col < grid.cols) : (col += 1) {
                    const cell = grid.cellAtConst(grid_row, col);
                    line_len = appendUtf8(&line_buf, line_len, cell.char);
                }
            }
        }

        // Trim trailing spaces
        while (line_len > 0 and line_buf[line_len - 1] == ' ') {
            line_len -= 1;
        }

        if (pos + line_len > buf.len) {
            const avail = buf.len - pos;
            @memcpy(buf[pos..][0..avail], line_buf[0..avail]);
            return buf.len;
        }
        @memcpy(buf[pos..][0..line_len], line_buf[0..line_len]);
        pos += line_len;

        if (row < n.r1) {
            if (pos < buf.len) { buf[pos] = '\n'; pos += 1; }
        }
    }
    return pos;
}

/// Strip SGR escape sequences from VT bytes, extracting plain text
/// for the given column range.
fn stripSgrToColumns(text: []const u8, col_start: u16, col_end: u16, buf: []u8) usize {
    var col: u16 = 0;
    var len: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        // Skip ESC [ ... m
        if (i + 2 < text.len and text[i] == 0x1b and text[i + 1] == '[') {
            i += 2;
            while (i < text.len) : (i += 1) {
                if (text[i] == 'm' or (text[i] >= 0x40 and text[i] <= 0x7E)) {
                    i += 1;
                    break;
                }
            }
            continue;
        }

        const byte = text[i];
        // Decode UTF-8 to count columns, but extract bytes
        if (byte < 0x80) {
            if (byte >= 32) {
                if (col >= col_start and col <= col_end) {
                    if (len < buf.len) { buf[len] = byte; len += 1; }
                }
                col += 1;
            }
            i += 1;
        } else {
            // Multi-byte UTF-8
            const seq_len: usize = if (byte < 0xC0) 1 else if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
            if (col >= col_start and col <= col_end) {
                const end = @min(i + seq_len, text.len);
                for (text[i..end]) |b| {
                    if (len < buf.len) { buf[len] = b; len += 1; }
                }
            }
            col += 1;
            i += seq_len;
        }
    }
    return len;
}

fn appendUtf8(buf: []u8, pos: usize, cp: u21) usize {
    if (cp < 0x80) {
        if (pos < buf.len) { buf[pos] = @intCast(cp); return pos + 1; }
    } else if (cp < 0x800) {
        if (pos + 2 <= buf.len) {
            buf[pos] = @intCast(0xC0 | (cp >> 6));
            buf[pos + 1] = @intCast(0x80 | (cp & 0x3F));
            return pos + 2;
        }
    } else if (cp < 0x10000) {
        if (pos + 3 <= buf.len) {
            buf[pos] = @intCast(0xE0 | (cp >> 12));
            buf[pos + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[pos + 2] = @intCast(0x80 | (cp & 0x3F));
            return pos + 3;
        }
    } else {
        if (pos + 4 <= buf.len) {
            buf[pos] = @intCast(0xF0 | (cp >> 18));
            buf[pos + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            buf[pos + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[pos + 3] = @intCast(0x80 | (cp & 0x3F));
            return pos + 4;
        }
    }
    return pos;
}

// ── Tests ────────────────────────────────────────────────────────

test "Selection begin/update/finish/clear" {
    var sel = Selection{};

    try std.testing.expect(!sel.active);

    sel.begin(5, 10);
    try std.testing.expect(sel.active);
    try std.testing.expectEqual(@as(u16, 5), sel.start_row);
    try std.testing.expectEqual(@as(u16, 10), sel.start_col);
    try std.testing.expectEqual(@as(u16, 5), sel.end_row);
    try std.testing.expectEqual(@as(u16, 10), sel.end_col);

    sel.update(8, 20);
    try std.testing.expectEqual(@as(u16, 8), sel.end_row);
    try std.testing.expectEqual(@as(u16, 20), sel.end_col);

    sel.finish();
    try std.testing.expect(sel.active); // stays active after finish

    sel.clear();
    try std.testing.expect(!sel.active);
    try std.testing.expectEqual(@as(u16, 0), sel.start_row);
}

test "isSelected single row forward" {
    var sel = Selection{};
    sel.begin(2, 3);
    sel.update(2, 7);

    try std.testing.expect(sel.isSelected(2, 3)); // start
    try std.testing.expect(sel.isSelected(2, 5)); // middle
    try std.testing.expect(sel.isSelected(2, 7)); // end
    try std.testing.expect(!sel.isSelected(2, 2)); // before
    try std.testing.expect(!sel.isSelected(2, 8)); // after
    try std.testing.expect(!sel.isSelected(1, 5)); // wrong row
    try std.testing.expect(!sel.isSelected(3, 5)); // wrong row
}

test "isSelected single row backward" {
    var sel = Selection{};
    sel.begin(2, 7);
    sel.update(2, 3);

    // Should work identically to forward
    try std.testing.expect(sel.isSelected(2, 3));
    try std.testing.expect(sel.isSelected(2, 5));
    try std.testing.expect(sel.isSelected(2, 7));
    try std.testing.expect(!sel.isSelected(2, 2));
    try std.testing.expect(!sel.isSelected(2, 8));
}

test "isSelected multi-row" {
    var sel = Selection{};
    sel.begin(1, 5);
    sel.update(3, 2);

    // Row 1: from col 5 to end
    try std.testing.expect(!sel.isSelected(1, 4));
    try std.testing.expect(sel.isSelected(1, 5));
    try std.testing.expect(sel.isSelected(1, 79)); // any col after start

    // Row 2: fully selected
    try std.testing.expect(sel.isSelected(2, 0));
    try std.testing.expect(sel.isSelected(2, 79));

    // Row 3: from start to col 2
    try std.testing.expect(sel.isSelected(3, 0));
    try std.testing.expect(sel.isSelected(3, 2));
    try std.testing.expect(!sel.isSelected(3, 3));

    // Outside rows
    try std.testing.expect(!sel.isSelected(0, 5));
    try std.testing.expect(!sel.isSelected(4, 0));
}

test "isSelected multi-row backward" {
    var sel = Selection{};
    sel.begin(3, 2);
    sel.update(1, 5);

    // Same result as forward
    try std.testing.expect(sel.isSelected(1, 5));
    try std.testing.expect(sel.isSelected(2, 0));
    try std.testing.expect(sel.isSelected(3, 2));
    try std.testing.expect(!sel.isSelected(1, 4));
    try std.testing.expect(!sel.isSelected(3, 3));
}

test "isSelected inactive returns false" {
    var sel = Selection{};
    try std.testing.expect(!sel.isSelected(0, 0));
}

test "getText single row" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 10);
    defer grid.deinit(allocator);

    // Write "Hello" at row 0
    grid.cellAt(0, 0).char = 'H';
    grid.cellAt(0, 1).char = 'e';
    grid.cellAt(0, 2).char = 'l';
    grid.cellAt(0, 3).char = 'l';
    grid.cellAt(0, 4).char = 'o';
    // cols 5-9 are spaces

    var sel = Selection{};
    sel.begin(0, 0);
    sel.update(0, 9); // select full row

    var buf: [256]u8 = undefined;
    const len = sel.getText(&grid, &buf);

    try std.testing.expectEqualStrings("Hello", buf[0..len]);
}

test "getText multi-row with trailing space trim" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);

    // Row 0: "Hi   "
    grid.cellAt(0, 0).char = 'H';
    grid.cellAt(0, 1).char = 'i';

    // Row 1: "World"
    grid.cellAt(1, 0).char = 'W';
    grid.cellAt(1, 1).char = 'o';
    grid.cellAt(1, 2).char = 'r';
    grid.cellAt(1, 3).char = 'l';
    grid.cellAt(1, 4).char = 'd';

    var sel = Selection{};
    sel.begin(0, 0);
    sel.update(1, 4);

    var buf: [256]u8 = undefined;
    const len = sel.getText(&grid, &buf);

    try std.testing.expectEqualStrings("Hi\nWorld", buf[0..len]);
}

test "getText partial row selection" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 1, 10);
    defer grid.deinit(allocator);

    // "ABCDEFGHIJ"
    var c: u16 = 0;
    while (c < 10) : (c += 1) {
        grid.cellAt(0, c).char = 'A' + @as(u21, c);
    }

    var sel = Selection{};
    sel.begin(0, 2);
    sel.update(0, 5);

    var buf: [256]u8 = undefined;
    const len = sel.getText(&grid, &buf);

    try std.testing.expectEqualStrings("CDEF", buf[0..len]);
}

test "getText inactive returns 0" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 10);
    defer grid.deinit(allocator);

    var sel = Selection{};
    var buf: [256]u8 = undefined;
    const len = sel.getText(&grid, &buf);
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "getText buffer too small" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 1, 10);
    defer grid.deinit(allocator);

    // Write "ABCDEFGHIJ"
    var c: u16 = 0;
    while (c < 10) : (c += 1) {
        grid.cellAt(0, c).char = 'A' + @as(u21, c);
    }

    var sel = Selection{};
    sel.begin(0, 0);
    sel.update(0, 9);

    // Buffer only 4 bytes
    var buf: [4]u8 = undefined;
    const len = sel.getText(&grid, &buf);
    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqualStrings("ABCD", buf[0..len]);
}

test "update on inactive selection is no-op" {
    var sel = Selection{};
    sel.update(10, 20);
    try std.testing.expect(!sel.active);
    try std.testing.expectEqual(@as(u16, 0), sel.end_row);
    try std.testing.expectEqual(@as(u16, 0), sel.end_col);
}
