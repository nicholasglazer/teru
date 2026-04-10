//! Compositor: pane-level rendering functions extracted from Multiplexer.
//!
//! These functions render individual panes, borders, glyphs, and status bars
//! into a SoftwareRenderer's framebuffer. The Multiplexer orchestrates which
//! panes to render and where; this module does the actual pixel work.
//!
//! Zero allocations in the hot path. All buffers are pre-allocated.

const std = @import("std");
const SoftwareRenderer = @import("software.zig").SoftwareRenderer;
const Grid = @import("../core/Grid.zig");
const FontAtlas = @import("FontAtlas.zig");
const ColorScheme = @import("../config/Config.zig").ColorScheme;
const Selection = @import("../core/Selection.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const LayoutEngine = @import("../tiling/LayoutEngine.zig");
const Rect = LayoutEngine.Rect;

// ── Types ─────────────────────────────────────────────────────────

pub const RenderContext = struct {
    renderer: *SoftwareRenderer,
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
};

// ── Pane rendering ────────────────────────────────────────────────

/// Render a single pane's grid into a specific rect of the framebuffer.
pub fn renderPaneIntoRect(
    renderer: *SoftwareRenderer,
    grid: *const Grid,
    rect: Rect,
    cell_width: u32,
    cell_height: u32,
    is_active: bool,
    sel: ?*const Selection,
    scroll_offset: u32,
    sb_lines: u32,
    cursor_visible: bool,
) void {
    const cols: usize = grid.cols;
    const rows: usize = grid.rows;
    const cw: usize = cell_width;
    const ch: usize = cell_height;
    const fb_w: usize = renderer.width;
    const fb_h: usize = renderer.height;
    const rx: usize = rect.x;
    const ry: usize = rect.y;
    const rw: usize = rect.width;
    const rh: usize = rect.height;

    for (0..rows) |row| {
        const screen_y = ry + row * ch;
        if (screen_y >= fb_h or screen_y >= ry + rh) break;

        for (0..cols) |col| {
            const screen_x = rx + col * cw;
            if (screen_x >= fb_w or screen_x >= rx + rw) break;

            const cell = grid.cellAtConst(@intCast(row), @intCast(col));

            var fg = renderer.scheme.resolve(cell.fg, true);
            var bg = renderer.scheme.resolve(cell.bg, false);

            if (cell.attrs.inverse) {
                const tmp = fg;
                fg = bg;
                bg = tmp;
            }
            if (cell.attrs.dim) fg = renderer.scheme.dimColor(fg);
            if (cell.attrs.hidden) fg = bg;

            // Selection highlight: use selection_bg, keep fg readable
            if (sel) |s| {
                if (s.isSelected(@intCast(row), @intCast(col), scroll_offset, sb_lines)) {
                    bg = renderer.scheme.selection_bg;
                    // If fg would be invisible against selection bg, use bright white
                    if (fg == bg) fg = renderer.scheme.ansi[15];
                }
            }

            // Fill cell background
            const max_y = @min(screen_y + ch, fb_h, ry + rh);
            const max_x = @min(screen_x + cw, fb_w, rx + rw);

            for (screen_y..max_y) |py| {
                const row_start = py * fb_w;
                @memset(renderer.framebuffer[row_start + screen_x .. row_start + max_x], bg);
            }

            // Bold-is-bright: shift ANSI 0-7 to bright 8-15 when bold
            if (cell.attrs.bold and renderer.scheme.bold_is_bright) {
                switch (cell.fg) {
                    .indexed => |idx| if (idx < 8) {
                        fg = renderer.scheme.ansi[idx + 8];
                    },
                    else => {},
                }
            }

            // Blit glyph from atlas (ASCII, Latin-1, box drawing, block elements)
            const cp = cell.char;
            if (renderer.atlas_width > 0 and renderer.glyph_atlas.len > 0) {
                if (FontAtlas.glyphSlot(@intCast(cp))) |slot| {
                    const atlas = renderer.getAtlasForAttrs(cell.attrs.bold, cell.attrs.italic);
                    blitGlyphInRect(renderer, @intCast(slot), screen_x, screen_y, max_x, max_y, fg, bg, atlas);
                }
            }
        }
    }

    // Draw cursor for active pane (respects blink state and DECTCEM visibility)
    if (is_active and cursor_visible and renderer.cursor_blink_on and grid.cursor_row < grid.rows and grid.cursor_col < grid.cols) {
        const cx: usize = rx + @as(usize, grid.cursor_col) * cw;
        const cy: usize = ry + @as(usize, grid.cursor_row) * ch;
        const cursor_color: u32 = renderer.scheme.cursor;

        const cursor_max_y = @min(cy + ch, fb_h, ry + rh);
        const cursor_max_x = @min(cx + cw, fb_w, rx + rw);

        if (cx < rx + rw and cy < ry + rh) {
            for (cy..cursor_max_y) |py| {
                const row_start = py * fb_w;
                if (cx < cursor_max_x) {
                    @memset(renderer.framebuffer[row_start + cx .. row_start + cursor_max_x], cursor_color);
                }
            }
        }
    }
}

// ── Glyph blitting ────────────────────────────────────────────────

/// Blit a glyph from the given atlas at the given screen position.
/// The `atlas` parameter selects which font variant to render from
/// (regular, bold, italic, or bold+italic).
pub fn blitGlyphInRect(
    renderer: *SoftwareRenderer,
    glyph_index: u21,
    screen_x: usize,
    screen_y: usize,
    max_x: usize,
    max_y: usize,
    fg: u32,
    bg: u32,
    atlas: []const u8,
) void {
    const cw: usize = renderer.cell_width;
    const ch: usize = renderer.cell_height;
    const aw: usize = renderer.atlas_width;
    const fb_w: usize = renderer.width;

    const glyphs_per_row = if (aw >= cw) aw / cw else return;
    const glyph_row = @as(usize, glyph_index) / glyphs_per_row;
    const glyph_col = @as(usize, glyph_index) % glyphs_per_row;
    const atlas_x = glyph_col * cw;
    const atlas_y = glyph_row * ch;

    const render_h = if (max_y > screen_y) max_y - screen_y else return;
    const render_w = if (max_x > screen_x) max_x - screen_x else return;

    for (0..@min(render_h, ch)) |dy| {
        const py = screen_y + dy;
        if (py >= renderer.height) break;

        const atlas_row_offset = (atlas_y + dy) * aw + atlas_x;
        if (atlas_y + dy >= renderer.atlas_height) break;
        if (atlas_row_offset + cw > atlas.len) break;

        const alpha_row = atlas[atlas_row_offset..][0..cw];
        const fb_row_start = py * fb_w + screen_x;
        const fb_row_end = fb_row_start + render_w;
        if (fb_row_end > renderer.framebuffer.len) break;
        // Ensure we don't cross the framebuffer row boundary
        if (screen_x + render_w > fb_w) break;
        const dst = renderer.framebuffer[fb_row_start..fb_row_end];

        for (0..@min(render_w, cw)) |px| {
            const alpha: u16 = alpha_row[px];
            if (alpha == 0) {
                dst[px] = bg;
            } else if (alpha == 255) {
                dst[px] = fg;
            } else {
                const inv: u16 = 255 - alpha;
                const fg_r: u16 = @truncate((fg >> 16) & 0xFF);
                const fg_g: u16 = @truncate((fg >> 8) & 0xFF);
                const fg_b: u16 = @truncate(fg & 0xFF);
                const bg_r: u16 = @truncate((bg >> 16) & 0xFF);
                const bg_g: u16 = @truncate((bg >> 8) & 0xFF);
                const bg_b: u16 = @truncate(bg & 0xFF);
                const r = (fg_r * alpha + bg_r * inv) / 255;
                const g = (fg_g * alpha + bg_g * inv) / 255;
                const b = (fg_b * alpha + bg_b * inv) / 255;
                dst[px] = (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            }
        }
    }
}

// ── Border drawing ────────────────────────────────────────────────

/// Draw a 1px border around a rect.
pub fn drawBorder(renderer: *SoftwareRenderer, rect: Rect, color: u32) void {
    const fb_w: usize = renderer.width;
    const fb_h: usize = renderer.height;
    const x0: usize = rect.x;
    const y0: usize = rect.y;
    const x1: usize = @min(@as(usize, rect.x) + rect.width, fb_w);
    const y1: usize = @min(@as(usize, rect.y) + rect.height, fb_h);

    if (x0 >= fb_w or y0 >= fb_h) return;

    // Top edge
    if (y0 < fb_h) {
        const row_start = y0 * fb_w;
        @memset(renderer.framebuffer[row_start + x0 .. row_start + x1], color);
    }
    // Bottom edge
    if (y1 > 0 and y1 - 1 < fb_h) {
        const row_start = (y1 - 1) * fb_w;
        @memset(renderer.framebuffer[row_start + x0 .. row_start + x1], color);
    }
    // Left edge
    for (y0..y1) |py| {
        if (py < fb_h and x0 < fb_w) {
            renderer.framebuffer[py * fb_w + x0] = color;
        }
    }
    // Right edge
    for (y0..y1) |py| {
        if (py < fb_h and x1 > 0 and x1 - 1 < fb_w) {
            renderer.framebuffer[py * fb_w + x1 - 1] = color;
        }
    }
}

// ── Agent status bar ──────────────────────────────────────────────

/// Render a status bar at the bottom of the framebuffer showing agent counts.
/// The bar is color-coded: cyan segments for running, green for done, red for failed.
pub fn renderAgentStatusBar(
    renderer: *SoftwareRenderer,
    graph: ?*const ProcessGraph,
    screen_width: u32,
    screen_height: u32,
    bar_height: u16,
) void {
    const scheme = &renderer.scheme;
    const bar_y: usize = screen_height - bar_height;
    const bar_bg: u32 = scheme.bg;
    const fb_w: usize = renderer.width;

    // Fill bar background
    for (bar_y..screen_height) |y| {
        if (y >= renderer.height) break;
        const row_start = y * fb_w;
        const end = @min(row_start + screen_width, renderer.framebuffer.len);
        if (row_start < end) {
            @memset(renderer.framebuffer[row_start..end], bar_bg);
        }
    }

    // Draw a 1px separator line at the top of the bar
    if (bar_y > 0 and bar_y < renderer.height) {
        const sep_start = bar_y * fb_w;
        const sep_end = @min(sep_start + screen_width, renderer.framebuffer.len);
        if (sep_start < sep_end) {
            @memset(renderer.framebuffer[sep_start..sep_end], scheme.selection_bg);
        }
    }

    const pg = graph orelse return;
    const counts = pg.countAgentsByState();
    const total = counts.running + counts.done + counts.failed;
    if (total == 0) return;

    // Draw colored segments proportional to counts (2px inset from edges)
    const inset_px: usize = 2;
    const seg_y_start: usize = bar_y + inset_px + 1; // +1 for separator
    const seg_y_end: usize = @min(screen_height - inset_px, renderer.height);
    if (seg_y_start >= seg_y_end) return;

    const bar_width: usize = if (screen_width > inset_px * 2) screen_width - inset_px * 2 else return;

    const running_w: usize = @as(usize, counts.running) * bar_width / total;
    const done_w: usize = @as(usize, counts.done) * bar_width / total;
    // Failed gets the remainder to avoid rounding gaps
    const failed_w: usize = if (counts.failed > 0) bar_width - running_w - done_w else 0;

    for (seg_y_start..seg_y_end) |y| {
        if (y >= renderer.height) break;
        const row_start = y * fb_w + inset_px;
        if (row_start + bar_width > renderer.framebuffer.len) break;
        const row = renderer.framebuffer[row_start..][0..bar_width];

        var offset: usize = 0;
        if (running_w > 0) {
            @memset(row[offset..][0..running_w], scheme.ansi[6]); // cyan
            offset += running_w;
        }
        if (done_w > 0) {
            @memset(row[offset..][0..done_w], scheme.ansi[2]); // green
            offset += done_w;
        }
        if (failed_w > 0) {
            @memset(row[offset..][0..failed_w], scheme.ansi[1]); // red
        }
    }
}

// ── Border color ──────────────────────────────────────────────────

/// Determine border color based on agent state for the given pane.
/// Falls back to scheme border colors when no process graph or no agent is assigned.
pub fn getBorderColor(graph: ?*const ProcessGraph, pane_id: u64, is_active: bool, scheme: *const ColorScheme) u32 {
    const default_active: u32 = scheme.border_active;
    const default_inactive: u32 = scheme.border_inactive;

    const pg = graph orelse return if (is_active) default_active else default_inactive;

    // Search for an agent node whose workspace matches this pane
    // Agent nodes are linked to panes by convention -- the agent event handler
    // stores the pane ID context. For now, iterate agent nodes and check if
    // any are associated with this pane_id (workspace == pane mapping).
    var it = pg.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.kind != .agent) continue;
        // Match agent to pane via workspace (pane IDs are used as workspace markers)
        // This is a soft association -- agents created for a pane get the pane's workspace
        if (node.id == pane_id or node.workspace == @as(u8, @truncate(pane_id))) {
            return switch (node.state) {
                .running => scheme.ansi[6], // cyan -- working
                .finished => if ((node.exit_code orelse 1) == 0)
                    scheme.ansi[2] // green -- success
                else
                    scheme.ansi[1], // red -- failed
                .paused => scheme.ansi[8], // bright black -- idle
                .persisted, .interrupted => if (is_active) default_active else default_inactive,
            };
        }
    }

    return if (is_active) default_active else default_inactive;
}

// ── Rect utility ──────────────────────────────────────────────────

/// Shrink a rect by n pixels on each side.
pub fn insetRect(rect: Rect, n: u16) Rect {
    const double_n = n * 2;
    if (rect.width <= double_n or rect.height <= double_n) return rect;
    return .{
        .x = rect.x + n,
        .y = rect.y + n,
        .width = rect.width - double_n,
        .height = rect.height - double_n,
    };
}

// ── Tests ─────────────────────────────────────────────────────────

const t = std.testing;

test "insetRect" {
    const rect = Rect{ .x = 10, .y = 20, .width = 100, .height = 80 };
    const inset = insetRect(rect, 1);
    try t.expectEqual(@as(u16, 11), inset.x);
    try t.expectEqual(@as(u16, 21), inset.y);
    try t.expectEqual(@as(u16, 98), inset.width);
    try t.expectEqual(@as(u16, 78), inset.height);

    // Too small to inset
    const tiny = Rect{ .x = 0, .y = 0, .width = 2, .height = 2 };
    const no_change = insetRect(tiny, 1);
    try t.expect(no_change.eql(tiny));
}

test "drawBorder" {
    var renderer = try SoftwareRenderer.init(t.allocator, 10, 10, 1, 1);
    defer renderer.deinit();

    const bg = renderer.scheme.bg;
    @memset(renderer.framebuffer, bg);

    drawBorder(&renderer, .{ .x = 2, .y = 2, .width = 4, .height = 3 }, 0xFFFF0000);

    // Top edge: pixels (2,2) through (5,2)
    try t.expectEqual(@as(u32, 0xFFFF0000), renderer.framebuffer[2 * 10 + 2]);
    try t.expectEqual(@as(u32, 0xFFFF0000), renderer.framebuffer[2 * 10 + 5]);

    // Bottom edge: pixels at y=4
    try t.expectEqual(@as(u32, 0xFFFF0000), renderer.framebuffer[4 * 10 + 2]);
    try t.expectEqual(@as(u32, 0xFFFF0000), renderer.framebuffer[4 * 10 + 5]);

    // Left edge
    try t.expectEqual(@as(u32, 0xFFFF0000), renderer.framebuffer[3 * 10 + 2]);

    // Right edge
    try t.expectEqual(@as(u32, 0xFFFF0000), renderer.framebuffer[3 * 10 + 5]);

    // Interior should be unchanged (bg)
    try t.expectEqual(bg, renderer.framebuffer[3 * 10 + 3]);
}

test "getBorderColor defaults without graph" {
    const scheme = ColorScheme{};
    // No graph: should return default colors
    try t.expectEqual(scheme.border_active, getBorderColor(null, 1, true, &scheme));
    try t.expectEqual(scheme.border_inactive, getBorderColor(null, 1, false, &scheme));
}

test "getBorderColor with running agent" {
    const scheme = ColorScheme{};
    var graph = ProcessGraph.init(t.allocator);
    defer graph.deinit();

    const agent_id = try graph.spawn(.{
        .name = "test-agent",
        .kind = .agent,
        .agent = .{ .group = "test", .role = "worker" },
        .workspace = 1,
    });

    // Agent node ID should give cyan (running)
    try t.expectEqual(scheme.ansi[6], getBorderColor(&graph, agent_id, true, &scheme));
}

test "getBorderColor with finished agent" {
    const scheme = ColorScheme{};
    var graph = ProcessGraph.init(t.allocator);
    defer graph.deinit();

    const agent_id = try graph.spawn(.{
        .name = "done-agent",
        .kind = .agent,
        .agent = .{ .group = "test", .role = "worker" },
    });
    graph.markFinished(agent_id, 0); // success

    // Should be green (ansi[2])
    try t.expectEqual(scheme.ansi[2], getBorderColor(&graph, agent_id, true, &scheme));
}

test "getBorderColor with failed agent" {
    const scheme = ColorScheme{};
    var graph = ProcessGraph.init(t.allocator);
    defer graph.deinit();

    const agent_id = try graph.spawn(.{
        .name = "fail-agent",
        .kind = .agent,
        .agent = .{ .group = "test", .role = "worker" },
    });
    graph.markFinished(agent_id, 1); // failure

    // Should be red (ansi[1])
    try t.expectEqual(scheme.ansi[1], getBorderColor(&graph, agent_id, true, &scheme));
}

test "renderAgentStatusBar with agents" {
    var graph = ProcessGraph.init(t.allocator);
    defer graph.deinit();

    _ = try graph.spawn(.{
        .name = "a1",
        .kind = .agent,
        .agent = .{ .group = "g", .role = "w" },
    });
    const a2 = try graph.spawn(.{
        .name = "a2",
        .kind = .agent,
        .agent = .{ .group = "g", .role = "w" },
    });
    graph.markFinished(a2, 0);

    const width: u32 = 100;
    const height: u32 = 100;
    var renderer = try SoftwareRenderer.init(t.allocator, width, height, 8, 16);
    defer renderer.deinit();

    const bar_h: u16 = 20;
    renderAgentStatusBar(&renderer, &graph, width, height, bar_h);

    // The bar should have colored pixels in the bottom 20 rows
    // Check that the status bar region is not all default bg
    const bar_y = height - bar_h;
    const mid_y = bar_y + bar_h / 2;
    const mid_pixel = renderer.framebuffer[mid_y * width + 10];
    // Should be one of our agent colors (cyan=running or green=done), not the default bg
    const scheme_bg = renderer.scheme.bg;
    try t.expect(mid_pixel != scheme_bg);
}

test "renderAgentStatusBar no graph is no-op" {
    const width: u32 = 100;
    const height: u32 = 100;
    var renderer = try SoftwareRenderer.init(t.allocator, width, height, 8, 16);
    defer renderer.deinit();

    const scheme = renderer.scheme;
    @memset(renderer.framebuffer, scheme.bg);

    renderAgentStatusBar(&renderer, null, width, height, 20);

    // Bar background should be drawn but no colored segments
    const bar_y = height - 20;
    try t.expectEqual(scheme.bg, renderer.framebuffer[(bar_y + 5) * width + 10]);
}
