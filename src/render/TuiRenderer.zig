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
const LeaderKey = @import("../config/LeaderKey.zig");

const Self = @This();

screen: *TuiScreen,
allocator: Allocator,
daemon_fd: posix.fd_t,
/// Gap (in cells) between panes + screen edge; set from teru.conf
/// (`tui_pane_gap`). The mouse hit-test in modes/tui.zig reads this same field
/// so click geometry stays identical to render geometry.
pane_gap: u16 = default_pane_gap,
/// Track last-sent pane sizes to avoid redundant resizes
last_pane_sizes: [64]PaneSize = @splat(.{}),
last_pane_count: usize = 0,

const PaneSize = struct { id: u64 = 0, rows: u16 = 0, cols: u16 = 0 };

/// Default gap (in cells) between tiled panes and between panes and the screen
/// edge. 0 = panes touch (borders adjacent). Overridable per-instance via the
/// `pane_gap` field, set from teru.conf `tui_pane_gap`. Applied as a half-gap
/// pre-inset on the tiling area + a half-gap post-inset on each pane, so
/// inter-pane and edge spacing both equal `2 * pane_gap`.
pub const default_pane_gap: u16 = 0;

// Border colors (ANSI indexed)
const border_active: Color = .{ .rgb = .{ .r = 0xFF, .g = 0x98, .b = 0x37 } }; // miozu orange #FF9837
// Dim ring on unfocused panes so multiple panes read as distinct frames (the
// content is already inset by 1 for every pane, so this never reflows on focus).
const border_inactive: Color = .{ .rgb = .{ .r = 0x3a, .g = 0x3d, .b = 0x44 } }; // miozu base02 #3a3d44
// Status bar — themed (miozu) instead of plain black/white so the panel reads
// as a coloured strip, not a monochrome line.
const status_bg: Color = .{ .rgb = .{ .r = 0x2a, .g = 0x2f, .b = 0x3d } }; // base01-ish, lighter than pane bg → distinct strip
const status_fg: Color = .{ .rgb = .{ .r = 0xd0, .g = 0xd2, .b = 0xdb } }; // miozu fg
const status_dim: Color = .{ .rgb = .{ .r = 0x6b, .g = 0x73, .b = 0x89 } }; // muted (base03) — hints / separators
const status_accent: Color = .{ .rgb = .{ .r = 0xff, .g = 0x98, .b = 0x37 } }; // miozu orange (base09)
const status_layout: Color = .{ .indexed = 6 }; // cyan accent (follows the live theme palette)
const status_active_fg: Color = .{ .rgb = .{ .r = 0x23, .g = 0x27, .b = 0x33 } }; // dark text on orange
const status_active_bg: Color = .{ .rgb = .{ .r = 0xff, .g = 0x98, .b = 0x37 } }; // orange highlight for active ws

pub fn init(screen: *TuiScreen, allocator: Allocator, daemon_fd: posix.fd_t) Self {
    return .{ .screen = screen, .allocator = allocator, .daemon_fd = daemon_fd };
}

pub const RenderOpts = struct {
    nested: bool = false,
    prefix_active: bool = false,
    /// Draw the status bar even when nested (TERU_NESTED_BAR=1). Without it,
    /// nested mode drops the bar entirely — fine under an outer teru, but it
    /// leaves no panel at all under teruwm / a plain terminal.
    nested_bar: bool = false,
    /// When non-null AND active, draw the leader/which-key HUD band along the
    /// bottom (above the status row). Client-side overlay — works over SSH.
    leader: ?*const LeaderKey = null,
};

/// Whether to draw the status bar (and reserve its row): always when not
/// nested; when nested, only if the nested-bar opt-in is set.
fn showBar(opts: RenderOpts) bool {
    return !opts.nested or opts.nested_bar;
}

/// Render the active workspace's panes into the TuiScreen and flush to stdout.
pub fn render(self: *Self, mux: *Multiplexer, stdout_fd: i32) void {
    self.renderWithOpts(mux, stdout_fd, .{});
}

/// Render with TUI-specific options (nesting, prefix state).
pub fn renderWithOpts(self: *Self, mux: *Multiplexer, stdout_fd: i32, opts: RenderOpts) void {
    // A 0-width or 0-height screen has nothing to draw and would underflow the
    // `w - 1` / `height - 1` arithmetic below. Happens transiently when a
    // terminal reports a 0x0 winsize (some terminals on first connect / during
    // a resize). Skip the frame rather than panic.
    if (self.screen.width == 0 or self.screen.height == 0) return;
    self.screen.clear();

    const ws = &mux.layout_engine.workspaces[mux.active_workspace];
    const pane_ids = ws.node_ids.items;

    if (pane_ids.len == 0) {
        if (showBar(opts)) self.drawStatusBar(mux, opts);
        _ = self.screen.flush(stdout_fd);
        return;
    }

    // Reserve last row for the status bar — UNLESS nested, where we drop our
    // own status bar (the outer teru already has one) and give the row back to
    // the panes so there's no duplicate bar and no blank gap.
    const content_height = if (showBar(opts))
        (if (self.screen.height > 1) self.screen.height - 1 else self.screen.height)
    else
        self.screen.height;

    const multi_pane = pane_ids.len > 1;

    // Uniform gaps: pre-inset the whole tiling area by `pane_gap` (half-gap), then
    // post-inset every pane rect by `pane_gap` at each use site below. Edge and
    // inter-pane spacing both come out to 2*pane_gap, so panes share equal space
    // AND equal gaps. A single pane keeps the full screen (no chrome, no waste).
    const g: u16 = if (multi_pane) self.pane_gap else 0;

    // Calculate layout rects in character cells (within the gapped tiling area)
    const screen_rect = Rect{
        .x = g,
        .y = g,
        .width = self.screen.width -| (2 *| g),
        .height = content_height -| (2 *| g),
    };

    const rects = mux.layout_engine.calculate(mux.active_workspace, screen_rect) catch {
        // Fallback: single pane fills screen
        if (mux.getActivePane()) |pane| {
            self.screen.stamp(&pane.grid, 0, 0, content_height, self.screen.width);
        }
        if (showBar(opts)) self.drawStatusBar(mux, opts);
        _ = self.screen.flush(stdout_fd);
        return;
    };
    defer self.allocator.free(rects);

    // Resize daemon panes to match layout rects (so grid rows/cols match)
    for (pane_ids, 0..) |pane_id, ri| {
        if (ri >= rects.len) break;
        const rect = Compositor.insetRect(rects[ri], g);
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
                pane.grid.resize(mux.allocator, content_rows, content_cols) catch |e| std.log.warn("local grid resize failed: {s}", .{@errorName(e)});
            }
        }
    }
    // Update cache
    self.last_pane_count = @min(pane_ids.len, self.last_pane_sizes.len);
    for (pane_ids, 0..) |pane_id, ci| {
        if (ci >= self.last_pane_sizes.len or ci >= rects.len) break;
        const rect = Compositor.insetRect(rects[ci], g);
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
        const rect = Compositor.insetRect(rects[i], g);
        const is_active = (ws.active_index == i);

        if (multi_pane) {
            // Content is inset by 1 for ALL panes (whether or not a border is
            // drawn), so focus changes never reflow a pane's geometry.
            const inset = Compositor.insetRect(rect, 1);
            self.screen.stamp(&pane.grid, inset.y, inset.x, inset.height, inset.width);

            // Every pane gets a frame: orange when focused, dim base02 otherwise,
            // so panes are visually separated even before you look for the active
            // one. The 1-cell content inset above is identical for both, so a focus
            // change only recolors the ring — it never reflows pane geometry.
            self.drawPaneBorder(rect, if (is_active) border_active else border_inactive);
        } else {
            // Single pane: no borders, fill entire content area
            self.screen.stamp(&pane.grid, rect.y, rect.x, rect.height, rect.width);
        }
    }

    // Status bar — skipped when nested (the outer teru owns the bar).
    if (showBar(opts)) self.drawStatusBar(mux, opts);

    // Leader / which-key HUD band — overlays the bottom rows while active.
    if (opts.leader) |lk| {
        if (lk.active) self.drawLeaderBand(lk);
    }

    // Flush
    _ = self.screen.flush(stdout_fd);

    // Position cursor at active pane's cursor location
    if (mux.getActivePane()) |pane| {
        const active_idx = ws.active_index;
        if (active_idx < rects.len) {
            const rect = Compositor.insetRect(rects[active_idx], g);
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
/// Draw the leader / which-key HUD as a cell band along the bottom, just above
/// the status row. A cell-based sibling of teruwm's pixel LeaderPanel: breadcrumb
/// inline on row 0, entries flowing after it; sized to the current group (one
/// row when it fits, growing a row at a time). Overlay only — the next frame's
/// screen.clear()+recompose erases it, so dismiss needs no special handling.
fn drawLeaderBand(self: *Self, leader: *const LeaderKey) void {
    const w = self.screen.width;
    const h = self.screen.height;
    if (w == 0 or h <= 1) return;

    // Tightest column width (cells) that fits every entry.
    var slot: u16 = 10;
    for (leader.node) |e| {
        const kw: u16 = if (e.key == ' ') 3 else 1; // "SPC" vs single char
        const ew: u16 = kw + 1 + @as(u16, @intCast(@min(e.label.len, 200))) + 2;
        if (ew > slot) slot = ew;
    }
    const pad_x: u16 = 1;
    const usable: u16 = if (w > pad_x * 2) w - pad_x * 2 else w;
    const cols: u16 = @max(1, usable / slot);

    const hint = if (leader.atRoot()) "(1-9 ws \xc2\xb7 Esc cancel)" else "(Esc back)";
    const crumb = leader.crumb;
    const bc_cells: u16 = @intCast(@min(crumb.len + 1 + hint.len + 2, 80));
    const bc_cols: u16 = @max(1, (bc_cells + slot - 1) / slot);
    const total: u16 = bc_cols + @as(u16, @intCast(@min(leader.node.len, 200)));
    const want_rows: u16 = @max(1, (total + cols - 1) / cols);

    const status_row: u16 = h - 1; // reserve the status row
    const band_h: u16 = @min(want_rows, status_row);
    if (band_h == 0) return;
    const band_top: u16 = status_row - band_h;

    // Background fill.
    var ry: u16 = band_top;
    while (ry < status_row) : (ry += 1) {
        var cx: u16 = 0;
        while (cx < w) : (cx += 1) self.screen.setCell(ry, cx, ' ', status_fg, status_bg, .{});
    }

    // Breadcrumb (accent) + hint (dim) on the first band row.
    var col: u16 = pad_x;
    for (crumb) |ch| {
        if (col >= w) break;
        self.screen.setCell(band_top, col, ch, status_accent, status_bg, .{ .bold = true });
        col += 1;
    }
    col += 1;
    for (hint) |ch| {
        if (col >= w) break;
        self.screen.setCell(band_top, col, ch, status_dim, status_bg, .{});
        col += 1;
    }

    // Entries flow after the breadcrumb's column span.
    for (leader.node, 0..) |e, idx| {
        const slot_idx: u16 = bc_cols + @as(u16, @intCast(idx));
        const c: u16 = slot_idx % cols;
        const r: u16 = slot_idx / cols;
        if (r >= band_h) break;
        var x: u16 = pad_x + c * slot;
        const ey: u16 = band_top + r;
        if (e.key == ' ') {
            for ("SPC") |ch| {
                if (x >= w) break;
                self.screen.setCell(ey, x, ch, status_accent, status_bg, .{ .bold = true });
                x += 1;
            }
            x += 1;
        } else {
            if (x < w) {
                self.screen.setCell(ey, x, e.key, status_accent, status_bg, .{ .bold = true });
                x += 1;
            }
            x += 1;
        }
        for (e.label) |ch| {
            if (x >= w) break;
            self.screen.setCell(ey, x, ch, status_fg, status_bg, .{});
            x += 1;
        }
    }
}

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
        if (col >= w -| 1) break; // saturating: w may be 0
        self.screen.setCell(row, col, ch, status_layout, status_bg, .{ .bold = true });
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
        // Nested prefix is Ctrl+A (the outer/host owns Ctrl+B), so show C-a.
        const hint = " C-a:prefix ";
        for (hint) |ch| {
            if (col >= w - 1) break;
            self.screen.setCell(row, col, ch, status_dim, status_bg, .{});
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
                self.screen.setCell(row, rc, ch, status_accent, status_bg, .{ .bold = true });
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
