//! Text selection state for mouse-driven copy.
//!
//! Tracks a rectangular selection range over the character grid.
//! Handles both forward and backward selections (start can be after end).
//! Extracts selected text with newlines at row boundaries and trailing
//! space trimming.

const std = @import("std");
const Grid = @import("Grid.zig");

const Selection = @This();

active: bool = false,
start_row: u16 = 0,
start_col: u16 = 0,
end_row: u16 = 0,
end_col: u16 = 0,

/// Begin a new selection at the given grid cell.
pub fn begin(self: *Selection, row: u16, col: u16) void {
    self.active = true;
    self.start_row = row;
    self.start_col = col;
    self.end_row = row;
    self.end_col = col;
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

/// Clear the selection entirely.
pub fn clear(self: *Selection) void {
    self.active = false;
    self.start_row = 0;
    self.start_col = 0;
    self.end_row = 0;
    self.end_col = 0;
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
        var line_buf: [1024]u8 = undefined;

        var col = col_start;
        while (col <= col_end and col < grid.cols) : (col += 1) {
            const cell = grid.cellAtConst(row, col);
            const cp = cell.char;

            // Encode the codepoint as UTF-8
            if (cp < 0x80) {
                if (line_len < line_buf.len) {
                    line_buf[line_len] = @intCast(cp);
                    line_len += 1;
                }
            } else if (cp < 0x800) {
                if (line_len + 2 <= line_buf.len) {
                    line_buf[line_len] = @intCast(0xC0 | (cp >> 6));
                    line_buf[line_len + 1] = @intCast(0x80 | (cp & 0x3F));
                    line_len += 2;
                }
            } else if (cp < 0x10000) {
                if (line_len + 3 <= line_buf.len) {
                    line_buf[line_len] = @intCast(0xE0 | (cp >> 12));
                    line_buf[line_len + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                    line_buf[line_len + 2] = @intCast(0x80 | (cp & 0x3F));
                    line_len += 3;
                }
            } else {
                if (line_len + 4 <= line_buf.len) {
                    line_buf[line_len] = @intCast(0xF0 | (cp >> 18));
                    line_buf[line_len + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                    line_buf[line_len + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                    line_buf[line_len + 3] = @intCast(0x80 | (cp & 0x3F));
                    line_len += 4;
                }
            }
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
