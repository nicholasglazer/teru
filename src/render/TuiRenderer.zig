//! TuiRenderer: stamps pane Grids into a TuiScreen and flushes to stdout.
//!
//! Renders teru's full multiplexer experience as ANSI escape sequences:
//! - Multi-pane tiling layouts (all 8 layouts, cell_width=1)
//! - Pane borders with Unicode box-drawing characters
//! - Status bar with workspace indicators, layout name, session info
//! - Diff-based output — only changed cells are re-emitted

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const TuiScreen = @import("TuiScreen.zig");
const Grid = @import("../core/Grid.zig");
const Color = Grid.Color;
const Multiplexer = @import("../core/Multiplexer.zig");
const LayoutEngine = @import("../tiling/LayoutEngine.zig");
const Rect = LayoutEngine.Rect;
const Compositor = @import("Compositor.zig");
const daemon_proto = @import("../server/protocol.zig");

const Self = @This();

screen: *TuiScreen,
allocator: Allocator,
daemon_fd: posix.fd_t,
/// Track last-sent pane sizes to avoid redundant resizes
last_pane_sizes: [64]PaneSize = .{PaneSize{}} ** 64,
last_pane_count: usize = 0,

const PaneSize = struct { id: u64 = 0, rows: u16 = 0, cols: u16 = 0 };

// Border colors (ANSI indexed)
const border_active: Color = .{ .rgb = .{ .r = 0xFF, .g = 0x98, .b = 0x37 } }; // miozu orange #FF9837
const border_inactive: Color = .{ .indexed = 240 }; // dark gray (visible on dark bg)
const status_fg: Color = .{ .indexed = 7 }; // white
const status_bg: Color = .{ .indexed = 0 }; // black
const status_active_fg: Color = .{ .indexed = 0 }; // black on yellow
const status_active_bg: Color = .{ .indexed = 3 }; // yellow

pub fn init(screen: *TuiScreen, allocator: Allocator, daemon_fd: posix.fd_t) Self {
    return .{ .screen = screen, .allocator = allocator, .daemon_fd = daemon_fd };
}

pub const RenderOpts = struct {
    nested: bool = false,
    prefix_active: bool = false,
};

/// Render the active workspace's panes into the TuiScreen and flush to stdout.
pub fn render(self: *Self, mux: *Multiplexer, stdout_fd: i32) void {
    self.renderWithOpts(mux, stdout_fd, .{});
}

/// Render with TUI-specific options (nesting, prefix state).
pub fn renderWithOpts(self: *Self, mux: *Multiplexer, stdout_fd: i32, opts: RenderOpts) void {
    self.screen.clear();

    const ws = &mux.layout_engine.workspaces[mux.active_workspace];
    const pane_ids = ws.node_ids.items;

    if (pane_ids.len == 0) {
        self.drawStatusBar(mux, opts);
        _ = self.screen.flush(stdout_fd);
        return;
    }

    // Reserve last row for status bar
    const content_height = if (self.screen.height > 1) self.screen.height - 1 else self.screen.height;

    // Calculate layout rects in character cells
    const screen_rect = Rect{
        .x = 0,
        .y = 0,
        .width = self.screen.width,
        .height = content_height,
    };

    const rects = mux.layout_engine.calculate(mux.active_workspace, screen_rect) catch {
        // Fallback: single pane fills screen
        if (mux.getActivePane()) |pane| {
            self.screen.stamp(&pane.grid, 0, 0, content_height, self.screen.width);
        }
        self.drawStatusBar(mux, opts);
        _ = self.screen.flush(stdout_fd);
        return;
    };
    defer self.allocator.free(rects);

    const multi_pane = pane_ids.len > 1;

    // Resize daemon panes to match layout rects (so grid rows/cols match)
    for (pane_ids, 0..) |pane_id, ri| {
        if (ri >= rects.len) break;
        const rect = rects[ri];
        // Content area: inset by 1 for borders if multi-pane
        const content_rows = if (multi_pane and rect.height > 2) rect.height - 2 else rect.height;
        const content_cols = if (multi_pane and rect.width > 2) rect.width - 2 else rect.width;

        // Only send resize if dimensions changed
        var needs_resize = true;
        for (self.last_pane_sizes[0..self.last_pane_count]) |ps| {
            if (ps.id == pane_id and ps.rows == content_rows and ps.cols == content_cols) {
                needs_resize = false;
                break;
            }
        }
        if (needs_resize and content_rows > 0 and content_cols > 0) {
            // Send pane-specific resize: [pane_id:8][rows:2][cols:2]
            var resize_buf: [12]u8 = undefined;
            std.mem.writeInt(u64, resize_buf[0..8], pane_id, .little);
            const resize_data = daemon_proto.encodeResize(content_rows, content_cols);
            @memcpy(resize_buf[8..12], &resize_data);
            _ = daemon_proto.sendMessage(self.daemon_fd, .resize, &resize_buf);

            // Also resize local grid to match
            if (mux.getPaneById(pane_id)) |pane| {
                pane.grid.resize(mux.allocator, content_rows, content_cols) catch {};
            }
        }
    }
    // Update cache
    self.last_pane_count = @min(pane_ids.len, self.last_pane_sizes.len);
    for (pane_ids, 0..) |pane_id, ci| {
        if (ci >= self.last_pane_sizes.len or ci >= rects.len) break;
        const rect = rects[ci];
        self.last_pane_sizes[ci] = .{
            .id = pane_id,
            .rows = if (multi_pane and rect.height > 2) rect.height - 2 else rect.height,
            .cols = if (multi_pane and rect.width > 2) rect.width - 2 else rect.width,
        };
    }

    // Stamp each pane's grid into its layout rect
    for (pane_ids, 0..) |pane_id, i| {
        if (i >= rects.len) break;
        const pane = mux.getPaneById(pane_id) orelse continue;
        const rect = rects[i];
        const is_active = (ws.active_index == i);

        if (multi_pane) {
            // Inset by 1 for borders
            const inset = Compositor.insetRect(rect, 1);
            self.screen.stamp(&pane.grid, inset.y, inset.x, inset.height, inset.width);

            // Draw border
            const color = if (is_active) border_active else border_inactive;
            self.drawPaneBorder(rect, color);
        } else {
            // Single pane: no borders, fill entire content area
            self.screen.stamp(&pane.grid, rect.y, rect.x, rect.height, rect.width);
        }
    }

    // Status bar
    self.drawStatusBar(mux, opts);

    // Flush
    _ = self.screen.flush(stdout_fd);

    // Position cursor at active pane's cursor location
    if (mux.getActivePane()) |pane| {
        const active_idx = ws.active_index;
        if (active_idx < rects.len) {
            const rect = rects[active_idx];
            if (multi_pane) {
                const inset = Compositor.insetRect(rect, 1);
                const cursor_row = inset.y + @min(pane.grid.cursor_row, inset.height -| 1);
                const cursor_col = inset.x + @min(pane.grid.cursor_col, inset.width -| 1);
                self.screen.setCursorPosition(cursor_row, cursor_col, stdout_fd);
            } else {
                const cursor_row = rect.y + @min(pane.grid.cursor_row, rect.height -| 1);
                const cursor_col = rect.x + @min(pane.grid.cursor_col, rect.width -| 1);
                self.screen.setCursorPosition(cursor_row, cursor_col, stdout_fd);
            }
        }
    }
}

/// Draw a Unicode box border around a rect.
fn drawPaneBorder(self: *Self, rect: Rect, color: Color) void {
    const x1 = rect.x;
    const y1 = rect.y;
    const x2 = rect.x + rect.width -| 1;
    const y2 = rect.y + rect.height -| 1;

    if (rect.width < 3 or rect.height < 3) return;

    // Corners
    self.screen.setCell(y1, x1, 0x250C, color, .default, .{}); // ┌
    self.screen.setCell(y1, x2, 0x2510, color, .default, .{}); // ┐
    self.screen.setCell(y2, x1, 0x2514, color, .default, .{}); // └
    self.screen.setCell(y2, x2, 0x2518, color, .default, .{}); // ┘

    // Horizontal lines (top and bottom)
    var c = x1 + 1;
    while (c < x2) : (c += 1) {
        self.screen.setCell(y1, c, 0x2500, color, .default, .{}); // ─
        self.screen.setCell(y2, c, 0x2500, color, .default, .{}); // ─
    }

    // Vertical lines (left and right)
    var r = y1 + 1;
    while (r < y2) : (r += 1) {
        self.screen.setCell(r, x1, 0x2502, color, .default, .{}); // │
        self.screen.setCell(r, x2, 0x2502, color, .default, .{}); // │
    }
}

/// Draw the status bar on the last row.
fn drawStatusBar(self: *Self, mux: *Multiplexer, opts: RenderOpts) void {
    const row = self.screen.height -| 1;
    const w = self.screen.width;

    // Fill status bar background
    for (0..w) |col| {
        self.screen.setCell(row, @intCast(col), ' ', status_fg, status_bg, .{});
    }

    var col: u16 = 1; // start with 1-char padding

    // Workspace indicators: [1] 2 3 ...
    for (0..10) |wi| {
        if (col + 3 >= w) break;
        const ws = &mux.layout_engine.workspaces[wi];
        const has_panes = ws.node_ids.items.len > 0;
        const is_active = (wi == mux.active_workspace);

        if (is_active) {
            // Active workspace: highlighted
            self.screen.setCell(row, col, '[', status_active_fg, status_active_bg, .{});
            col += 1;
            self.screen.setCell(row, col, '0' + @as(u21, @intCast(if (wi == 9) 0 else wi + 1)), status_active_fg, status_active_bg, .{ .bold = true });
            col += 1;
            self.screen.setCell(row, col, ']', status_active_fg, status_active_bg, .{});
            col += 1;
        } else if (has_panes) {
            // Occupied workspace: shown dimly
            self.screen.setCell(row, col, ' ', status_fg, status_bg, .{});
            col += 1;
            self.screen.setCell(row, col, '0' + @as(u21, @intCast(if (wi == 9) 0 else wi + 1)), status_fg, status_bg, .{});
            col += 1;
            self.screen.setCell(row, col, ' ', status_fg, status_bg, .{});
            col += 1;
        }
        // Empty workspaces: skip entirely
    }

    // Separator
    col += 1;

    // Layout name
    const layout = mux.layout_engine.workspaces[mux.active_workspace].layout;
    const layout_name = layout.name();
    for (layout_name) |ch| {
        if (col >= w - 1) break;
        self.screen.setCell(row, col, ch, status_fg, status_bg, .{});
        col += 1;
    }

    // Prefix mode indicator
    if (opts.prefix_active) {
        col += 1;
        const prefix_str = " [PREFIX] ";
        for (prefix_str) |ch| {
            if (col >= w - 1) break;
            self.screen.setCell(row, col, ch, status_active_fg, status_active_bg, .{ .bold = true });
            col += 1;
        }
    } else if (opts.nested) {
        col += 1;
        const hint = " C-b:prefix ";
        for (hint) |ch| {
            if (col >= w - 1) break;
            self.screen.setCell(row, col, ch, .{ .indexed = 8 }, status_bg, .{});
            col += 1;
        }
    }

    // Right side: pane count
    const pane_count = mux.layout_engine.workspaces[mux.active_workspace].node_ids.items.len;
    if (pane_count > 0 and w > 20) {
        // Format: "N panes" right-aligned
        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d} pane{s}", .{
            pane_count,
            if (pane_count == 1) "" else "s",
        }) catch "";

        const right_start = w -| @as(u16, @intCast(count_str.len)) -| 1;
        for (count_str, 0..) |ch, ci| {
            const rc = right_start + @as(u16, @intCast(ci));
            if (rc < w) {
                self.screen.setCell(row, rc, ch, status_fg, status_bg, .{});
            }
        }
    }
}

/// Force a full redraw on the next render (e.g. after resize).
pub fn invalidate(self: *Self) void {
    self.screen.full_dirty = true;
}

// ── Tests ────────────────────────────────────────────────────────

test "TuiRenderer: init" {
    const allocator = std.testing.allocator;
    var screen = try TuiScreen.init(allocator, 24, 80);
    defer screen.deinit(allocator);

    const renderer = init(&screen, allocator, -1);
    _ = renderer;
}

test "TuiRenderer: drawPaneBorder" {
    const allocator = std.testing.allocator;
    var screen = try TuiScreen.init(allocator, 24, 80);
    defer screen.deinit(allocator);

    var renderer = init(&screen, allocator, -1);
    const rect = Rect{ .x = 0, .y = 0, .width = 10, .height = 5 };
    renderer.drawPaneBorder(rect, border_active);

    // Check corners
    try std.testing.expectEqual(@as(u21, 0x250C), screen.cells[0].char); // top-left ┌
    try std.testing.expectEqual(@as(u21, 0x2510), screen.cells[9].char); // top-right ┐
    try std.testing.expectEqual(@as(u21, 0x2514), screen.cells[4 * 80].char); // bottom-left └
    try std.testing.expectEqual(@as(u21, 0x2518), screen.cells[4 * 80 + 9].char); // bottom-right ┘

    // Check horizontal line
    try std.testing.expectEqual(@as(u21, 0x2500), screen.cells[1].char); // ─

    // Check vertical line
    try std.testing.expectEqual(@as(u21, 0x2502), screen.cells[1 * 80].char); // │
}

test "TuiRenderer: drawStatusBar" {
    const allocator = std.testing.allocator;
    var screen = try TuiScreen.init(allocator, 24, 80);
    defer screen.deinit(allocator);

    var renderer = init(&screen, allocator, -1);
    var mux = Multiplexer.init(allocator);
    defer mux.deinit();

    renderer.drawStatusBar(&mux, .{});

    // Status bar is on last row (row 23)
    // Should have workspace indicator [1] since ws 0 is active
    const row_start = 23 * 80;
    // First char is padding space, then [1]
    try std.testing.expectEqual(@as(u21, '['), screen.cells[row_start + 1].char);
    try std.testing.expectEqual(@as(u21, '1'), screen.cells[row_start + 2].char);
    try std.testing.expectEqual(@as(u21, ']'), screen.cells[row_start + 3].char);
}
