//! Vi/copy mode for keyboard-driven scrollback navigation and text selection.
//!
//! Entered via prefix + v (Ctrl+Space then v). Provides vim-like cursor
//! movement, visual selection, and yank-to-clipboard. Pure computation:
//! no I/O, no allocations.

const std = @import("std");
const Grid = @import("Grid.zig");

const ViMode = @This();

/// Action returned to the caller after handling a key.
pub const Action = enum {
    none, // handled internally (cursor move, etc.)
    exit, // leave vi mode
    yank, // copy selection and exit
    search, // enter search mode
};

active: bool = false,
/// Scrollback-relative row: 0 = bottom of scrollback (newest), increases upward.
/// When in vi mode, this is the absolute row in the virtual viewport:
///   rows 0..sb_lines-1 are scrollback, rows sb_lines..sb_lines+grid_rows-1 are grid.
cursor_row: u32 = 0,
cursor_col: u16 = 0,
selection_active: bool = false,
selection_start_row: u32 = 0,
selection_start_col: u16 = 0,
line_select: bool = false,
/// Total number of rows in the virtual viewport (scrollback + grid).
total_rows: u32 = 0,
grid_cols: u16 = 0,
grid_rows: u16 = 0,

/// Enter vi mode. Cursor starts at the terminal cursor position.
/// `scroll_offset` is the current scrollback offset (0 = not scrolled).
/// `sb_lines` is the total number of scrollback lines available.
pub fn enter(
    self: *ViMode,
    rows: u16,
    cols: u16,
    cursor_row: u16,
    cursor_col: u16,
    _scroll_offset: u32,
    sb_lines: u32,
) void {
    _ = _scroll_offset; // cursor placed at absolute position regardless of scroll
    self.active = true;
    self.grid_rows = rows;
    self.grid_cols = cols;
    self.total_rows = sb_lines + rows;
    self.cursor_row = sb_lines + cursor_row;
    self.cursor_col = @min(cursor_col, cols -| 1);
    self.selection_active = false;
    self.selection_start_row = 0;
    self.selection_start_col = 0;
    self.line_select = false;
}

/// Exit vi mode, clearing all state.
pub fn exit(self: *ViMode) void {
    self.active = false;
    self.selection_active = false;
    self.line_select = false;
}

/// Handle a single key byte. Mutates cursor/selection state and returns
/// an action for the caller.
/// `scroll_offset` is updated to keep the cursor visible in the viewport.
pub fn handleKey(
    self: *ViMode,
    key: u8,
    grid: *const Grid,
    scroll_offset: *u32,
    sb_lines: u32,
) Action {
    // Update total_rows in case scrollback grew
    self.total_rows = sb_lines + self.grid_rows;

    switch (key) {
        // ── Exit ──
        'q', 0x1b => return .exit,

        // ── Navigation ──
        'h' => self.moveLeft(),
        'l' => self.moveRight(),
        'j' => self.moveDown(1),
        'k' => self.moveUp(1),

        '0' => self.cursor_col = 0,
        '$' => self.cursor_col = self.grid_cols -| 1,

        'g' => self.cursor_row = 0, // top of scrollback
        'G' => self.cursor_row = self.total_rows -| 1, // bottom

        'H' => {
            // Viewport top
            self.cursor_row = self.viewportTopRow(scroll_offset.*, sb_lines);
        },
        'M' => {
            // Viewport middle
            const top = self.viewportTopRow(scroll_offset.*, sb_lines);
            self.cursor_row = top + self.grid_rows / 2;
        },
        'L' => {
            // Viewport bottom
            const top = self.viewportTopRow(scroll_offset.*, sb_lines);
            self.cursor_row = @min(top + self.grid_rows -| 1, self.total_rows -| 1);
        },

        // Ctrl+U: half page up
        0x15 => self.moveUp(self.grid_rows / 2),
        // Ctrl+D: half page down
        0x04 => self.moveDown(self.grid_rows / 2),

        // ── Word motions ──
        'w' => self.wordForward(grid, sb_lines),
        'b' => self.wordBackward(grid, sb_lines),
        'e' => self.wordEnd(grid, sb_lines),

        // ── Selection ──
        'v' => {
            if (self.selection_active and !self.line_select) {
                // Toggle off
                self.selection_active = false;
            } else {
                self.selection_active = true;
                self.line_select = false;
                self.selection_start_row = self.cursor_row;
                self.selection_start_col = self.cursor_col;
            }
        },
        'V' => {
            if (self.selection_active and self.line_select) {
                self.selection_active = false;
                self.line_select = false;
            } else {
                self.selection_active = true;
                self.line_select = true;
                self.selection_start_row = self.cursor_row;
                self.selection_start_col = 0;
            }
        },
        'o' => {
            // Swap selection endpoint
            if (self.selection_active) {
                const tmp_row = self.cursor_row;
                const tmp_col = self.cursor_col;
                self.cursor_row = self.selection_start_row;
                self.cursor_col = self.selection_start_col;
                self.selection_start_row = tmp_row;
                self.selection_start_col = tmp_col;
            }
        },

        // ── Actions ──
        'y' => {
            if (self.selection_active) return .yank;
        },
        '/' => return .search,

        else => {},
    }

    // Clamp cursor
    if (self.total_rows > 0) {
        self.cursor_row = @min(self.cursor_row, self.total_rows -| 1);
    }
    self.cursor_col = @min(self.cursor_col, self.grid_cols -| 1);

    // Auto-scroll to keep cursor visible
    self.ensureVisible(scroll_offset, sb_lines);

    return .none;
}

/// Handle an XKB keysym for non-ASCII keys (arrows, etc.).
/// Returns true if the keysym was consumed.
pub fn handleKeysym(
    self: *ViMode,
    keysym: u32,
    scroll_offset: *u32,
    sb_lines: u32,
) Action {
    const XKB_KEY_Left: u32 = 0xff51;
    const XKB_KEY_Up: u32 = 0xff52;
    const XKB_KEY_Right: u32 = 0xff53;
    const XKB_KEY_Down: u32 = 0xff54;
    const XKB_KEY_Escape: u32 = 0xff1b;
    const XKB_KEY_Page_Up: u32 = 0xff55;
    const XKB_KEY_Page_Down: u32 = 0xff56;

    self.total_rows = sb_lines + self.grid_rows;

    switch (keysym) {
        XKB_KEY_Left => self.moveLeft(),
        XKB_KEY_Right => self.moveRight(),
        XKB_KEY_Up => self.moveUp(1),
        XKB_KEY_Down => self.moveDown(1),
        XKB_KEY_Escape => return .exit,
        XKB_KEY_Page_Up => self.moveUp(self.grid_rows / 2),
        XKB_KEY_Page_Down => self.moveDown(self.grid_rows / 2),
        else => return .none,
    }

    // Clamp
    if (self.total_rows > 0) {
        self.cursor_row = @min(self.cursor_row, self.total_rows -| 1);
    }
    self.cursor_col = @min(self.cursor_col, self.grid_cols -| 1);

    self.ensureVisible(scroll_offset, sb_lines);
    return .none;
}

// ── Internal movement helpers ────────────────────────────────────

fn moveLeft(self: *ViMode) void {
    if (self.cursor_col > 0) self.cursor_col -= 1;
}

fn moveRight(self: *ViMode) void {
    if (self.cursor_col + 1 < self.grid_cols) self.cursor_col += 1;
}

fn moveDown(self: *ViMode, n: u32) void {
    self.cursor_row = @min(self.cursor_row +| n, self.total_rows -| 1);
}

fn moveUp(self: *ViMode, n: u32) void {
    self.cursor_row = self.cursor_row -| n;
}

fn viewportTopRow(_: *const ViMode, scroll_offset: u32, sb_lines: u32) u32 {
    return sb_lines -| scroll_offset;
}

fn ensureVisible(self: *ViMode, scroll_offset: *u32, sb_lines: u32) void {
    const vp_top = self.viewportTopRow(scroll_offset.*, sb_lines);
    const vp_bottom = vp_top + self.grid_rows -| 1;

    if (self.cursor_row < vp_top) {
        // Cursor above viewport: scroll up
        scroll_offset.* = sb_lines -| self.cursor_row;
    } else if (self.cursor_row > vp_bottom) {
        // Cursor below viewport: scroll down
        const needed = self.cursor_row - self.grid_rows + 1;
        if (needed >= sb_lines) {
            scroll_offset.* = 0;
        } else {
            scroll_offset.* = sb_lines - needed;
        }
    }
}

// ── Word motion helpers ──────────────────────────────────────────

fn isWordChar(ch: u21) bool {
    if (ch >= 'a' and ch <= 'z') return true;
    if (ch >= 'A' and ch <= 'Z') return true;
    if (ch >= '0' and ch <= '9') return true;
    if (ch == '_') return true;
    return false;
}

/// Get the character at (virtual_row, col) from grid or scrollback.
fn getChar(self: *const ViMode, grid: *const Grid, sb_lines: u32, vrow: u32, col: u16) u21 {
    if (vrow >= sb_lines) {
        // Grid row
        const grid_row: u16 = @intCast(@min(vrow - sb_lines, self.grid_rows -| 1));
        if (col < grid.cols) {
            return grid.cellAtConst(grid_row, col).char;
        }
        return ' ';
    }
    // Scrollback row — we can't easily access individual characters without
    // the scrollback pointer. Return space as a safe fallback. The caller
    // passes the Grid which doesn't carry scrollback line data directly.
    // Word motion in scrollback is best-effort.
    return ' ';
}

fn wordForward(self: *ViMode, grid: *const Grid, sb_lines: u32) void {
    const max_col = self.grid_cols -| 1;
    const max_row = self.total_rows -| 1;
    var row = self.cursor_row;
    var col = self.cursor_col;

    // Skip current word chars
    while (row <= max_row) {
        if (isWordChar(self.getChar(grid, sb_lines, row, col))) {
            col += 1;
            if (col > max_col) { col = 0; row += 1; }
        } else break;
    }
    // Skip non-word chars (spaces, punctuation)
    while (row <= max_row) {
        const ch = self.getChar(grid, sb_lines, row, col);
        if (!isWordChar(ch) and ch != ' ') {
            // Punctuation counts as a "word" in vim — stop here
            break;
        }
        if (ch == ' ') {
            col += 1;
            if (col > max_col) { col = 0; row += 1; }
        } else break;
    }
    self.cursor_row = @min(row, max_row);
    self.cursor_col = @min(col, max_col);
}

fn wordBackward(self: *ViMode, grid: *const Grid, sb_lines: u32) void {
    const max_col = self.grid_cols -| 1;
    var row = self.cursor_row;
    var col = self.cursor_col;

    // Move back one first
    if (col > 0) {
        col -= 1;
    } else if (row > 0) {
        row -= 1;
        col = max_col;
    } else return;

    // Skip spaces backward
    while (true) {
        const ch = self.getChar(grid, sb_lines, row, col);
        if (ch == ' ') {
            if (col > 0) {
                col -= 1;
            } else if (row > 0) {
                row -= 1;
                col = max_col;
            } else break;
        } else break;
    }
    // Skip word chars backward
    while (true) {
        if (!isWordChar(self.getChar(grid, sb_lines, row, col))) break;
        if (col > 0) {
            col -= 1;
        } else if (row > 0) {
            row -= 1;
            col = max_col;
        } else break;
        // Check if we went past the start
        if (!isWordChar(self.getChar(grid, sb_lines, row, col))) {
            // Went one too far, step forward
            col += 1;
            if (col > max_col) { col = 0; row += 1; }
            break;
        }
    }
    self.cursor_row = row;
    self.cursor_col = col;
}

fn wordEnd(self: *ViMode, grid: *const Grid, sb_lines: u32) void {
    const max_col = self.grid_cols -| 1;
    const max_row = self.total_rows -| 1;
    var row = self.cursor_row;
    var col = self.cursor_col;

    // Move forward one first
    col += 1;
    if (col > max_col) { col = 0; row += 1; }
    if (row > max_row) { self.cursor_row = max_row; self.cursor_col = max_col; return; }

    // Skip spaces
    while (row <= max_row) {
        if (self.getChar(grid, sb_lines, row, col) == ' ') {
            col += 1;
            if (col > max_col) { col = 0; row += 1; }
        } else break;
    }
    // Move to end of word
    while (row <= max_row) {
        if (!isWordChar(self.getChar(grid, sb_lines, row, col))) break;
        const next_col = col + 1;
        if (next_col > max_col) break;
        if (!isWordChar(self.getChar(grid, sb_lines, row, next_col))) break;
        col = next_col;
    }
    self.cursor_row = @min(row, max_row);
    self.cursor_col = @min(col, max_col);
}

// ── Viewport query helpers (for rendering) ───────────────────────

/// Convert vi cursor to viewport-relative row. Returns null if not visible.
pub fn viewportRow(self: *const ViMode, scroll_offset: u32, sb_lines: u32) ?u16 {
    const vp_top = self.viewportTopRow(scroll_offset, sb_lines);
    if (self.cursor_row >= vp_top and self.cursor_row < vp_top + self.grid_rows) {
        return @intCast(self.cursor_row - vp_top);
    }
    return null;
}

/// Get normalized selection bounds in viewport coordinates for rendering.
/// Returns null if no selection is active.
pub const SelectionBounds = struct {
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
    line_select: bool,
};

pub fn getViewportSelection(self: *const ViMode, scroll_offset: u32, sb_lines: u32) ?SelectionBounds {
    if (!self.selection_active) return null;

    var sr = self.selection_start_row;
    var sc = self.selection_start_col;
    var er = self.cursor_row;
    var ec = self.cursor_col;

    // Normalize so start <= end
    if (sr > er or (sr == er and sc > ec)) {
        const tr = sr;
        const tc = sc;
        sr = er;
        sc = ec;
        er = tr;
        ec = tc;
    }

    if (self.line_select) {
        sc = 0;
        ec = self.grid_cols -| 1;
    }

    // Convert to viewport coordinates
    const vp_top = self.viewportTopRow(scroll_offset, sb_lines);
    const vp_bottom = vp_top + self.grid_rows;

    // Clamp to viewport
    if (er < vp_top or sr >= vp_bottom) return null;

    const vis_sr = if (sr >= vp_top) @as(u16, @intCast(sr - vp_top)) else 0;
    const vis_er = if (er < vp_bottom) @as(u16, @intCast(er - vp_top)) else self.grid_rows -| 1;
    const vis_sc = if (sr >= vp_top) sc else 0;
    const vis_ec = if (er < vp_bottom) ec else self.grid_cols -| 1;

    return .{
        .start_row = vis_sr,
        .start_col = vis_sc,
        .end_row = vis_er,
        .end_col = vis_ec,
        .line_select = self.line_select,
    };
}

/// Build a Selection struct for rendering highlights.
/// Uses absolute coordinates (scrollback-aware).
pub fn toSelection(self: *const ViMode, scroll_offset: u32, sb_lines: u32) ?@import("Selection.zig") {
    _ = scroll_offset;
    if (!self.selection_active) return null;

    var sr = self.selection_start_row;
    var sc = self.selection_start_col;
    var er = self.cursor_row;
    var ec = self.cursor_col;

    if (sr > er or (sr == er and sc > ec)) {
        const tr = sr; const tc = sc;
        sr = er; sc = ec;
        er = tr; ec = tc;
    }

    if (self.line_select) {
        sc = 0;
        ec = self.grid_cols -| 1;
    }

    // Vi mode rows are already absolute (0..sb_lines-1 = scrollback, sb_lines+ = grid)
    _ = sb_lines;
    const Selection = @import("Selection.zig");
    return Selection{
        .active = true,
        .start_row = sr,
        .start_col = sc,
        .end_row = er,
        .end_col = ec,
    };
}

/// Build a Selection for text extraction (yank). Uses the full
/// scrollback-aware coordinates so text above the viewport is included.
pub fn toYankSelection(self: *const ViMode, _: u32) ?@import("Selection.zig") {
    if (!self.selection_active) return null;

    var sr = self.selection_start_row;
    var sc = self.selection_start_col;
    var er = self.cursor_row;
    var ec = self.cursor_col;

    if (sr > er or (sr == er and sc > ec)) {
        const tr = sr; const tc = sc;
        sr = er; sc = ec;
        er = tr; ec = tc;
    }

    if (self.line_select) {
        sc = 0;
        ec = self.grid_cols -| 1;
    }

    // Vi mode rows are already absolute (0..sb_lines-1 = scrollback, sb_lines+ = grid).
    // Vi mode rows are already absolute coordinates
    const Selection = @import("Selection.zig");
    return Selection{
        .active = true,
        .start_row = sr,
        .start_col = sc,
        .end_row = er,
        .end_col = ec,
    };
}

/// Get the mode string for the status bar.
pub fn modeString(self: *const ViMode) []const u8 {
    if (!self.active) return "";
    if (self.selection_active) {
        return if (self.line_select) "-- VISUAL LINE --" else "-- VISUAL --";
    }
    return "-- VI --";
}

// ── Tests ────────────────────────────────────────────────────────

test "ViMode enter/exit" {
    var vm = ViMode{};
    try std.testing.expect(!vm.active);

    vm.enter(24, 80, 10, 5, 0, 100);
    try std.testing.expect(vm.active);
    try std.testing.expectEqual(@as(u32, 110), vm.cursor_row); // 100 + 10
    try std.testing.expectEqual(@as(u16, 5), vm.cursor_col);
    try std.testing.expectEqual(@as(u32, 124), vm.total_rows); // 100 + 24

    vm.exit();
    try std.testing.expect(!vm.active);
    try std.testing.expect(!vm.selection_active);
}

test "ViMode basic movement" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 12, 40, 0, 0);
    var scroll: u32 = 0;

    // h - move left
    _ = vm.handleKey('h', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u16, 39), vm.cursor_col);

    // l - move right
    _ = vm.handleKey('l', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u16, 40), vm.cursor_col);

    // j - move down
    _ = vm.handleKey('j', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u32, 13), vm.cursor_row);

    // k - move up
    _ = vm.handleKey('k', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u32, 12), vm.cursor_row);

    // 0 - line start
    _ = vm.handleKey('0', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u16, 0), vm.cursor_col);

    // $ - line end
    _ = vm.handleKey('$', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u16, 79), vm.cursor_col);
}

test "ViMode g/G movement" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 12, 40, 0, 100);
    var scroll: u32 = 0;

    // g - top of scrollback
    _ = vm.handleKey('g', &grid, &scroll, 100);
    try std.testing.expectEqual(@as(u32, 0), vm.cursor_row);

    // G - bottom
    _ = vm.handleKey('G', &grid, &scroll, 100);
    try std.testing.expectEqual(@as(u32, 123), vm.cursor_row); // 100 + 24 - 1
}

test "ViMode selection toggle" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 10, 5, 0, 0);
    var scroll: u32 = 0;

    // v - start selection
    _ = vm.handleKey('v', &grid, &scroll, 0);
    try std.testing.expect(vm.selection_active);
    try std.testing.expect(!vm.line_select);
    try std.testing.expectEqual(@as(u32, 10), vm.selection_start_row);
    try std.testing.expectEqual(@as(u16, 5), vm.selection_start_col);

    // v again - toggle off
    _ = vm.handleKey('v', &grid, &scroll, 0);
    try std.testing.expect(!vm.selection_active);

    // V - line select
    _ = vm.handleKey('V', &grid, &scroll, 0);
    try std.testing.expect(vm.selection_active);
    try std.testing.expect(vm.line_select);

    // V again - toggle off
    _ = vm.handleKey('V', &grid, &scroll, 0);
    try std.testing.expect(!vm.selection_active);
}

test "ViMode exit actions" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 10, 5, 0, 0);
    var scroll: u32 = 0;

    try std.testing.expectEqual(ViMode.Action.exit, vm.handleKey('q', &grid, &scroll, 0));

    vm.enter(24, 80, 10, 5, 0, 0);
    try std.testing.expectEqual(ViMode.Action.exit, vm.handleKey(0x1b, &grid, &scroll, 0));

    vm.enter(24, 80, 10, 5, 0, 0);
    try std.testing.expectEqual(ViMode.Action.search, vm.handleKey('/', &grid, &scroll, 0));
}

test "ViMode yank with selection" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 10, 5, 0, 0);
    var scroll: u32 = 0;

    // y without selection does nothing
    try std.testing.expectEqual(ViMode.Action.none, vm.handleKey('y', &grid, &scroll, 0));

    // Start selection, then yank
    _ = vm.handleKey('v', &grid, &scroll, 0);
    _ = vm.handleKey('l', &grid, &scroll, 0);
    _ = vm.handleKey('l', &grid, &scroll, 0);
    try std.testing.expectEqual(ViMode.Action.yank, vm.handleKey('y', &grid, &scroll, 0));
}

test "ViMode swap endpoint" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 10, 5, 0, 0);
    var scroll: u32 = 0;

    _ = vm.handleKey('v', &grid, &scroll, 0);
    _ = vm.handleKey('j', &grid, &scroll, 0);
    _ = vm.handleKey('j', &grid, &scroll, 0);
    _ = vm.handleKey('l', &grid, &scroll, 0);
    _ = vm.handleKey('l', &grid, &scroll, 0);

    const old_cursor_row = vm.cursor_row;
    const old_cursor_col = vm.cursor_col;
    const old_start_row = vm.selection_start_row;
    const old_start_col = vm.selection_start_col;

    _ = vm.handleKey('o', &grid, &scroll, 0);

    try std.testing.expectEqual(old_start_row, vm.cursor_row);
    try std.testing.expectEqual(old_start_col, vm.cursor_col);
    try std.testing.expectEqual(old_cursor_row, vm.selection_start_row);
    try std.testing.expectEqual(old_cursor_col, vm.selection_start_col);
}

test "ViMode auto-scroll" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 12, 0, 0, 100);
    var scroll: u32 = 0;

    // Move to top of scrollback — should cause scroll_offset to increase
    _ = vm.handleKey('g', &grid, &scroll, 100);
    try std.testing.expectEqual(@as(u32, 0), vm.cursor_row);
    try std.testing.expectEqual(@as(u32, 100), scroll); // scrolled to top

    // Move to bottom — should reset scroll
    _ = vm.handleKey('G', &grid, &scroll, 100);
    try std.testing.expectEqual(@as(u32, 0), scroll);
}

test "ViMode viewport row" {
    var vm = ViMode{};
    vm.enter(24, 80, 12, 5, 0, 100);

    // No scroll: viewport shows rows 100..123
    try std.testing.expectEqual(@as(?u16, 12), vm.viewportRow(0, 100));

    // Scroll to top: viewport shows rows 0..23
    try std.testing.expectEqual(@as(?u16, null), vm.viewportRow(100, 100));

    // Move cursor to top
    vm.cursor_row = 5;
    try std.testing.expectEqual(@as(?u16, 5), vm.viewportRow(100, 100));
}

test "ViMode mode string" {
    var vm = ViMode{};
    try std.testing.expectEqualStrings("", vm.modeString());

    vm.active = true;
    try std.testing.expectEqualStrings("-- VI --", vm.modeString());

    vm.selection_active = true;
    try std.testing.expectEqualStrings("-- VISUAL --", vm.modeString());

    vm.line_select = true;
    try std.testing.expectEqualStrings("-- VISUAL LINE --", vm.modeString());
}

test "ViMode toSelection" {
    var vm = ViMode{};
    vm.enter(24, 80, 10, 5, 0, 0);

    // No selection active
    try std.testing.expectEqual(@as(?@import("Selection.zig"), null), vm.toSelection(0, 0));

    // Activate selection and move
    vm.selection_active = true;
    vm.selection_start_row = 10;
    vm.selection_start_col = 5;
    vm.cursor_row = 12;
    vm.cursor_col = 20;

    const sel = vm.toSelection(0, 0).?;
    try std.testing.expect(sel.active);
    try std.testing.expectEqual(@as(u32, 10), sel.start_row);
    try std.testing.expectEqual(@as(u16, 5), sel.start_col);
    try std.testing.expectEqual(@as(u32, 12), sel.end_row);
    try std.testing.expectEqual(@as(u16, 20), sel.end_col);
}

test "ViMode half-page movement" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 12, 0, 0, 100);
    var scroll: u32 = 0;

    // Ctrl+D: half page down
    _ = vm.handleKey(0x04, &grid, &scroll, 100);
    try std.testing.expectEqual(@as(u32, 124), vm.cursor_row); // 112 + 12 = clamped to 123

    // Reset
    vm.cursor_row = 112;
    // Ctrl+U: half page up
    _ = vm.handleKey(0x15, &grid, &scroll, 100);
    try std.testing.expectEqual(@as(u32, 100), vm.cursor_row); // 112 - 12
}

test "ViMode keysym arrows" {
    var vm = ViMode{};
    vm.enter(24, 80, 12, 40, 0, 0);
    var scroll: u32 = 0;

    // Left arrow
    _ = vm.handleKeysym(0xff51, &scroll, 0);
    try std.testing.expectEqual(@as(u16, 39), vm.cursor_col);

    // Right arrow
    _ = vm.handleKeysym(0xff53, &scroll, 0);
    try std.testing.expectEqual(@as(u16, 40), vm.cursor_col);

    // Up arrow
    _ = vm.handleKeysym(0xff52, &scroll, 0);
    try std.testing.expectEqual(@as(u32, 11), vm.cursor_row);

    // Down arrow
    _ = vm.handleKeysym(0xff54, &scroll, 0);
    try std.testing.expectEqual(@as(u32, 12), vm.cursor_row);

    // Escape
    try std.testing.expectEqual(ViMode.Action.exit, vm.handleKeysym(0xff1b, &scroll, 0));
}

test "ViMode boundary clamping" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 24, 80);
    defer grid.deinit(allocator);

    var vm = ViMode{};
    vm.enter(24, 80, 0, 0, 0, 0);
    var scroll: u32 = 0;

    // Move left at col 0 — should stay
    _ = vm.handleKey('h', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u16, 0), vm.cursor_col);

    // Move up at row 0 — should stay
    _ = vm.handleKey('k', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u32, 0), vm.cursor_row);

    // Move to bottom-right corner
    vm.cursor_row = 23;
    vm.cursor_col = 79;
    _ = vm.handleKey('l', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u16, 79), vm.cursor_col);
    _ = vm.handleKey('j', &grid, &scroll, 0);
    try std.testing.expectEqual(@as(u32, 23), vm.cursor_row);
}
