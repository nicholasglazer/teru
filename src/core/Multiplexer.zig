const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Pane = @import("Pane.zig");
const Grid = @import("Grid.zig");
const VtParser = @import("VtParser.zig");
const Pty = @import("../pty/Pty.zig");
const LayoutEngine = @import("../tiling/LayoutEngine.zig");
const Rect = LayoutEngine.Rect;
const Selection = @import("Selection.zig");
const SoftwareRenderer = @import("../render/software.zig").SoftwareRenderer;
const Session = @import("../persist/Session.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Scrollback = @import("../persist/Scrollback.zig");

/// Multiplexer orchestrates multiple panes with tiling layout.
/// Each pane has its own PTY + Grid + VtParser. The LayoutEngine
/// determines where each pane renders on screen.
const Multiplexer = @This();

panes: std.ArrayListUnmanaged(Pane),
layout_engine: LayoutEngine,
active_workspace: u8,
allocator: Allocator,
scrollback: ?Scrollback,
next_pane_id: u64,
graph: ?*ProcessGraph = null,

pub fn init(allocator: Allocator) Multiplexer {
    return .{
        .panes = .empty,
        .layout_engine = LayoutEngine.init(allocator),
        .active_workspace = 0,
        .allocator = allocator,
        .scrollback = null,
        .next_pane_id = 1,
    };
}

pub fn deinit(self: *Multiplexer) void {
    for (self.panes.items) |*pane| {
        pane.deinit(self.allocator);
    }
    self.panes.deinit(self.allocator);
    self.layout_engine.deinit();
    if (self.scrollback) |*sb| sb.deinit();
}

// ── Pane management ────────────────────────────────────────────

/// Spawn a new pane with the given grid dimensions.
/// Returns the pane ID. The pane is added to the active workspace.
pub fn spawnPane(self: *Multiplexer, rows: u16, cols: u16) !u64 {
    const id = self.next_pane_id;
    self.next_pane_id += 1;

    var pane = try Pane.init(self.allocator, rows, cols, id);
    errdefer pane.deinit(self.allocator);

    try self.panes.append(self.allocator, pane);
    errdefer _ = self.panes.pop();

    // Patch VtParser's grid pointer now that Pane is in its final memory location
    self.panes.items[self.panes.items.len - 1].linkVt(self.allocator);

    try self.layout_engine.workspaces[self.active_workspace].addNode(self.allocator, id);

    return id;
}

/// Spawn a pane running a custom command instead of the user's shell.
/// The command string is passed as the shell argument to Pty.spawn.
/// Returns the pane ID.
pub fn spawnPaneWithCommand(self: *Multiplexer, rows: u16, cols: u16, command: []const u8, cwd: ?[]const u8) !u64 {
    const id = self.next_pane_id;
    self.next_pane_id += 1;

    var grid = try Grid.init(self.allocator, rows, cols);
    errdefer grid.deinit(self.allocator);

    var pty = try Pty.spawn(.{ .rows = rows, .cols = cols, .shell = command, .cwd = cwd });
    errdefer pty.deinit();

    // Set PTY master to non-blocking
    const flags = std.c.fcntl(pty.master, posix.F.GETFL);
    if (flags < 0) return error.FcntlFailed;
    const O_NONBLOCK = 0x800;
    _ = std.c.fcntl(pty.master, posix.F.SETFL, flags | O_NONBLOCK);

    var pane = Pane{
        .pty = pty,
        .grid = grid,
        .vt = VtParser.initEmpty(),
        .id = id,
    };
    _ = &pane;

    try self.panes.append(self.allocator, pane);
    errdefer _ = self.panes.pop();

    // Patch VtParser's grid pointer now that Pane is in its final memory location
    self.panes.items[self.panes.items.len - 1].linkVt(self.allocator);

    try self.layout_engine.workspaces[self.active_workspace].addNode(self.allocator, id);

    return id;
}

/// Close and remove a pane by its ID.
pub fn closePane(self: *Multiplexer, pane_id: u64) void {
    // Remove from all workspaces
    for (&self.layout_engine.workspaces) |*ws| {
        ws.removeNode(pane_id);
    }

    // Find and remove from panes list
    for (self.panes.items, 0..) |*pane, i| {
        if (pane.id == pane_id) {
            pane.deinit(self.allocator);
            _ = self.panes.orderedRemove(i);
            break;
        }
    }
}

/// Get the currently focused pane (active pane in active workspace).
pub fn getActivePane(self: *Multiplexer) ?*Pane {
    const ws = &self.layout_engine.workspaces[self.active_workspace];
    const active_id = ws.getActiveNodeId() orelse return null;
    return self.getPaneById(active_id);
}

/// Find a pane by its ID.
pub fn getPaneById(self: *Multiplexer, id: u64) ?*Pane {
    for (self.panes.items) |*pane| {
        if (pane.id == id) return pane;
    }
    return null;
}

// ── Navigation ─────────────────────────────────────────────────

/// Focus the next pane in the active workspace.
pub fn focusNext(self: *Multiplexer) void {
    self.layout_engine.workspaces[self.active_workspace].focusNext();
}

/// Focus the previous pane in the active workspace.
pub fn focusPrev(self: *Multiplexer) void {
    self.layout_engine.workspaces[self.active_workspace].focusPrev();
}

/// Switch to a workspace by index (0-8).
pub fn switchWorkspace(self: *Multiplexer, idx: u8) void {
    self.layout_engine.switchWorkspace(idx);
    self.active_workspace = self.layout_engine.active_workspace;
}

/// Cycle the layout of the active workspace.
pub fn cycleLayout(self: *Multiplexer) void {
    const ws = &self.layout_engine.workspaces[self.active_workspace];
    ws.layout = switch (ws.layout) {
        .master_stack => .grid,
        .grid => .monocle,
        .monocle => .floating,
        .floating => .master_stack,
    };
}

// ── PTY polling ────────────────────────────────────────────────

/// Read from all PTYs. Returns true if any had output.
pub fn pollPtys(self: *Multiplexer, buf: []u8) bool {
    var any_output = false;
    for (self.panes.items) |*pane| {
        const n = pane.readAndProcess(buf) catch 0;
        if (n > 0) any_output = true;
    }
    return any_output;
}

// ── Rendering ──────────────────────────────────────────────────

/// Render all visible panes into the software renderer's framebuffer.
/// Each pane is rendered into its layout rect. The active pane gets
/// a highlighted border.
pub fn renderAll(
    self: *Multiplexer,
    renderer: *SoftwareRenderer,
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
) void {
    self.renderAllWithSelection(renderer, screen_width, screen_height, cell_width, cell_height, null);
}

/// Render all visible panes with optional selection highlight on the active pane.
pub fn renderAllWithSelection(
    self: *Multiplexer,
    renderer: *SoftwareRenderer,
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
    sel: ?*const Selection,
) void {
    const bg = resolveDefaultBg();
    @memset(renderer.framebuffer, bg);

    const screen_rect = Rect{
        .x = 0,
        .y = 0,
        .width = @intCast(@min(screen_width, std.math.maxInt(u16))),
        .height = @intCast(@min(screen_height, std.math.maxInt(u16))),
    };

    const ws = &self.layout_engine.workspaces[self.active_workspace];
    const node_ids = ws.node_ids.items;
    if (node_ids.len == 0) return;

    const rects = self.layout_engine.calculate(self.active_workspace, screen_rect) catch return;
    defer self.allocator.free(rects);

    const active_id = ws.getActiveNodeId();

    // Reserve bottom bar height only when agents are active
    const has_agents = if (self.graph) |g| g.countAgentsByState().running + g.countAgentsByState().done + g.countAgentsByState().failed > 0 else false;
    const bar_height: u16 = if (has_agents and screen_height > 60) 20 else 0;
    const effective_height: u16 = @intCast(screen_height -| bar_height);

    for (rects, 0..) |rect, i| {
        if (i >= node_ids.len) break;
        if (rect.width == 0 or rect.height == 0) continue;

        // Clamp rect to effective height (above status bar)
        var clamped = rect;
        if (@as(u32, clamped.y) + clamped.height > effective_height) {
            if (clamped.y >= effective_height) continue;
            clamped.height = effective_height - clamped.y;
        }

        const pane = self.getPaneById(node_ids[i]) orelse continue;
        const is_active = if (active_id) |aid| aid == pane.id else false;
        // Only apply selection highlight to the active pane
        const pane_sel = if (is_active) sel else null;

        // For multi-pane layouts, reserve 1px border around each pane
        const has_border = node_ids.len > 1;
        if (has_border) {
            // Draw border with agent-aware color
            const border_color = getBorderColor(self.graph, pane.id, is_active);
            drawBorder(renderer, clamped, border_color);

            // Render grid into inset rect
            const inset = insetRect(clamped, 1);
            renderPaneIntoRect(renderer, &pane.grid, inset, cell_width, cell_height, is_active, pane_sel);
        } else {
            // Single pane: no border, full screen (above status bar)
            renderPaneIntoRect(renderer, &pane.grid, clamped, cell_width, cell_height, is_active, pane_sel);
        }
    }

    // Render status bar at the bottom
    if (screen_height > bar_height + 40) {
        renderStatusBar(renderer, self.graph, screen_width, screen_height, bar_height);
    }
}

/// Render a single pane's grid into a specific rect of the framebuffer.
fn renderPaneIntoRect(
    renderer: *SoftwareRenderer,
    grid: *const Grid,
    rect: Rect,
    cell_width: u32,
    cell_height: u32,
    is_active: bool,
    sel: ?*const Selection,
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

            var fg = resolveColorArgb(cell.fg, true);
            var bg = resolveColorArgb(cell.bg, false);

            if (cell.attrs.inverse) {
                const tmp = fg;
                fg = bg;
                bg = tmp;
            }
            if (cell.attrs.dim) fg = dimColor(fg);
            if (cell.attrs.hidden) fg = bg;

            // Selection highlight: swap fg/bg for selected cells
            if (sel) |s| {
                if (s.isSelected(@intCast(row), @intCast(col))) {
                    const tmp = fg;
                    fg = bg;
                    bg = tmp;
                }
            }

            // Fill cell background
            const max_y = @min(screen_y + ch, fb_h, ry + rh);
            const max_x = @min(screen_x + cw, fb_w, rx + rw);

            for (screen_y..max_y) |py| {
                const row_start = py * fb_w;
                @memset(renderer.framebuffer[row_start + screen_x .. row_start + max_x], bg);
            }

            // Blit glyph from atlas
            const cp = cell.char;
            if (cp >= 32 and cp < 127 and renderer.atlas_width > 0 and renderer.glyph_atlas.len > 0) {
                blitGlyphInRect(renderer, cp - 32, screen_x, screen_y, max_x, max_y, fg, bg);
            }
        }
    }

    // Draw cursor for active pane
    if (is_active and grid.cursor_row < grid.rows and grid.cursor_col < grid.cols) {
        const cx: usize = rx + @as(usize, grid.cursor_col) * cw;
        const cy: usize = ry + @as(usize, grid.cursor_row) * ch;
        const cursor_color: u32 = 0xFFFF9922;

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

/// Blit a glyph from the atlas at the given screen position.
fn blitGlyphInRect(
    renderer: *SoftwareRenderer,
    glyph_index: u21,
    screen_x: usize,
    screen_y: usize,
    max_x: usize,
    max_y: usize,
    fg: u32,
    bg: u32,
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

    const render_h = max_y - screen_y;
    const render_w = max_x - screen_x;

    for (0..@min(render_h, ch)) |dy| {
        const atlas_row_offset = (atlas_y + dy) * aw + atlas_x;
        if (atlas_y + dy >= renderer.atlas_height) break;
        if (atlas_row_offset + cw > renderer.glyph_atlas.len) break;

        const alpha_row = renderer.glyph_atlas[atlas_row_offset..][0..cw];
        const fb_row_start = (screen_y + dy) * fb_w + screen_x;
        const dst = renderer.framebuffer[fb_row_start..][0..render_w];

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

/// Draw a 1px border around a rect.
fn drawBorder(renderer: *SoftwareRenderer, rect: Rect, color: u32) void {
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

/// Determine border color based on agent state for the given pane.
/// Falls back to default colors when no process graph or no agent is assigned.
fn getBorderColor(graph: ?*const ProcessGraph, pane_id: u64, is_active: bool) u32 {
    const default_active: u32 = 0xFFFF9922; // orange
    const default_inactive: u32 = 0xFF444444; // dim gray

    const pg = graph orelse return if (is_active) default_active else default_inactive;

    // Search for an agent node whose workspace matches this pane
    // Agent nodes are linked to panes by convention — the agent event handler
    // stores the pane ID context. For now, iterate agent nodes and check if
    // any are associated with this pane_id (workspace == pane mapping).
    var it = pg.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.kind != .agent) continue;
        // Match agent to pane via workspace (pane IDs are used as workspace markers)
        // This is a soft association — agents created for a pane get the pane's workspace
        if (node.id == pane_id or node.workspace == @as(u8, @truncate(pane_id))) {
            return switch (node.state) {
                .running => 0xFF2DD9F0, // cyan — working
                .finished => if ((node.exit_code orelse 1) == 0)
                    0xFF7DB359 // green — success
                else
                    0xFFF4517D, // red — failed
                .paused => 0xFF38384C, // gray — idle
                .persisted, .interrupted => if (is_active) default_active else default_inactive,
            };
        }
    }

    return if (is_active) default_active else default_inactive;
}

/// Render a status bar at the bottom of the framebuffer showing agent counts.
/// The bar is color-coded: cyan segments for running, green for done, red for failed.
fn renderStatusBar(
    renderer: *SoftwareRenderer,
    graph: ?*const ProcessGraph,
    screen_width: u32,
    screen_height: u32,
    bar_height: u16,
) void {
    const bar_y: usize = screen_height - bar_height;
    const bar_bg: u32 = 0xFF1D1D23; // dark background
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
            @memset(renderer.framebuffer[sep_start..sep_end], 0xFF38384C);
        }
    }

    const pg = graph orelse return;
    const counts = pg.countAgentsByState();
    const total = counts.running + counts.done + counts.failed;
    if (total == 0) return;

    // Draw colored segments proportional to counts (2px inset from edges)
    const inset: usize = 2;
    const seg_y_start: usize = bar_y + inset + 1; // +1 for separator
    const seg_y_end: usize = @min(screen_height - inset, renderer.height);
    if (seg_y_start >= seg_y_end) return;

    const bar_width: usize = if (screen_width > inset * 2) screen_width - inset * 2 else return;

    const running_w: usize = @as(usize, counts.running) * bar_width / total;
    const done_w: usize = @as(usize, counts.done) * bar_width / total;
    // Failed gets the remainder to avoid rounding gaps
    const failed_w: usize = if (counts.failed > 0) bar_width - running_w - done_w else 0;

    for (seg_y_start..seg_y_end) |y| {
        if (y >= renderer.height) break;
        const row_start = y * fb_w + inset;
        if (row_start + bar_width > renderer.framebuffer.len) break;
        const row = renderer.framebuffer[row_start..][0..bar_width];

        var offset: usize = 0;
        if (running_w > 0) {
            @memset(row[offset..][0..running_w], 0xFF2DD9F0); // cyan
            offset += running_w;
        }
        if (done_w > 0) {
            @memset(row[offset..][0..done_w], 0xFF7DB359); // green
            offset += done_w;
        }
        if (failed_w > 0) {
            @memset(row[offset..][0..failed_w], 0xFFF4517D); // red
        }
    }
}

/// Shrink a rect by n pixels on each side.
fn insetRect(rect: Rect, n: u16) Rect {
    const double_n = n * 2;
    if (rect.width <= double_n or rect.height <= double_n) return rect;
    return .{
        .x = rect.x + n,
        .y = rect.y + n,
        .width = rect.width - double_n,
        .height = rect.height - double_n,
    };
}

// ── Session persistence ────────────────────────────────────────

/// Save session state to a file. This serializes the process graph.
pub fn saveSession(self: *Multiplexer, graph: *const ProcessGraph, path: []const u8, io: Io) !void {
    _ = self;
    try Session.saveToFile(graph, path, io);
}

// ── Color helpers (duplicated from software.zig to avoid coupling) ──

fn resolveDefaultBg() u32 {
    return packArgb(18, 18, 26);
}

fn resolveColorArgb(color: Grid.Color, is_fg: bool) u32 {
    return switch (color) {
        .default => if (is_fg) packArgb(230, 230, 230) else packArgb(18, 18, 26),
        .indexed => |idx| indexed256Argb(idx),
        .rgb => |c| packArgb(c.r, c.g, c.b),
    };
}

fn packArgb(r: u8, g: u8, b: u8) u32 {
    return (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

fn indexed256Argb(idx: u8) u32 {
    // Inline the 16 standard colors, delegate rest to formula
    const standard = [16]u32{
        0xFF000000, 0xFFCC0000, 0xFF00CC00, 0xFFCCCC00,
        0xFF0000CC, 0xFFCC00CC, 0xFF00CCCC, 0xFFBFBFBF,
        0xFF808080, 0xFFFF0000, 0xFF00FF00, 0xFFFFFF00,
        0xFF0000FF, 0xFFFF00FF, 0xFF00FFFF, 0xFFFFFFFF,
    };
    if (idx < 16) return standard[idx];
    if (idx >= 232) {
        const v: u32 = @as(u32, idx - 232) * 10 + 8;
        return (0xFF << 24) | (v << 16) | (v << 8) | v;
    }
    // 16-231: 6x6x6 color cube
    const i = @as(u32, idx) - 16;
    const b_val = i % 6;
    const g_val = (i / 6) % 6;
    const r_val = i / 36;
    const r: u32 = if (r_val == 0) 0 else r_val * 40 + 55;
    const g: u32 = if (g_val == 0) 0 else g_val * 40 + 55;
    const b: u32 = if (b_val == 0) 0 else b_val * 40 + 55;
    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

fn dimColor(argb: u32) u32 {
    const r = ((argb >> 16) & 0xFF) >> 1;
    const g = ((argb >> 8) & 0xFF) >> 1;
    const b = (argb & 0xFF) >> 1;
    return (0xFF << 24) | (r << 16) | (g << 8) | b;
}

// ── Tests ──────────────────────────────────────────────────────

const t = std.testing;

test "Multiplexer init and deinit" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    try t.expectEqual(@as(u64, 1), mux.next_pane_id);
    try t.expectEqual(@as(u8, 0), mux.active_workspace);
    try t.expectEqual(@as(usize, 0), mux.panes.items.len);
}

test "Multiplexer spawnPane and closePane" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    const id1 = try mux.spawnPane(24, 80);
    try t.expectEqual(@as(u64, 1), id1);
    try t.expectEqual(@as(usize, 1), mux.panes.items.len);

    const id2 = try mux.spawnPane(24, 80);
    try t.expectEqual(@as(u64, 2), id2);
    try t.expectEqual(@as(usize, 2), mux.panes.items.len);

    // Active workspace should have both
    const ws = &mux.layout_engine.workspaces[0];
    try t.expectEqual(@as(usize, 2), ws.nodeCount());

    mux.closePane(id1);
    try t.expectEqual(@as(usize, 1), mux.panes.items.len);
    try t.expectEqual(@as(usize, 1), ws.nodeCount());
    try t.expectEqual(@as(?u64, id2), ws.getActiveNodeId());
}

test "Multiplexer getActivePane" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    // No panes yet
    try t.expectEqual(@as(?*Pane, null), mux.getActivePane());

    const id = try mux.spawnPane(24, 80);
    const active = mux.getActivePane();
    try t.expect(active != null);
    try t.expectEqual(id, active.?.id);
}

test "Multiplexer getPaneById" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    const id1 = try mux.spawnPane(10, 20);
    const id2 = try mux.spawnPane(10, 20);

    try t.expectEqual(id1, mux.getPaneById(id1).?.id);
    try t.expectEqual(id2, mux.getPaneById(id2).?.id);
    try t.expectEqual(@as(?*Pane, null), mux.getPaneById(999));
}

test "Multiplexer focus navigation" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    const id1 = try mux.spawnPane(10, 20);
    const id2 = try mux.spawnPane(10, 20);
    const id3 = try mux.spawnPane(10, 20);

    try t.expectEqual(id1, mux.getActivePane().?.id);

    mux.focusNext();
    try t.expectEqual(id2, mux.getActivePane().?.id);

    mux.focusNext();
    try t.expectEqual(id3, mux.getActivePane().?.id);

    mux.focusNext(); // wraps
    try t.expectEqual(id1, mux.getActivePane().?.id);

    mux.focusPrev(); // wraps back
    try t.expectEqual(id3, mux.getActivePane().?.id);
}

test "Multiplexer switchWorkspace" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    try t.expectEqual(@as(u8, 0), mux.active_workspace);

    mux.switchWorkspace(3);
    try t.expectEqual(@as(u8, 3), mux.active_workspace);

    // Out of range does nothing
    mux.switchWorkspace(99);
    try t.expectEqual(@as(u8, 3), mux.active_workspace);
}

test "Multiplexer cycleLayout" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    _ = try mux.spawnPane(10, 20);

    const ws = &mux.layout_engine.workspaces[0];

    // monocle (auto-selected for 1 pane) -> grid -> monocle -> ...
    // Force a known starting layout
    ws.layout = .master_stack;
    mux.cycleLayout();
    try t.expectEqual(LayoutEngine.Layout.grid, ws.layout);

    mux.cycleLayout();
    try t.expectEqual(LayoutEngine.Layout.monocle, ws.layout);

    mux.cycleLayout();
    try t.expectEqual(LayoutEngine.Layout.floating, ws.layout);

    mux.cycleLayout();
    try t.expectEqual(LayoutEngine.Layout.master_stack, ws.layout);
}

test "Multiplexer pollPtys" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    _ = try mux.spawnPane(10, 20);

    var buf: [4096]u8 = undefined;
    // Should not crash; may or may not have output
    _ = mux.pollPtys(&buf);
}

test "Multiplexer renderAll with single pane" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    _ = try mux.spawnPane(3, 4);

    const cw: u32 = 8;
    const ch: u32 = 16;
    const width: u32 = 4 * cw;
    const height: u32 = 3 * ch;

    var renderer = try SoftwareRenderer.init(t.allocator, width, height, cw, ch);
    defer renderer.deinit();

    mux.renderAll(&renderer, width, height, cw, ch);

    // Should have rendered something (at minimum the background)
    // Single pane = no border, cursor should be visible
    const cursor_color: u32 = 0xFFFF9922;
    try t.expectEqual(cursor_color, renderer.framebuffer[0]); // cursor at (0,0)
}

test "Multiplexer renderAll with multiple panes" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    _ = try mux.spawnPane(3, 4);
    _ = try mux.spawnPane(3, 4);

    const cw: u32 = 8;
    const ch: u32 = 16;
    const width: u32 = 80;
    const height: u32 = 48;

    var renderer = try SoftwareRenderer.init(t.allocator, width, height, cw, ch);
    defer renderer.deinit();

    mux.renderAll(&renderer, width, height, cw, ch);

    // With 2 panes, borders should be drawn. Active pane border = 0xFFFF9922.
    // First pixel (0,0) should be the active pane's border color.
    try t.expectEqual(@as(u32, 0xFFFF9922), renderer.framebuffer[0]);
}

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

    const bg = resolveDefaultBg();
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
    // No graph: should return default colors
    try t.expectEqual(@as(u32, 0xFFFF9922), getBorderColor(null, 1, true));
    try t.expectEqual(@as(u32, 0xFF444444), getBorderColor(null, 1, false));
}

test "getBorderColor with running agent" {
    var graph = ProcessGraph.init(t.allocator);
    defer graph.deinit();

    const agent_id = try graph.spawn(.{
        .name = "test-agent",
        .kind = .agent,
        .agent = .{ .group = "test", .role = "worker" },
        .workspace = 1,
    });

    // Agent node ID should give cyan (running)
    try t.expectEqual(@as(u32, 0xFF2DD9F0), getBorderColor(&graph, agent_id, true));
}

test "getBorderColor with finished agent" {
    var graph = ProcessGraph.init(t.allocator);
    defer graph.deinit();

    const agent_id = try graph.spawn(.{
        .name = "done-agent",
        .kind = .agent,
        .agent = .{ .group = "test", .role = "worker" },
    });
    graph.markFinished(agent_id, 0); // success

    // Should be green
    try t.expectEqual(@as(u32, 0xFF7DB359), getBorderColor(&graph, agent_id, true));
}

test "getBorderColor with failed agent" {
    var graph = ProcessGraph.init(t.allocator);
    defer graph.deinit();

    const agent_id = try graph.spawn(.{
        .name = "fail-agent",
        .kind = .agent,
        .agent = .{ .group = "test", .role = "worker" },
    });
    graph.markFinished(agent_id, 1); // failure

    // Should be red
    try t.expectEqual(@as(u32, 0xFFF4517D), getBorderColor(&graph, agent_id, true));
}

test "renderStatusBar with agents" {
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
    renderStatusBar(&renderer, &graph, width, height, bar_h);

    // The bar should have colored pixels in the bottom 20 rows
    // Check that the status bar region is not all default bg
    const bar_y = height - bar_h;
    const mid_y = bar_y + bar_h / 2;
    const mid_pixel = renderer.framebuffer[mid_y * width + 10];
    // Should be one of our agent colors (cyan=running or green=done), not the default bg
    const default_bg = resolveDefaultBg();
    try t.expect(mid_pixel != default_bg);
}

test "renderStatusBar no graph is no-op" {
    const width: u32 = 100;
    const height: u32 = 100;
    var renderer = try SoftwareRenderer.init(t.allocator, width, height, 8, 16);
    defer renderer.deinit();

    const bg = resolveDefaultBg();
    @memset(renderer.framebuffer, bg);

    renderStatusBar(&renderer, null, width, height, 20);

    // Bar background should be drawn but no colored segments
    const bar_y = height - 20;
    // The bar bg (0xFF1D1D23) should be present
    try t.expectEqual(@as(u32, 0xFF1D1D23), renderer.framebuffer[(bar_y + 5) * width + 10]);
}
