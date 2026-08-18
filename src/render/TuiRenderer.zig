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
const Config = @import("../config/Config.zig");
const VtParser = @import("../core/VtParser.zig");
const Pane = @import("../core/Pane.zig");
const Selection = @import("../core/Selection.zig");

const Self = @This();

screen: *TuiScreen,
allocator: Allocator,
daemon_fd: posix.fd_t,
/// Gap (in cells) between panes + screen edge; set from teru.conf
/// (`tui_pane_gap`). The mouse hit-test in modes/tui.zig reads this same field
/// so click geometry stays identical to render geometry.
pane_gap: u16 = default_pane_gap,
/// How panes are separated when more than one is visible; set from teru.conf
/// (`tui_pane_border`). See Config.PaneBorder — `.box` frames every pane,
/// `.line` draws one shared separator per boundary, `.none` reclaims every
/// cell and lets neighbours touch.
pane_border: Config.PaneBorder = .box,
/// Track last-sent pane sizes to avoid redundant resizes
last_pane_sizes: [64]PaneSize = @splat(.{}),
last_pane_count: usize = 0,
/// Active mouse selection and the pane it belongs to, set by the TUI loop
/// before each render. Only one pane is ever selecting at a time. Null = no
/// selection; the renderer paints the plain scrolled view.
selection: ?*const Selection = null,
selection_pane_id: u64 = 0,

const PaneSize = struct { id: u64 = 0, rows: u16 = 0, cols: u16 = 0 };

/// Default gap (in cells) between tiled panes and between panes and the screen
/// edge. 0 = panes touch (borders adjacent). Overridable per-instance via the
/// `pane_gap` field, set from teru.conf `tui_pane_gap`. Applied as a half-gap
/// pre-inset on the tiling area + a half-gap post-inset on each pane, so
/// inter-pane and edge spacing both equal `2 * pane_gap`.
pub const default_pane_gap: u16 = 0;

/// Cells a pane surrenders on each side to whatever separates it.
///
/// Per-side rather than a single number because `line` mode is asymmetric: a
/// pane gives up a column only on the sides where it actually has a neighbour,
/// and nothing at the screen edge.
pub const PaneFrame = struct {
    left: u16 = 0,
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,

    pub fn horizontal(self: PaneFrame) u16 {
        return self.left +| self.right;
    }
    pub fn vertical(self: PaneFrame) u16 {
        return self.top +| self.bottom;
    }
};

/// What `raw` (a pane's slice of `area`, before any gap inset) gives up.
///
/// Every site that splits a pane rect into frame + content derives from this:
/// the resize sent to the daemon, the cache that suppresses redundant resizes,
/// the grid stamp, and the cursor placement. They must agree exactly — a
/// mismatch resizes the shell to one geometry and draws it at another, so
/// output wraps at the wrong column and the cursor sits a cell off.
///
/// A lone pane is never separated from anything, so it always keeps the whole
/// rect — no chrome, no waste — and the setting only bites once a second pane
/// exists.
pub fn paneFrame(mode: Config.PaneBorder, multi_pane: bool, raw: Rect, area: Rect) PaneFrame {
    if (!multi_pane) return .{};
    return switch (mode) {
        .none => .{},
        .box => .{ .left = 1, .top = 1, .right = 1, .bottom = 1 },
        // Own the separator on the sides that face another pane. The layout
        // engine tiles `area` exactly, so "my right edge is short of the
        // area's right edge" is precisely "someone is over there". Each
        // boundary is therefore drawn once, by the pane on its left/top —
        // which is what makes this cost 1 cell between neighbours instead of
        // box mode's 2, with none spent at the screen edge.
        .line => .{
            .right = if (raw.x +| raw.width < area.x +| area.width) 1 else 0,
            .bottom = if (raw.y +| raw.height < area.y +| area.height) 1 else 0,
        },
    };
}

pub const Axis = enum { vertical, horizontal };

/// Whether a separator segment borders the focused pane.
///
/// `at` is the separator's fixed coordinate (its column when vertical, its row
/// when horizontal); `span_start`/`span_len` describe its extent along the
/// other axis.
///
/// A boundary counts as active when the focused pane lies on EITHER side of it:
/// `at` is the cell just left/above the focused rect, or the focused rect's own
/// last column/row. Both are needed — colouring only the owner's side made the
/// highlight depend on which pane of a pair you focused, since the left/top one
/// always draws the shared line. The span overlap keeps a distant separator on
/// the same column from lighting up in a multi-row layout.
pub fn touchesActive(active: ?Rect, axis: Axis, at: u16, span_start: u16, span_len: u16) bool {
    const a = active orelse return false;
    const span_end = span_start +| span_len;
    return switch (axis) {
        .vertical => blk: {
            if (!(span_start < a.y +| a.height and a.y < span_end)) break :blk false;
            // `a.x > 0` guards the saturating subtraction: a pane flush to the
            // left edge has no boundary to its left to light up.
            break :blk (a.x > 0 and at == a.x - 1) or at == a.x +| a.width -| 1;
        },
        .horizontal => blk: {
            if (!(span_start < a.x +| a.width and a.x < span_end)) break :blk false;
            break :blk (a.y > 0 and at == a.y - 1) or at == a.y +| a.height -| 1;
        },
    };
}

/// Shrink `rect` by a per-side frame, saturating so a rect too small to hold
/// its own separator collapses to zero rather than wrapping around.
pub fn insetByFrame(rect: Rect, f: PaneFrame) Rect {
    return .{
        .x = rect.x +| f.left,
        .y = rect.y +| f.top,
        .width = rect.width -| f.horizontal(),
        .height = rect.height -| f.vertical(),
    };
}

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
        // Content area: the rect minus whatever separates this pane. Saturating
        // (insetByFrame clamps to 0) rather than falling back to the full
        // extent — a rect too small to hold its own separator, like the 2-cell
        // rows a crowded master-stack hands out, would otherwise resize the
        // shell to 2 rows while the stamp draws 0, leaving the pane blank while
        // its shell believes it has room.
        const frame = paneFrame(self.pane_border, multi_pane, rects[ri], screen_rect);
        const content_rows = rect.height -| frame.vertical();
        const content_cols = rect.width -| frame.horizontal();

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
        const frame = paneFrame(self.pane_border, multi_pane, rects[ci], screen_rect);
        self.last_pane_sizes[ci] = .{
            .id = pane_id,
            .rows = rect.height -| frame.vertical(),
            .cols = rect.width -| frame.horizontal(),
        };
    }

    // The focused pane's rect, so a separator can ask whether it touches it.
    const active_rect: ?Rect = if (ws.active_index < rects.len)
        Compositor.insetRect(rects[ws.active_index], g)
    else
        null;

    // Stamp each pane's grid into its layout rect
    for (pane_ids, 0..) |pane_id, i| {
        if (i >= rects.len) break;
        const pane = mux.getPaneById(pane_id) orelse continue;
        const rect = Compositor.insetRect(rects[i], g);
        const is_active = (ws.active_index == i);

        const frame = paneFrame(self.pane_border, multi_pane, rects[i], screen_rect);
        const inset = insetByFrame(rect, frame);

        // The inset is identical whether or not this pane is focused, so a
        // focus change only recolours the chrome — it never reflows geometry.
        const sel: ?*const Selection = if (self.selection) |s|
            (if (pane_id == self.selection_pane_id) s else null)
        else
            null;
        self.stampPaneView(pane, inset, sel);

        switch (self.pane_border) {
            .none => {},
            .box => self.drawPaneBorder(rect, if (is_active) border_active else border_inactive),
            // Each boundary is drawn once, by the pane on its left or top — but
            // it is coloured by whether it TOUCHES the focused pane, not by who
            // draws it. Ownership is layout bookkeeping; highlighting by it made
            // the cue depend on which side of a pair you happened to focus (the
            // right pane of two left its divider dim, because the left one drew
            // it). "Active wins" is what tmux, zellij and kitty all settle on.
            .line => {
                if (frame.right > 0) {
                    const x = rect.x +| rect.width -| 1;
                    self.drawVLine(x, rect.y, rect.height, if (touchesActive(active_rect, .vertical, x, rect.y, rect.height))
                        border_active
                    else
                        border_inactive);
                }
                if (frame.bottom > 0) {
                    const y = rect.y +| rect.height -| 1;
                    self.drawHLine(y, rect.x, rect.width, if (touchesActive(active_rect, .horizontal, y, rect.x, rect.width))
                        border_active
                    else
                        border_inactive);
                }
            },
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
            const frame = paneFrame(self.pane_border, multi_pane, rects[active_idx], screen_rect);
            const inset = insetByFrame(rect, frame);
            const cursor_row = inset.y + @min(pane.grid.cursor_row, inset.height -| 1);
            const cursor_col = inset.x + @min(pane.grid.cursor_col, inset.width -| 1);
            self.screen.setCursorPosition(cursor_row, cursor_col, stdout_fd);
        }
    }
}

/// Stamp a pane's viewport into `inset`, accounting for scrollback position and
/// painting the selection highlight. When `pane.scroll_offset == 0` and there's
/// no selection this is the plain fast path (stamp the live grid). Otherwise it
/// composites the viewport row by row: rows below the scroll point come from the
/// live grid; rows above it are reconstructed from scrollback deltas.
///
/// The virtual line for viewport row r is `r - scroll_offset`: ≥0 indexes the
/// grid, <0 indexes scrollback at offset `-(virt) - 1` (0 = newest). This is the
/// cell-grid analogue of Ui.renderScrollOverlay (the pixel path) — same mapping,
/// same getLineByOffset source, so scrolled content matches what teruwm shows.
fn stampPaneView(self: *Self, pane: *Pane, inset: Rect, sel: ?*const Selection) void {
    const so = pane.scroll_offset;
    if (so == 0 and sel == null) {
        self.screen.stamp(&pane.grid, inset.y, inset.x, inset.height, inset.width);
        return;
    }

    const sb = pane.grid.scrollback;
    const sb_lines: u32 = if (sb) |s| @intCast(s.lineCount()) else 0;

    // A 1-row scratch grid+parser reconstructs each scrollback line's cells by
    // replaying its stored VT bytes. Created only while scrolled; a failure
    // degrades to the live-grid stamp rather than crashing.
    var scratch: ?Grid = if (so > 0 and sb != null)
        (Grid.init(self.allocator, 1, pane.grid.cols) catch null)
    else
        null;
    defer if (scratch) |*g| g.deinit(self.allocator);
    var parser: ?VtParser = if (scratch) |*g| VtParser.init(self.allocator, g) else null;

    var r: u16 = 0;
    while (r < inset.height) : (r += 1) {
        const screen_row = inset.y + r;
        const virt: i32 = @as(i32, @intCast(r)) - @as(i32, @intCast(so));
        // `r` IS the Selection "screen row" (viewport row from the top);
        // isSelected does the scroll_offset/sb_lines → absolute conversion.
        if (virt >= 0) {
            const grow: u16 = @intCast(virt);
            if (grow >= pane.grid.rows) {
                self.screen.blankRow(screen_row, inset.x, inset.width);
                continue;
            }
            self.stampRowMaybeSel(&pane.grid, grow, screen_row, inset.x, inset.width, sel, r, so, sb_lines);
        } else if (scratch != null and parser != null) {
            const off: u32 = @intCast(-virt - 1); // 0 = newest scrollback line
            if (off >= sb_lines) {
                self.screen.blankRow(screen_row, inset.x, inset.width);
                continue;
            }
            const bytes = sb.?.getLineByOffset(off) orelse {
                self.screen.blankRow(screen_row, inset.x, inset.width);
                continue;
            };
            // Reset the scratch row (home, clear line, clean pen), then replay
            // the line so its SGR/unicode reconstruct exactly.
            parser.?.feed("\x1b[H\x1b[2K\x1b[0m");
            parser.?.feed(bytes);
            self.stampRowMaybeSel(&scratch.?, 0, screen_row, inset.x, inset.width, sel, r, so, sb_lines);
        } else {
            self.screen.blankRow(screen_row, inset.x, inset.width);
        }
    }
}

/// Stamp one source row. No selection → one fast whole-row copy. With a
/// selection active, go cell-by-cell inverting selected cells (one isSelected
/// call per cell is negligible at TUI scale, and only runs while a drag is live).
fn stampRowMaybeSel(self: *Self, grid: *const Grid, src_row: u16, screen_row: u16, screen_col: u16, cols: u16, sel: ?*const Selection, view_row: u16, so: u32, sb_lines: u32) void {
    const s = sel orelse {
        self.screen.stampRow(grid, src_row, screen_row, screen_col, cols, false);
        return;
    };
    const n = @min(@as(usize, cols), @as(usize, grid.cols));
    var col: usize = 0;
    while (col < n) : (col += 1) {
        const inv = s.isSelected(view_row, @intCast(col), so, sb_lines);
        self.screen.stampRow(grid, src_row, screen_row, @intCast(@as(usize, screen_col) + col), 1, inv);
    }
}

/// One vertical separator column, `height` cells tall from `y`.
fn drawVLine(self: *Self, x: u16, y: u16, height: u16, color: Color) void {
    var r = y;
    const end = y +| height;
    while (r < end) : (r += 1) self.screen.setCell(r, x, 0x2502, color, .default, .{}); // │
}

/// One horizontal separator row, `width` cells wide from `x`.
fn drawHLine(self: *Self, y: u16, x: u16, width: u16, color: Color) void {
    var c = x;
    const end = x +| width;
    while (c < end) : (c += 1) self.screen.setCell(y, c, 0x2500, color, .default, .{}); // ─
}

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

test "TuiRenderer: paneFrame — a lone pane is never separated from anything" {
    const area = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const full = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    inline for (.{ Config.PaneBorder.box, .line, .none }) |mode| {
        const f = paneFrame(mode, false, full, area);
        try std.testing.expectEqual(@as(u16, 0), f.horizontal());
        try std.testing.expectEqual(@as(u16, 0), f.vertical());
    }
}

test "TuiRenderer: paneFrame — box frames all four sides, none frames nothing" {
    const area = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const left = Rect{ .x = 0, .y = 0, .width = 40, .height = 24 };

    const box = paneFrame(.box, true, left, area);
    try std.testing.expectEqual(@as(u16, 2), box.horizontal());
    try std.testing.expectEqual(@as(u16, 2), box.vertical());

    const none = paneFrame(.none, true, left, area);
    try std.testing.expectEqual(@as(u16, 0), none.horizontal());
    try std.testing.expectEqual(@as(u16, 0), none.vertical());
}

test "TuiRenderer: paneFrame — line separates only where a neighbour exists" {
    const area = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    // Two panes side by side. The left one owns the boundary; the right one
    // touches the screen edge and so spends nothing.
    const left = Rect{ .x = 0, .y = 0, .width = 40, .height = 24 };
    const right = Rect{ .x = 40, .y = 0, .width = 40, .height = 24 };

    const lf = paneFrame(.line, true, left, area);
    try std.testing.expectEqual(@as(u16, 1), lf.right);
    try std.testing.expectEqual(@as(u16, 0), lf.left);
    try std.testing.expectEqual(@as(u16, 0), lf.vertical());

    const rf = paneFrame(.line, true, right, area);
    try std.testing.expectEqual(@as(u16, 0), rf.horizontal());
    try std.testing.expectEqual(@as(u16, 0), rf.vertical());

    // One boundary, drawn once: 1 cell total between neighbours, versus box's
    // 2, and nothing wasted at the screen edge.
    try std.testing.expectEqual(@as(u16, 1), lf.horizontal() + rf.horizontal());
    const bl = paneFrame(.box, true, left, area);
    const br = paneFrame(.box, true, right, area);
    try std.testing.expectEqual(@as(u16, 4), bl.horizontal() + br.horizontal());
}

test "TuiRenderer: paneFrame — line detects a neighbour below" {
    const area = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const top = Rect{ .x = 0, .y = 0, .width = 80, .height = 12 };
    const bottom = Rect{ .x = 0, .y = 12, .width = 80, .height = 12 };

    try std.testing.expectEqual(@as(u16, 1), paneFrame(.line, true, top, area).bottom);
    try std.testing.expectEqual(@as(u16, 0), paneFrame(.line, true, bottom, area).bottom);
}

test "TuiRenderer: insetByFrame collapses a rect too small to hold its separator" {
    // A crowded master-stack hands out 2-cell-tall rects. The content must
    // collapse to 0 rather than wrap — reporting the full height would resize
    // the shell to rows nothing will ever draw.
    const area = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const tiny = Rect{ .x = 0, .y = 0, .width = 2, .height = 2 };
    const f = paneFrame(.box, true, tiny, area);

    const inset = insetByFrame(tiny, f);
    try std.testing.expectEqual(@as(u16, 0), inset.height);
    try std.testing.expectEqual(@as(u16, 0), inset.width);
    // The resize sites compute the same numbers from the same frame.
    try std.testing.expectEqual(inset.height, tiny.height -| f.vertical());
    try std.testing.expectEqual(inset.width, tiny.width -| f.horizontal());
}

test "TuiRenderer: pane_border defaults to box" {
    const allocator = std.testing.allocator;
    var screen = try TuiScreen.init(allocator, 24, 80);
    defer screen.deinit(allocator);

    const renderer = init(&screen, allocator, -1);
    try std.testing.expectEqual(Config.PaneBorder.box, renderer.pane_border);
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

test "TuiRenderer: a divider highlights from EITHER side of the focused pane" {
    // Two panes side by side in an 80-wide area. The left owns the boundary at
    // column 39; the right begins at 40.
    const left = Rect{ .x = 0, .y = 0, .width = 40, .height = 24 };
    const right = Rect{ .x = 40, .y = 0, .width = 40, .height = 24 };
    const boundary: u16 = 39; // left.x + left.width - 1

    // Focus the OWNER: highlighted, as before.
    try std.testing.expect(touchesActive(left, .vertical, boundary, left.y, left.height));

    // Focus the NEIGHBOUR: still highlighted. This is the regression — the
    // divider went dim whenever the right pane of a pair held focus, because
    // the left pane drew it.
    try std.testing.expect(touchesActive(right, .vertical, boundary, left.y, left.height));

    // Nothing focused at all.
    try std.testing.expect(!touchesActive(null, .vertical, boundary, left.y, left.height));
}

test "TuiRenderer: a divider the focused pane does not touch stays dim" {
    const area_h: u16 = 24;
    // Stacked right column: top [40..80)x[0..12), bottom x[12..24).
    const top = Rect{ .x = 40, .y = 0, .width = 40, .height = 12 };

    // The horizontal divider under `top` is at row 11 and touches it.
    try std.testing.expect(touchesActive(top, .horizontal, 11, top.x, top.width));

    // A vertical divider on the far side of the screen shares no columns with
    // it, so it must not light up.
    try std.testing.expect(!touchesActive(top, .vertical, 5, 0, area_h));

    // Same column, but a row span that does not overlap the focused rect.
    try std.testing.expect(!touchesActive(top, .vertical, 39, 12, 12));
}

test "TuiRenderer: a pane flush to an edge has no boundary beyond it" {
    // x = 0: the saturating `a.x - 1` must not claim column 0 as "the boundary
    // to my left" — there is nothing there.
    const flush = Rect{ .x = 0, .y = 0, .width = 40, .height = 24 };
    try std.testing.expect(!touchesActive(flush, .vertical, 0, 0, 24));
    // Its own right edge still counts.
    try std.testing.expect(touchesActive(flush, .vertical, 39, 0, 24));

    const top_flush = Rect{ .x = 0, .y = 0, .width = 80, .height = 12 };
    try std.testing.expect(!touchesActive(top_flush, .horizontal, 0, 0, 80));
    try std.testing.expect(touchesActive(top_flush, .horizontal, 11, 0, 80));
}
