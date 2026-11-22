//! Text selection state for mouse-driven copy.
//!
//! Uses absolute row coordinates: row 0 is the oldest scrollback line,
//! row (scrollback_lines + grid_rows - 1) is the bottom of the grid.
//! This makes selections stable across viewport scrolling.

const std = @import("std");
const Grid = @import("Grid.zig");
const Scrollback = @import("../persist/Scrollback.zig");

const Selection = @This();

active: bool = false,
/// Absolute row coordinates: 0 = top of scrollback history.
/// For a terminal with S scrollback lines and R grid rows,
/// rows 0..S-1 are scrollback, rows S..S+R-1 are grid.
start_row: u32 = 0,
start_col: u16 = 0,
end_row: u32 = 0,
end_col: u16 = 0,

/// Convert a screen row to an absolute row.
/// screen_row is 0-based from the top of the viewport.
/// scroll_offset is how many scrollback lines are visible above the grid.
/// sb_lines is the total number of scrollback lines.
pub fn screenToAbsolute(screen_row: u32, scroll_offset: u32, sb_lines: u32) u32 {
    // The viewport shows:
    //   rows 0..scroll_offset-1 = scrollback lines (newest first from offset)
    //   rows scroll_offset..grid_rows-1 = grid rows
    // In absolute coordinates:
    //   scrollback line at viewport row r (where r < scroll_offset) = sb_lines - scroll_offset + r
    //   grid row at viewport row r (where r >= scroll_offset) = sb_lines + (r - scroll_offset)
    if (scroll_offset > 0 and screen_row < scroll_offset) {
        return sb_lines -| scroll_offset + screen_row;
    }
    return sb_lines + screen_row -| scroll_offset;
}

/// Convert an absolute row back to a screen row, or null if off-screen.
pub fn absoluteToScreen(abs_row: u32, scroll_offset: u32, sb_lines: u32, grid_rows: u16) ?u16 {
    // Viewport shows absolute rows [sb_lines - scroll_offset .. sb_lines + grid_rows - 1 - scroll_offset]
    // Wait, let me think about this more carefully.
    //
    // When scroll_offset == 0 (no scrollback visible):
    //   screen row r maps to absolute row sb_lines + r
    //   so absolute row A maps to screen row A - sb_lines (if in range 0..grid_rows-1)
    //
    // When scroll_offset > 0:
    //   screen row 0 maps to absolute row sb_lines - scroll_offset
    //   screen row r maps to absolute row sb_lines - scroll_offset + r
    //   so absolute row A maps to screen row A - (sb_lines - scroll_offset)
    const viewport_start: u32 = sb_lines -| scroll_offset;
    if (abs_row < viewport_start) return null;
    const screen = abs_row - viewport_start;
    if (screen >= @as(u32, grid_rows)) return null;
    return @intCast(screen);
}

/// Begin a new selection at the given screen position.
pub fn begin(self: *Selection, screen_row: u32, col: u16, scroll_offset: u32, sb_lines: u32) void {
    const abs = screenToAbsolute(screen_row, scroll_offset, sb_lines);
    self.active = true;
    self.start_row = abs;
    self.start_col = col;
    self.end_row = abs;
    self.end_col = col;
}

/// Update the selection endpoint (called during drag).
pub fn update(self: *Selection, screen_row: u32, col: u16, scroll_offset: u32, sb_lines: u32) void {
    if (!self.active) return;
    self.end_row = screenToAbsolute(screen_row, scroll_offset, sb_lines);
    self.end_col = col;
}

/// Finish the selection (mouse release).
pub fn finish(self: *Selection) void {
    _ = self;
}

/// Select the word at (screen_row, col).
pub fn selectWord(self: *Selection, grid: *const Grid, screen_row: u32, col: u16, delimiters: []const u8, scroll_offset: u32, sb_lines: u32) void {
    // Word selection only works on visible grid rows (not scrollback)
    const view_row: u32 = if (scroll_offset > 0 and screen_row >= scroll_offset)
        screen_row - scroll_offset
    else if (scroll_offset == 0)
        screen_row
    else
        return; // In scrollback region, skip word selection

    if (view_row >= grid.rows) return;
    const grid_row: u16 = @intCast(view_row);

    var left: u16 = col;
    while (left > 0) {
        const ch = grid.cellAtConst(grid_row, left -| 1).char;
        if (ch < 128 and isDelimiter(@intCast(ch), delimiters)) break;
        left -= 1;
    }
    var right: u16 = col;
    while (right + 1 < grid.cols) {
        const ch = grid.cellAtConst(grid_row, right + 1).char;
        if (ch < 128 and isDelimiter(@intCast(ch), delimiters)) break;
        right += 1;
    }
    const abs = screenToAbsolute(screen_row, scroll_offset, sb_lines);
    self.active = true;
    self.start_row = abs;
    self.start_col = left;
    self.end_row = abs;
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
    self.* = .{};
}

/// Normalize to (first, last) in reading order.
fn normalized(self: *const Selection) struct { r0: u32, c0: u16, r1: u32, c1: u16 } {
    if (self.start_row < self.end_row or
        (self.start_row == self.end_row and self.start_col <= self.end_col))
    {
        return .{ .r0 = self.start_row, .c0 = self.start_col, .r1 = self.end_row, .c1 = self.end_col };
    }
    return .{ .r0 = self.end_row, .c0 = self.end_col, .r1 = self.start_row, .c1 = self.start_col };
}

/// Check if a screen cell at (screen_row, col) is within the selection,
/// given the current viewport scroll state.
pub fn isSelected(self: *const Selection, screen_row: u32, col: u16, scroll_offset: u32, sb_lines: u32) bool {
    if (!self.active) return false;
    const abs = screenToAbsolute(screen_row, scroll_offset, sb_lines);
    const n = self.normalized();

    if (abs < n.r0 or abs > n.r1) return false;

    if (n.r0 == n.r1) {
        return col >= n.c0 and col <= n.c1;
    }

    if (abs == n.r0) return col >= n.c0;
    if (abs == n.r1) return col <= n.c1;
    return true;
}

/// Whether the grid cell (row, col), shown on `screen_row`, is drawn selected.
/// A wide glyph is selected as a whole: either of its two columns being in
/// the selection highlights both, which matches what `getText` copies.
pub fn isCellSelected(self: *const Selection, grid: *const Grid, row: u16, col: u16, screen_row: u32, scroll_offset: u32, sb_lines: u32) bool {
    if (!self.active) return false;
    if (self.isSelected(screen_row, col, scroll_offset, sb_lines)) return true;
    const partner = grid.widePartner(row, col) orelse return false;
    return self.isSelected(screen_row, partner, scroll_offset, sb_lines);
}

/// Extract selected text from grid and scrollback.
pub fn getText(self: *const Selection, grid: *const Grid, sb: ?*const Scrollback, buf: []u8) usize {
    if (!self.active) return 0;

    const n = self.normalized();
    const sb_lines: u32 = if (sb) |s| @intCast(s.lineCount()) else 0;
    var pos: usize = 0;

    var row = n.r0;
    while (row <= n.r1) : (row += 1) {
        const col_start: u16 = if (row == n.r0) n.c0 else 0;
        const col_end: u16 = if (row == n.r1) n.c1 else grid.cols -| 1;

        var line_buf: [2048]u8 = undefined;
        var line_len: usize = 0;

        if (row < sb_lines) {
            // Row is in scrollback
            const sb_offset = sb_lines - 1 - row;
            if (sb.?.getLineByOffset(sb_offset)) |text| {
                line_len = stripSgrToColumns(text, col_start, col_end, &line_buf);
            }
        } else {
            // Row is in the grid
            const grid_row: u16 = @intCast(row - sb_lines);
            if (grid_row < grid.rows) {
                var col = col_start;
                // A selection that starts on the right half of a wide glyph
                // includes the glyph.
                if (col < grid.cols) {
                    if (grid.widePartner(grid_row, col)) |partner| col = @min(col, partner);
                }
                while (col <= col_end and col < grid.cols) : (col += 1) {
                    const cell = grid.cellAtConst(grid_row, col);
                    if (cell.char == 0) continue; // wide-glyph trailer — its lead carries the text (and avoids a NUL in the clipboard)
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

/// Screen columns taken by one UTF-8 sequence: two for a wide glyph, one
/// otherwise (including malformed bytes, which are drawn as one cell or not
/// at all).
fn columnsOf(seq: []const u8) u16 {
    const cp: u21 = switch (seq.len) {
        2 => (@as(u21, seq[0] & 0x1F) << 6) | (seq[1] & 0x3F),
        3 => (@as(u21, seq[0] & 0x0F) << 12) | (@as(u21, seq[1] & 0x3F) << 6) | (seq[2] & 0x3F),
        4 => (@as(u21, seq[0] & 0x07) << 18) | (@as(u21, seq[1] & 0x3F) << 12) | (@as(u21, seq[2] & 0x3F) << 6) | (seq[3] & 0x3F),
        else => return 1,
    };
    return @max(1, Grid.displayWidth(cp));
}

/// Strip SGR escape sequences from VT bytes, extracting plain text
/// for the given column range.
fn stripSgrToColumns(text: []const u8, col_start: u16, col_end: u16, buf: []u8) usize {
    var col: u16 = 0;
    var len: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        // i + 1 (not i + 2): we only need ESC and '['. The stricter bound
        // missed a truncated trailing "\x1b[" at end-of-line, leaking a
        // literal '[' into the copied text.
        if (i + 1 < text.len and text[i] == 0x1b and text[i + 1] == '[') {
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
        if (byte < 0x80) {
            if (byte >= 32) {
                if (col >= col_start and col <= col_end) {
                    if (len < buf.len) { buf[len] = byte; len += 1; }
                }
                col += 1;
            }
            i += 1;
        } else {
            const seq_len: usize = if (byte < 0xC0) 1 else if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;
            const end = @min(i + seq_len, text.len);
            // The character is copied when any column it occupies is in the
            // range, so a selection starting on the right half of a wide
            // glyph includes it, and columns after it line up with the screen.
            const width = columnsOf(text[i..end]);
            if (col + width > col_start and col <= col_end) {
                for (text[i..end]) |b| {
                    if (len < buf.len) { buf[len] = b; len += 1; }
                }
            }
            col += width;
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

test "screenToAbsolute — no scrollback" {
    // No scrollback: screen row maps directly
    try std.testing.expectEqual(@as(u32, 0), screenToAbsolute(0, 0, 0));
    try std.testing.expectEqual(@as(u32, 5), screenToAbsolute(5, 0, 0));
}

test "screenToAbsolute — with scrollback, no scroll" {
    // 100 scrollback lines, not scrolled: screen row 0 = absolute row 100
    try std.testing.expectEqual(@as(u32, 100), screenToAbsolute(0, 0, 100));
    try std.testing.expectEqual(@as(u32, 105), screenToAbsolute(5, 0, 100));
}

test "screenToAbsolute — scrolled back" {
    // 100 scrollback lines, scrolled back 10 lines:
    // screen row 0 = absolute row 90 (scrollback line 90)
    // screen row 9 = absolute row 99 (last scrollback line)
    // screen row 10 = absolute row 100 (grid row 0)
    try std.testing.expectEqual(@as(u32, 90), screenToAbsolute(0, 10, 100));
    try std.testing.expectEqual(@as(u32, 99), screenToAbsolute(9, 10, 100));
    try std.testing.expectEqual(@as(u32, 100), screenToAbsolute(10, 10, 100));
}

test "absoluteToScreen — basic" {
    // No scrollback, no scroll
    try std.testing.expectEqual(@as(?u16, 0), absoluteToScreen(0, 0, 0, 24));
    try std.testing.expectEqual(@as(?u16, 23), absoluteToScreen(23, 0, 0, 24));
    try std.testing.expectEqual(@as(?u16, null), absoluteToScreen(24, 0, 0, 24));

    // 100 scrollback, not scrolled: abs 100 = screen 0
    try std.testing.expectEqual(@as(?u16, 0), absoluteToScreen(100, 0, 100, 24));
    try std.testing.expectEqual(@as(?u16, null), absoluteToScreen(99, 0, 100, 24)); // in scrollback, off screen

    // 100 scrollback, scrolled 10: abs 90 = screen 0
    try std.testing.expectEqual(@as(?u16, 0), absoluteToScreen(90, 10, 100, 24));
    try std.testing.expectEqual(@as(?u16, 10), absoluteToScreen(100, 10, 100, 24));
}

test "Selection begin/update/clear with absolute coords" {
    var sel = Selection{};
    try std.testing.expect(!sel.active);

    sel.begin(5, 10, 0, 0);
    try std.testing.expect(sel.active);
    try std.testing.expectEqual(@as(u32, 5), sel.start_row);
    try std.testing.expectEqual(@as(u16, 10), sel.start_col);

    sel.update(8, 20, 0, 0);
    try std.testing.expectEqual(@as(u32, 8), sel.end_row);

    sel.clear();
    try std.testing.expect(!sel.active);
}

test "isSelected with scroll offset" {
    var sel = Selection{};
    // Select absolute rows 95..105 (spans scrollback and grid)
    sel.active = true;
    sel.start_row = 95;
    sel.start_col = 0;
    sel.end_row = 105;
    sel.end_col = 79;

    // Scrolled 10 lines back, 100 sb lines, screen row 0 = abs 90
    // abs 95 = screen row 5 (selected)
    try std.testing.expect(sel.isSelected(5, 40, 10, 100));
    // abs 105 = screen row 15 (selected)
    try std.testing.expect(sel.isSelected(15, 40, 10, 100));
    // abs 90 = screen row 0 (before selection)
    try std.testing.expect(!sel.isSelected(0, 40, 10, 100));
}

test "getText single row from grid" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 10);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'H';
    grid.cellAt(0, 1).char = 'e';
    grid.cellAt(0, 2).char = 'l';
    grid.cellAt(0, 3).char = 'l';
    grid.cellAt(0, 4).char = 'o';

    var sel = Selection{};
    // With no scrollback, grid row 0 = absolute row 0
    sel.begin(0, 0, 0, 0);
    sel.update(0, 9, 0, 0);

    var buf: [256]u8 = undefined;
    const len = sel.getText(&grid, null, &buf);
    try std.testing.expectEqualStrings("Hello", buf[0..len]);
}

test "getText multi-row with trailing space trim" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'H';
    grid.cellAt(0, 1).char = 'i';
    grid.cellAt(1, 0).char = 'W';
    grid.cellAt(1, 1).char = 'o';
    grid.cellAt(1, 2).char = 'r';
    grid.cellAt(1, 3).char = 'l';
    grid.cellAt(1, 4).char = 'd';

    var sel = Selection{};
    sel.begin(0, 0, 0, 0);
    sel.update(1, 4, 0, 0);

    var buf: [256]u8 = undefined;
    const len = sel.getText(&grid, null, &buf);
    try std.testing.expectEqualStrings("Hi\nWorld", buf[0..len]);
}

test "getText partial row" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 1, 10);
    defer grid.deinit(allocator);

    var c: u16 = 0;
    while (c < 10) : (c += 1) {
        grid.cellAt(0, c).char = 'A' + @as(u21, c);
    }

    var sel = Selection{};
    sel.begin(0, 2, 0, 0);
    sel.update(0, 5, 0, 0);

    var buf: [256]u8 = undefined;
    const len = sel.getText(&grid, null, &buf);
    try std.testing.expectEqualStrings("CDEF", buf[0..len]);
}

test "getText inactive returns 0" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 10);
    defer grid.deinit(allocator);

    var sel = Selection{};
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), sel.getText(&grid, null, &buf));
}

test "getText buffer too small" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 1, 10);
    defer grid.deinit(allocator);

    var c: u16 = 0;
    while (c < 10) : (c += 1) {
        grid.cellAt(0, c).char = 'A' + @as(u21, c);
    }

    var sel = Selection{};
    sel.begin(0, 0, 0, 0);
    sel.update(0, 9, 0, 0);

    var buf: [4]u8 = undefined;
    const len = sel.getText(&grid, null, &buf);
    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqualStrings("ABCD", buf[0..len]);
}

test "update on inactive selection is no-op" {
    var sel = Selection{};
    sel.update(10, 20, 0, 0);
    try std.testing.expect(!sel.active);
}

test "stripSgrToColumns counts a wide glyph as two columns" {
    var buf: [64]u8 = undefined;
    // Columns: A=0, 한=1-2, B=3, 글=4-5, C=6.
    const line = "A\u{d55c}B\x1b[1m\u{ae00}\x1b[0mC";
    try std.testing.expectEqualStrings("B", buf[0..stripSgrToColumns(line, 3, 3, &buf)]);
    try std.testing.expectEqualStrings("B\u{ae00}C", buf[0..stripSgrToColumns(line, 3, 6, &buf)]);
    try std.testing.expectEqualStrings("A\u{d55c}", buf[0..stripSgrToColumns(line, 0, 1, &buf)]);
    // Narrow non-ASCII still takes one column.
    try std.testing.expectEqualStrings("b", buf[0..stripSgrToColumns("\u{e9}b", 1, 1, &buf)]);
}

test "a selection touching either half of a wide glyph takes the whole glyph" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 1, 8);
    defer grid.deinit(allocator);
    grid.write('A');
    grid.write(0xD55C); // columns 1-2
    grid.write('B');
    grid.write('C');

    var buf: [64]u8 = undefined;
    var sel = Selection{};

    // Starting on the right half (column 2): the glyph is highlighted and copied.
    sel.begin(0, 2, 0, 0);
    sel.update(0, 3, 0, 0);
    try std.testing.expect(sel.isCellSelected(&grid, 0, 1, 0, 0, 0));
    try std.testing.expect(sel.isCellSelected(&grid, 0, 2, 0, 0, 0));
    try std.testing.expect(!sel.isCellSelected(&grid, 0, 0, 0, 0, 0));
    try std.testing.expectEqualStrings("\u{d55c}B", buf[0..sel.getText(&grid, null, &buf)]);

    // Ending on the left half (column 1): both halves are highlighted.
    sel.begin(0, 0, 0, 0);
    sel.update(0, 1, 0, 0);
    try std.testing.expect(sel.isCellSelected(&grid, 0, 2, 0, 0, 0));
    try std.testing.expect(!sel.isCellSelected(&grid, 0, 3, 0, 0, 0));
    try std.testing.expectEqualStrings("A\u{d55c}", buf[0..sel.getText(&grid, null, &buf)]);

    // The same line in scrollback copies the same text for the same columns.
    try std.testing.expectEqualStrings("\u{d55c}B", buf[0..stripSgrToColumns("A\u{d55c}BC", 2, 3, &buf)]);
    try std.testing.expectEqualStrings("A\u{d55c}", buf[0..stripSgrToColumns("A\u{d55c}BC", 0, 1, &buf)]);
}

test "selection rows past 65535 lines of scrollback" {
    var sel: Selection = .{};
    const sb_lines: u32 = 200_000;
    const scroll_offset: u32 = 200_000; // scrolled to the top of the history
    sel.begin(scroll_offset + 3, 0, scroll_offset, sb_lines);
    sel.update(scroll_offset + 3, 5, scroll_offset, sb_lines);
    try std.testing.expect(sel.isSelected(scroll_offset + 3, 2, scroll_offset, sb_lines));
    try std.testing.expect(!sel.isSelected(scroll_offset + 4, 2, scroll_offset, sb_lines));
}
