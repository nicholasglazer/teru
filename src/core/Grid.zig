const std = @import("std");
const Scrollback = @import("../persist/Scrollback.zig");

/// Character grid for terminal cell data.
/// Stores a flat array of cells (rows * cols) with cursor position
/// and scroll region tracking. The VT parser writes into this grid.
const Grid = @This();

pub const Color = union(enum) {
    default,
    indexed: u8, // 0-255 (standard + 256-color)
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
    hyperlink_id: u8 = 0, // 0 = no link, 1-255 = index into hyperlink table

    pub fn blank() Cell {
        return .{};
    }
};

pub const CursorShape = enum { block, underline, bar };

// ── Color helpers for scrollback encoding ────────────────────────

fn colorEql(a: Color, b: Color) bool {
    return std.meta.eql(a, b);
}

/// Encode an SGR foreground color change into buf at position pos.
/// Returns the new position after the sequence.
fn encodeSgr(buf: []u8, pos: usize, color: Color) usize {
    var p = pos;
    switch (color) {
        .default => {
            // ESC[0m (reset)
            const seq = "\x1b[0m";
            if (p + seq.len <= buf.len) {
                @memcpy(buf[p..][0..seq.len], seq);
                p += seq.len;
            }
        },
        .indexed => |idx| {
            if (idx < 8) {
                // ESC[30-37m
                const seq = [4]u8{ 0x1b, '[', '3', '0' + idx };
                if (p + 5 <= buf.len) {
                    @memcpy(buf[p..][0..4], &seq);
                    buf[p + 4] = 'm';
                    p += 5;
                }
            } else if (idx < 16) {
                // ESC[90-97m
                const seq = [4]u8{ 0x1b, '[', '9', '0' + idx - 8 };
                if (p + 5 <= buf.len) {
                    @memcpy(buf[p..][0..4], &seq);
                    buf[p + 4] = 'm';
                    p += 5;
                }
            } else {
                // ESC[38;5;Nm — up to 12 bytes
                if (p + 12 <= buf.len) {
                    const written = std.fmt.bufPrint(buf[p..][0..12], "\x1b[38;5;{d}m", .{idx}) catch return p;
                    p += written.len;
                }
            }
        },
        .rgb => |c| {
            // ESC[38;2;R;G;Bm — up to 19 bytes
            if (p + 19 <= buf.len) {
                const written = std.fmt.bufPrint(buf[p..][0..19], "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch return p;
                p += written.len;
            }
        },
    }
    return p;
}

/// OSC 133 shell integration: semantic prompt marks.
pub const PromptMark = enum {
    none,
    prompt_start, // A: shell is drawing prompt
    input_start, // B: user is typing
    output_start, // C: command executing, output begins
    output_end, // D: command finished
};

/// OSC 8 hyperlink storage. Max URI length 256 bytes.
pub const HyperlinkEntry = struct {
    uri: [256]u8 = [_]u8{0} ** 256,
    uri_len: u16 = 0,
    active: bool = false,
};

/// Per-row metadata for shell integration (OSC 133).
pub const RowMeta = struct {
    prompt_mark: PromptMark = .none,
    exit_code: ?u8 = null, // set on D mark
};

cells: []Cell,
rows: u16,
cols: u16,
cursor_row: u16 = 0,
cursor_col: u16 = 0,
scroll_top: u16 = 0,
scroll_bottom: u16,
dirty: bool = true,
cursor_shape: CursorShape = .block,
bell: bool = false,

/// Optional scrollback buffer. When set, lines that scroll off the top
/// are captured as text and pushed to the scrollback.
scrollback: ?*Scrollback = null,

/// Pen: current attributes applied to newly written cells.
pen_fg: Color = .default,
pen_bg: Color = .default,
pen_attrs: Attrs = .{},

/// Active hyperlink ID (0 = none). Set by OSC 8; applied to new cells.
pen_hyperlink_id: u8 = 0,

/// Hyperlink URI table. Index 0 is unused (means "no link").
/// Slots are reused when a link is closed (OSC 8;; with empty URI).
hyperlinks: [256]HyperlinkEntry = [_]HyperlinkEntry{.{}} ** 256,
hyperlink_next_id: u8 = 1,

/// Saved cursor state (ESC 7 / ESC[s).
saved_cursor_row: u16 = 0,
saved_cursor_col: u16 = 0,

/// Alt screen buffer. When non-null, this holds the INACTIVE screen's cells.
/// On alt-screen switch, `cells` and `alt_cells` are swapped.
alt_cells: ?[]Cell = null,
/// Cursor position saved for the alt screen's paired main screen.
alt_saved_cursor_row: u16 = 0,
alt_saved_cursor_col: u16 = 0,

/// Per-row metadata for OSC 133 shell integration.
/// Allocated alongside cells, one entry per row.
row_meta: []RowMeta = &.{},

pub fn init(allocator: std.mem.Allocator, rows: u16, cols: u16) !Grid {
    const total = @as(usize, rows) * @as(usize, cols);
    const cells = try allocator.alloc(Cell, total);
    for (cells) |*c| c.* = Cell.blank();

    const meta = try allocator.alloc(RowMeta, rows);
    for (meta) |*m| m.* = .{};

    return .{
        .cells = cells,
        .rows = rows,
        .cols = cols,
        .scroll_bottom = rows -| 1,
        .row_meta = meta,
    };
}

pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
    allocator.free(self.cells);
    if (self.row_meta.len > 0) allocator.free(self.row_meta);
    self.row_meta = &.{};
    if (self.alt_cells) |alt| {
        allocator.free(alt);
        self.alt_cells = null;
    }
    self.cells = &.{};
}

/// Return a pointer to the cell at (row, col). Clamps to grid bounds.
pub fn cellAt(self: *Grid, row: u16, col: u16) *Cell {
    const r: usize = @min(row, self.rows -| 1);
    const c: usize = @min(col, self.cols -| 1);
    return &self.cells[r * @as(usize, self.cols) + c];
}

/// Return a const pointer to the cell at (row, col). Clamps to grid bounds.
pub fn cellAtConst(self: *const Grid, row: u16, col: u16) *const Cell {
    const r: usize = @min(row, self.rows -| 1);
    const c: usize = @min(col, self.cols -| 1);
    return &self.cells[r * @as(usize, self.cols) + c];
}

/// Write a character at the current cursor position with pen attributes,
/// then advance the cursor. Wraps to the next line at the right margin.
pub fn write(self: *Grid, char: u21) void {
    if (self.cursor_col >= self.cols) {
        // Wrap: move to start of next line
        self.cursor_col = 0;
        self.cursorDown();
    }

    const cell = self.cellAt(self.cursor_row, self.cursor_col);
    cell.char = char;
    cell.fg = self.pen_fg;
    cell.bg = self.pen_bg;
    cell.attrs = self.pen_attrs;

    self.cursor_col += 1;
    self.dirty = true;
}

/// Move the cursor down one row. If at the scroll region bottom, scroll up.
pub fn cursorDown(self: *Grid) void {
    if (self.cursor_row >= self.scroll_bottom) {
        self.scrollUp();
    } else {
        self.cursor_row += 1;
    }
}

/// Handle newline: move cursor to column 0, then move down (with scroll).
pub fn newline(self: *Grid) void {
    self.cursor_col = 0;
    self.cursorDown();
    self.dirty = true;
}

/// Scroll the scroll region up by one line (content moves up, new blank line at bottom).
pub fn scrollUp(self: *Grid) void {
    self.scrollUpN(1);
}

/// Scroll the scroll region up by n lines.
pub fn scrollUpN(self: *Grid, n: u16) void {
    const top: usize = self.scroll_top;
    const bottom: usize = self.scroll_bottom;
    const w: usize = self.cols;

    var i: u16 = 0;
    while (i < n) : (i += 1) {
        // Push the top line to scrollback before it's overwritten.
        // Encodes cell colors as SGR sequences to preserve them.
        if (self.scrollback) |sb| {
            var line_buf: [2048]u8 = undefined;
            var len: usize = 0;
            var prev_fg: Color = .default;

            for (0..w) |col| {
                const cell = self.cellAtConst(@intCast(top), @intCast(col));

                // Emit SGR sequence when foreground color changes
                if (!colorEql(cell.fg, prev_fg)) {
                    const sgr_len = encodeSgr(&line_buf, len, cell.fg);
                    len = sgr_len;
                    prev_fg = cell.fg;
                }

                if (cell.char < 128 and cell.char >= 32) {
                    if (len < line_buf.len) {
                        line_buf[len] = @intCast(cell.char);
                        len += 1;
                    }
                }
            }
            // Trim trailing spaces (but not SGR sequences)
            while (len > 0 and line_buf[len - 1] == ' ') len -= 1;
            // Scrollback capture is best-effort: OOM just drops the line
            sb.pushLine(line_buf[0..len], self) catch {};
        }

        // Shift rows up within the scroll region
        var row = top;
        while (row < bottom) : (row += 1) {
            const dst_start = row * w;
            const src_start = (row + 1) * w;
            @memcpy(self.cells[dst_start..][0..w], self.cells[src_start..][0..w]);
        }
        // Shift row_meta up within the scroll region
        if (self.row_meta.len > bottom) {
            var mr = top;
            while (mr < bottom) : (mr += 1) {
                self.row_meta[mr] = self.row_meta[mr + 1];
            }
            self.row_meta[bottom] = .{};
        }
        // Clear the bottom row of the scroll region
        self.clearRow(@intCast(bottom));
    }
    self.dirty = true;
}

/// Scroll the scroll region down by one line (content moves down, new blank line at top).
pub fn scrollDown(self: *Grid) void {
    self.scrollDownN(1);
}

/// Scroll the scroll region down by n lines.
pub fn scrollDownN(self: *Grid, n: u16) void {
    const top: usize = self.scroll_top;
    const bottom: usize = self.scroll_bottom;
    const w: usize = self.cols;

    var i: u16 = 0;
    while (i < n) : (i += 1) {
        // Shift rows down within the scroll region
        var row = bottom;
        while (row > top) : (row -= 1) {
            const dst_start = row * w;
            const src_start = (row - 1) * w;
            @memcpy(self.cells[dst_start..][0..w], self.cells[src_start..][0..w]);
        }
        // Shift row_meta down within the scroll region
        if (self.row_meta.len > bottom) {
            var mr = bottom;
            while (mr > top) : (mr -= 1) {
                self.row_meta[mr] = self.row_meta[mr - 1];
            }
            self.row_meta[top] = .{};
        }
        // Clear the top row of the scroll region
        self.clearRow(@intCast(top));
    }
    self.dirty = true;
}

/// Clear a single row to blank cells.
fn clearRow(self: *Grid, row: u16) void {
    const start: usize = @as(usize, row) * @as(usize, self.cols);
    const end = start + @as(usize, self.cols);
    for (self.cells[start..end]) |*c| c.* = Cell.blank();
}

/// Clear an entire line (0 = cursor to end, 1 = start to cursor, 2 = whole line).
pub fn clearLine(self: *Grid, row: u16, mode: u8) void {
    const r: usize = @min(row, self.rows -| 1);
    const w: usize = self.cols;
    const row_start = r * w;

    switch (mode) {
        0 => {
            // Cursor to end of line
            const start = row_start + @as(usize, @min(self.cursor_col, self.cols));
            for (self.cells[start..row_start + w]) |*c| c.* = Cell.blank();
        },
        1 => {
            // Start of line to cursor (inclusive)
            const end = row_start + @as(usize, @min(self.cursor_col + 1, self.cols));
            for (self.cells[row_start..end]) |*c| c.* = Cell.blank();
        },
        2 => {
            // Whole line
            self.clearRow(@intCast(r));
        },
        else => {},
    }
    self.dirty = true;
}

/// Clear the screen (0 = cursor to end, 1 = start to cursor, 2 = whole screen, 3 = whole screen + scrollback).
pub fn clearScreen(self: *Grid, mode: u8) void {
    switch (mode) {
        0 => {
            // Cursor to end: clear rest of current line + all lines below
            self.clearLine(self.cursor_row, 0);
            var r = self.cursor_row + 1;
            while (r < self.rows) : (r += 1) {
                self.clearRow(r);
            }
        },
        1 => {
            // Start to cursor: clear all lines above + start of current line
            var r: u16 = 0;
            while (r < self.cursor_row) : (r += 1) {
                self.clearRow(r);
            }
            self.clearLine(self.cursor_row, 1);
        },
        2, 3 => {
            // Whole screen
            for (self.cells) |*c| c.* = Cell.blank();
        },
        else => {},
    }
    self.dirty = true;
}

/// Resize the grid, preserving content where possible.
pub fn resize(self: *Grid, allocator: std.mem.Allocator, new_rows: u16, new_cols: u16) !void {
    const new_total = @as(usize, new_rows) * @as(usize, new_cols);
    const new_cells = try allocator.alloc(Cell, new_total);
    for (new_cells) |*c| c.* = Cell.blank();

    // Copy overlapping region
    const copy_rows = @min(self.rows, new_rows);
    const copy_cols = @min(self.cols, new_cols);

    var r: usize = 0;
    while (r < copy_rows) : (r += 1) {
        const old_start = r * @as(usize, self.cols);
        const new_start = r * @as(usize, new_cols);
        @memcpy(new_cells[new_start..][0..copy_cols], self.cells[old_start..][0..copy_cols]);
    }

    allocator.free(self.cells);
    self.cells = new_cells;

    // Resize row_meta, preserving existing marks
    const new_meta = try allocator.alloc(RowMeta, new_rows);
    for (new_meta) |*m| m.* = .{};
    const copy_meta = @min(self.row_meta.len, @as(usize, new_rows));
    if (copy_meta > 0) {
        @memcpy(new_meta[0..copy_meta], self.row_meta[0..copy_meta]);
    }
    if (self.row_meta.len > 0) allocator.free(self.row_meta);
    self.row_meta = new_meta;

    self.rows = new_rows;
    self.cols = new_cols;
    self.scroll_bottom = new_rows -| 1;
    self.scroll_top = 0;

    // Resize the inactive alt buffer if it exists.
    // Content in the inactive buffer is not preserved on resize — this
    // matches behavior of most terminals (xterm, Alacritty, Kitty).
    if (self.alt_cells) |old_alt| {
        allocator.free(old_alt);
        const alt_cells = try allocator.alloc(Cell, new_total);
        for (alt_cells) |*c| c.* = Cell.blank();
        self.alt_cells = alt_cells;
    }

    // Clamp cursor
    self.cursor_row = @min(self.cursor_row, new_rows -| 1);
    self.cursor_col = @min(self.cursor_col, new_cols -| 1);
    self.dirty = true;
}

/// Set cursor position (1-based coordinates, as per VT convention).
/// Clamps to grid bounds. Pass 0 or 1 for top-left.
pub fn setCursorPos(self: *Grid, row: u16, col: u16) void {
    self.cursor_row = if (row == 0) 0 else @min(row - 1, self.rows -| 1);
    self.cursor_col = if (col == 0) 0 else @min(col - 1, self.cols -| 1);
}

/// Reset pen attributes to defaults.
pub fn resetPen(self: *Grid) void {
    self.pen_fg = .default;
    self.pen_bg = .default;
    self.pen_attrs = .{};
}

/// Save cursor position.
pub fn saveCursor(self: *Grid) void {
    self.saved_cursor_row = self.cursor_row;
    self.saved_cursor_col = self.cursor_col;
}

/// Restore saved cursor position.
pub fn restoreCursor(self: *Grid) void {
    self.cursor_row = @min(self.saved_cursor_row, self.rows -| 1);
    self.cursor_col = @min(self.saved_cursor_col, self.cols -| 1);
}

/// Switch to alternate screen buffer. Saves cursor and main cells,
/// clears the alt screen, and positions cursor at (0,0).
/// If alt_cells hasn't been allocated yet, allocates them.
pub fn switchToAltScreen(self: *Grid, allocator: std.mem.Allocator) !void {
    // Save main screen cursor
    self.alt_saved_cursor_row = self.cursor_row;
    self.alt_saved_cursor_col = self.cursor_col;

    const total = @as(usize, self.rows) * @as(usize, self.cols);

    if (self.alt_cells) |alt| {
        // Alt buffer already allocated — swap cells into it
        // Store main cells in alt_cells, use alt as active cells
        const main_cells = self.cells;
        self.cells = alt;
        self.alt_cells = main_cells;
    } else {
        // First time: allocate alt buffer, swap main into it
        const alt = try allocator.alloc(Cell, total);
        // Move main cells to alt storage
        const main_cells = self.cells;
        self.alt_cells = main_cells;
        self.cells = alt;
    }

    // Clear the now-active alt screen
    for (self.cells) |*c| c.* = Cell.blank();
    self.cursor_row = 0;
    self.cursor_col = 0;
    self.scroll_top = 0;
    self.scroll_bottom = self.rows -| 1;
    self.dirty = true;
}

/// Switch back to the main screen buffer. Restores saved cursor and
/// swaps the main cells back into active use.
pub fn switchToMainScreen(self: *Grid) void {
    if (self.alt_cells) |main_cells| {
        // Swap: alt_cells holds main, cells is alt
        const alt = self.cells;
        self.cells = main_cells;
        self.alt_cells = alt;
    }

    // Restore main screen cursor
    self.cursor_row = @min(self.alt_saved_cursor_row, self.rows -| 1);
    self.cursor_col = @min(self.alt_saved_cursor_col, self.cols -| 1);
    self.scroll_top = 0;
    self.scroll_bottom = self.rows -| 1;
    self.dirty = true;
}

/// Insert n blank lines at the cursor row (within scroll region).
/// Lines below shift down; lines pushed past scroll_bottom are lost.
pub fn insertLines(self: *Grid, n: u16) void {
    if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bottom) return;
    const count = @min(n, self.scroll_bottom - self.cursor_row + 1);
    const w: usize = self.cols;

    var i: u16 = 0;
    while (i < count) : (i += 1) {
        // Shift rows down from scroll_bottom toward cursor_row
        var row: usize = self.scroll_bottom;
        while (row > self.cursor_row) : (row -= 1) {
            const dst = row * w;
            const src = (row - 1) * w;
            @memcpy(self.cells[dst..][0..w], self.cells[src..][0..w]);
        }
        self.clearRow(self.cursor_row);
    }
    self.dirty = true;
}

/// Delete n lines at the cursor row (within scroll region).
/// Lines below shift up; blank lines appear at scroll_bottom.
pub fn deleteLines(self: *Grid, n: u16) void {
    if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bottom) return;
    const count = @min(n, self.scroll_bottom - self.cursor_row + 1);
    const w: usize = self.cols;

    var i: u16 = 0;
    while (i < count) : (i += 1) {
        // Shift rows up from cursor_row toward scroll_bottom
        var row: usize = self.cursor_row;
        while (row < self.scroll_bottom) : (row += 1) {
            const dst = row * w;
            const src = (row + 1) * w;
            @memcpy(self.cells[dst..][0..w], self.cells[src..][0..w]);
        }
        self.clearRow(@intCast(self.scroll_bottom));
    }
    self.dirty = true;
}

/// Delete n characters at cursor position, shifting the rest of the line left.
/// Blank cells appear at the right edge.
pub fn deleteChars(self: *Grid, n: u16) void {
    const row: usize = self.cursor_row;
    const col: usize = self.cursor_col;
    const w: usize = self.cols;
    const count: usize = @min(n, w - col);
    const row_start = row * w;

    // Shift cells left
    if (col + count < w) {
        const remaining = w - col - count;
        const dst = row_start + col;
        const src = row_start + col + count;
        var j: usize = 0;
        while (j < remaining) : (j += 1) {
            self.cells[dst + j] = self.cells[src + j];
        }
    }
    // Blank the rightmost cells
    const blank_start = row_start + w - count;
    for (self.cells[blank_start..row_start + w]) |*c| c.* = Cell.blank();
    self.dirty = true;
}

/// Insert n blank characters at cursor position, shifting existing chars right.
/// Characters pushed past the right edge are lost.
pub fn insertBlanks(self: *Grid, n: u16) void {
    const row: usize = self.cursor_row;
    const col: usize = self.cursor_col;
    const w: usize = self.cols;
    const count: usize = @min(n, w - col);
    const row_start = row * w;

    // Shift cells right (from end to avoid overlap)
    if (col + count < w) {
        const remaining = w - col - count;
        var j: usize = remaining;
        while (j > 0) {
            j -= 1;
            self.cells[row_start + col + count + j] = self.cells[row_start + col + j];
        }
    }
    // Blank the inserted cells
    for (self.cells[row_start + col ..][0..count]) |*c| c.* = Cell.blank();
    self.dirty = true;
}

/// Erase n characters at cursor position (overwrite with blanks, no shift).
pub fn eraseChars(self: *Grid, n: u16) void {
    const row: usize = self.cursor_row;
    const col: usize = self.cursor_col;
    const w: usize = self.cols;
    const count: usize = @min(n, w - col);
    const row_start = row * w;

    for (self.cells[row_start + col ..][0..count]) |*c| c.* = Cell.blank();
    self.dirty = true;
}

// ── Tests ────────────────────────────────────────────────────────

test "init and deinit" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 24), grid.rows);
    try std.testing.expectEqual(@as(u16, 80), grid.cols);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_col);
    try std.testing.expectEqual(@as(u16, 23), grid.scroll_bottom);
    try std.testing.expectEqual(@as(usize, 24 * 80), grid.cells.len);

    // All cells should be blank spaces
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(23, 79).char);
}

test "write characters and cursor advance" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    grid.write('H');
    grid.write('i');
    grid.write('!');

    try std.testing.expectEqual(@as(u21, 'H'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'i'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, '!'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), grid.cursor_col);
}

test "write wraps at right margin" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    // Write 5 chars into a 4-col grid
    grid.write('A');
    grid.write('B');
    grid.write('C');
    grid.write('D');
    // cursor_col is now 4, which == cols. Next write triggers wrap.
    grid.write('E');

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'E'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
}

test "newline moves cursor and scrolls" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.write('A');
    grid.newline();
    grid.write('B');
    grid.newline();
    grid.write('C');

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(2, 0).char);

    // One more newline should scroll: row 0 ('A') gone, 'B' moves to row 0
    grid.newline();
    grid.write('D');

    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), grid.cellAtConst(2, 0).char);
}

test "scrollUp shifts content up" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    // Fill rows: row 0 = 'A', row 1 = 'B', row 2 = 'C'
    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';

    grid.scrollUp();

    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(2, 0).char); // cleared
}

test "scrollDown shifts content down" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';

    grid.scrollDown();

    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char); // cleared
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(2, 0).char);
}

test "clearScreen mode 2 clears all" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.write('X');
    grid.write('Y');
    grid.clearScreen(2);

    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 1).char);
}

test "clearLine modes" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);

    // Fill row 0
    var col: u16 = 0;
    while (col < 5) : (col += 1) {
        grid.cellAt(0, col).char = 'A' + @as(u21, col);
    }
    // Position cursor at column 2
    grid.cursor_row = 0;
    grid.cursor_col = 2;

    // Mode 0: clear from cursor to end
    grid.clearLine(0, 0);
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 3).char);
}

test "resize preserves content" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'X';
    grid.cellAt(1, 1).char = 'Y';

    try grid.resize(allocator, 5, 6);

    try std.testing.expectEqual(@as(u16, 5), grid.rows);
    try std.testing.expectEqual(@as(u16, 6), grid.cols);
    try std.testing.expectEqual(@as(u21, 'X'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'Y'), grid.cellAtConst(1, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(4, 5).char);
}

test "resize shrinks and clamps cursor" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 10);
    defer grid.deinit(allocator);

    grid.cursor_row = 8;
    grid.cursor_col = 9;

    try grid.resize(allocator, 5, 5);

    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 4), grid.cursor_col);
}

test "setCursorPos 1-based" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    grid.setCursorPos(5, 10);
    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 9), grid.cursor_col);

    // Clamp to bounds
    grid.setCursorPos(100, 200);
    try std.testing.expectEqual(@as(u16, 23), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 79), grid.cursor_col);

    // 0 means 1 (VT convention)
    grid.setCursorPos(0, 0);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_col);
}

test "pen attributes applied to written cells" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 10);
    defer grid.deinit(allocator);

    grid.pen_attrs.bold = true;
    grid.pen_fg = .{ .indexed = 1 };
    grid.write('B');

    const cell = grid.cellAtConst(0, 0);
    try std.testing.expect(cell.attrs.bold);
    try std.testing.expectEqual(Color{ .indexed = 1 }, cell.fg);

    grid.resetPen();
    grid.write('N');
    const cell2 = grid.cellAtConst(0, 1);
    try std.testing.expect(!cell2.attrs.bold);
    try std.testing.expectEqual(Color.default, cell2.fg);
}

test "save and restore cursor" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    grid.cursor_row = 5;
    grid.cursor_col = 10;
    grid.saveCursor();

    grid.cursor_row = 20;
    grid.cursor_col = 70;
    grid.restoreCursor();

    try std.testing.expectEqual(@as(u16, 5), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 10), grid.cursor_col);
}

test "scrollUp pushes line to scrollback" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 10);
    defer grid.deinit(allocator);

    var sb = Scrollback.init(allocator, .{ .keyframe_interval = 100 });
    defer sb.deinit();
    grid.scrollback = &sb;

    // Fill row 0 with "Hello"
    grid.cellAt(0, 0).char = 'H';
    grid.cellAt(0, 1).char = 'e';
    grid.cellAt(0, 2).char = 'l';
    grid.cellAt(0, 3).char = 'l';
    grid.cellAt(0, 4).char = 'o';
    // Columns 5-9 are spaces (should be trimmed)

    grid.scrollUp();

    // Scrollback should have captured one line
    try std.testing.expectEqual(@as(u64, 1), sb.total_lines);
    // The delta should contain "Hello" (5 bytes, trailing spaces trimmed)
    try std.testing.expectEqual(@as(usize, 1), sb.deltas.items.len);
    try std.testing.expectEqualStrings("Hello", sb.deltas.items[0].vt_bytes);
}

test "scrollUp with no scrollback is safe" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    // scrollback is null by default — scrollUp should not crash
    grid.cellAt(0, 0).char = 'X';
    grid.scrollUp();

    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(2, 0).char);
}

test "insertLines" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 3);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';
    grid.cellAt(3, 0).char = 'D';

    grid.cursor_row = 1;
    grid.insertLines(1);

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(2, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(3, 0).char);
}

test "deleteLines" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 3);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(1, 0).char = 'B';
    grid.cellAt(2, 0).char = 'C';
    grid.cellAt(3, 0).char = 'D';

    grid.cursor_row = 1;
    grid.deleteLines(1);

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(1, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), grid.cellAtConst(2, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(3, 0).char);
}

test "deleteChars" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(0, 1).char = 'B';
    grid.cellAt(0, 2).char = 'C';
    grid.cellAt(0, 3).char = 'D';
    grid.cellAt(0, 4).char = 'E';

    grid.cursor_row = 0;
    grid.cursor_col = 1;
    grid.deleteChars(2);

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'D'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'E'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 4).char);
}

test "insertBlanks" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(0, 1).char = 'B';
    grid.cellAt(0, 2).char = 'C';
    grid.cellAt(0, 3).char = 'D';
    grid.cellAt(0, 4).char = 'E';

    grid.cursor_row = 0;
    grid.cursor_col = 1;
    grid.insertBlanks(2);

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'B'), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'C'), grid.cellAtConst(0, 4).char);
}

test "eraseChars" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 5);
    defer grid.deinit(allocator);

    grid.cellAt(0, 0).char = 'A';
    grid.cellAt(0, 1).char = 'B';
    grid.cellAt(0, 2).char = 'C';
    grid.cellAt(0, 3).char = 'D';
    grid.cellAt(0, 4).char = 'E';

    grid.cursor_row = 0;
    grid.cursor_col = 1;
    grid.eraseChars(3);

    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 3).char);
    try std.testing.expectEqual(@as(u21, 'E'), grid.cellAtConst(0, 4).char);
}

test "switchToAltScreen and switchToMainScreen" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    // Write content to main screen
    grid.cellAt(0, 0).char = 'M';
    grid.cellAt(0, 1).char = 'A';
    grid.cellAt(0, 2).char = 'I';
    grid.cellAt(0, 3).char = 'N';
    grid.cursor_row = 2;
    grid.cursor_col = 3;

    // Switch to alt screen
    try grid.switchToAltScreen(allocator);

    // Alt screen should be blank
    try std.testing.expectEqual(@as(u21, ' '), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_col);

    // Write on alt screen
    grid.cellAt(1, 0).char = 'A';
    grid.cellAt(1, 1).char = 'L';
    grid.cellAt(1, 2).char = 'T';

    // Switch back to main
    grid.switchToMainScreen();

    // Main content should be restored
    try std.testing.expectEqual(@as(u21, 'M'), grid.cellAtConst(0, 0).char);
    try std.testing.expectEqual(@as(u21, 'A'), grid.cellAtConst(0, 1).char);
    try std.testing.expectEqual(@as(u21, 'I'), grid.cellAtConst(0, 2).char);
    try std.testing.expectEqual(@as(u21, 'N'), grid.cellAtConst(0, 3).char);
    // Main cursor should be restored
    try std.testing.expectEqual(@as(u16, 2), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), grid.cursor_col);
}

test "row_meta initialized to none" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 10);
    defer grid.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), grid.row_meta.len);
    for (grid.row_meta) |meta| {
        try std.testing.expectEqual(PromptMark.none, meta.prompt_mark);
        try std.testing.expectEqual(@as(?u8, null), meta.exit_code);
    }
}

test "row_meta scrolls with content" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    // Set prompt marks
    grid.row_meta[0].prompt_mark = .prompt_start;
    grid.row_meta[1].prompt_mark = .output_start;
    grid.row_meta[2].prompt_mark = .output_end;
    grid.row_meta[2].exit_code = 0;

    // Scroll up: row 0 lost, rows shift up, new bottom row cleared
    grid.scrollUp();

    try std.testing.expectEqual(PromptMark.output_start, grid.row_meta[0].prompt_mark);
    try std.testing.expectEqual(PromptMark.output_end, grid.row_meta[1].prompt_mark);
    try std.testing.expectEqual(@as(?u8, 0), grid.row_meta[1].exit_code);
    try std.testing.expectEqual(PromptMark.none, grid.row_meta[2].prompt_mark);
    try std.testing.expectEqual(@as(?u8, null), grid.row_meta[2].exit_code);
}

test "row_meta preserved on resize" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 4, 10);
    defer grid.deinit(allocator);

    grid.row_meta[0].prompt_mark = .prompt_start;
    grid.row_meta[1].prompt_mark = .input_start;
    grid.row_meta[2].prompt_mark = .output_start;
    grid.row_meta[3].prompt_mark = .output_end;
    grid.row_meta[3].exit_code = 1;

    // Grow: marks preserved
    try grid.resize(allocator, 6, 10);
    try std.testing.expectEqual(@as(usize, 6), grid.row_meta.len);
    try std.testing.expectEqual(PromptMark.prompt_start, grid.row_meta[0].prompt_mark);
    try std.testing.expectEqual(PromptMark.output_end, grid.row_meta[3].prompt_mark);
    try std.testing.expectEqual(@as(?u8, 1), grid.row_meta[3].exit_code);
    try std.testing.expectEqual(PromptMark.none, grid.row_meta[5].prompt_mark);

    // Shrink: only first 3 rows survive
    try grid.resize(allocator, 3, 10);
    try std.testing.expectEqual(@as(usize, 3), grid.row_meta.len);
    try std.testing.expectEqual(PromptMark.prompt_start, grid.row_meta[0].prompt_mark);
    try std.testing.expectEqual(PromptMark.output_start, grid.row_meta[2].prompt_mark);
}

test "scrollDown shifts row_meta down" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 4);
    defer grid.deinit(allocator);

    grid.row_meta[0].prompt_mark = .prompt_start;
    grid.row_meta[1].prompt_mark = .output_start;
    grid.row_meta[2].prompt_mark = .output_end;

    grid.scrollDown();

    // Row 0 should be cleared (new blank line at top)
    try std.testing.expectEqual(PromptMark.none, grid.row_meta[0].prompt_mark);
    // Old rows shift down
    try std.testing.expectEqual(PromptMark.prompt_start, grid.row_meta[1].prompt_mark);
    try std.testing.expectEqual(PromptMark.output_start, grid.row_meta[2].prompt_mark);
}
