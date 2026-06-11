//! Bottom-anchored, full-width "leader panel" overlay for the which-key menu.
//!
//! Technically an overlay (its own wlr_scene_buffer, raised above panes AND
//! bars), so it works even when the bars are hidden (Mod+Shift+B) and never
//! reflows the tiling — it just OCCLUDES the bottom row(s) while active and
//! vanishes on dismiss. Styled as a full-width strip flush to the bottom edge
//! (sharp corners, opaque) so it reads as a tiling HUD, not a floating popup.
//!
//! Height tracks the current node's child count: a group that fits on one row
//! is exactly bar-height (`cell_h + 4`); each extra row of entries adds exactly
//! one `cell_h`. The surface is re-created when the needed height changes (on
//! group descend / ascend), so the panel is never taller than it needs to be.
//!
//! Lifecycle: created lazily on first leader activation (re-created if the
//! output resized OR the needed height changed), shown/hidden on
//! activate/dismiss, re-rendered as you descend groups. Mirrors
//! Bar.createBarInstance for the surface plumbing.

const std = @import("std");
const teru = @import("teru");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const LeaderKey = teru.LeaderKey; // shared engine
const CompositorLeader = @import("CompositorLeader.zig"); // teruwm tree (tests)
const Ui = teru.Ui;
const SoftwareRenderer = teru.render.SoftwareRenderer;

const LeaderPanel = @This();

/// Vertical padding (top+bottom) around the text rows — matches the bar's
/// `cell_h + 4`, so a single-row panel is pixel-for-pixel the bar's height.
const v_pad: u32 = 4;
/// Left/right inset for content, in pixels.
const pad_x: usize = 6;
/// Floor for a column's width in cells (so very short groups still breathe).
const min_slot_cells: usize = 8;

const root_hint = "(1-9 workspace - Esc cancel)";
const group_hint = "(Esc back)";

renderer: SoftwareRenderer,
pixel_buffer: *wlr.wlr_buffer,
scene_buffer: *wlr.wlr_scene_buffer,
width: u32,
height: u32,
cell_w: u32,
cell_h: u32,
visible: bool = false,

// ── Layout ────────────────────────────────────────────────────────────────

/// Computed placement for the current node at a given output width.
const Layout = struct {
    slot_cells: usize, // width of one entry column, in cells
    cols: usize, // entry columns per row
    bc_cols: usize, // columns the breadcrumb spans on row 0
    rows: usize, // total text rows (>= 1)
};

/// Tightest grid that fits the current node: columns sized to the widest entry,
/// breadcrumb consuming the head of row 0, entries flowing after it.
fn computeLayout(leader: *const LeaderKey, width: u32, cell_w: u32) Layout {
    const cw: usize = cell_w;
    const fb_w: usize = width;

    var slot_cells: usize = min_slot_cells;
    for (leader.node) |e| {
        const key_cells: usize = if (e.key == ' ') 3 else 1; // "SPC" vs a single key
        const w = key_cells + 1 + e.label.len + 2; // key gap label trailing-gap
        if (w > slot_cells) slot_cells = w;
    }

    const col_w = slot_cells * cw;
    const usable = if (fb_w > pad_x * 2) fb_w - pad_x * 2 else fb_w;
    const cols = @max(@as(usize, 1), usable / @max(@as(usize, 1), col_w));

    const hint_len: usize = if (leader.atRoot()) root_hint.len else group_hint.len;
    const bc_cells = leader.crumb.len + 1 + hint_len + 2;
    const bc_cols = @max(@as(usize, 1), (bc_cells + slot_cells - 1) / slot_cells);

    const total_slots = bc_cols + leader.node.len;
    const rows = @max(@as(usize, 1), (total_slots + cols - 1) / cols);
    return .{ .slot_cells = slot_cells, .cols = cols, .bc_cols = bc_cols, .rows = rows };
}

/// Cell metrics + active-output size, mirroring create()'s derivation.
fn metrics(server: *Server) struct { cw: u32, ch: u32, w: u32, h: u32 } {
    const cw: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const ch: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const dims = server.activeOutputDims();
    return .{ .cw = cw, .ch = ch, .w = dims.w, .h = dims.h };
}

/// Pixel height the panel needs for the current leader node (bar-height when a
/// single row suffices, growing by one cell_h per extra row).
pub fn wantedHeight(server: *Server) u32 {
    const m = metrics(server);
    const lay = computeLayout(&server.leader, m.w, m.cw);
    return @intCast(lay.rows * m.ch + v_pad);
}

// ── Lifecycle ───────────────────────────────────────────────────────────────

pub fn create(server: *Server) ?LeaderPanel {
    const allocator = server.zig_allocator;
    const m = metrics(server);
    const width = m.w;
    const height = wantedHeight(server);
    const y_pos: c_int = @intCast(@as(i64, m.h) - @as(i64, height));

    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(width), @intCast(height)) orelse return null;
    const root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_buffer = wlr.wlr_scene_buffer_create(root, pixel_buffer) orelse return null;

    if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, 0, y_pos);
        wlr.wlr_scene_node_raise_to_top(node); // above panes + bars
        wlr.wlr_scene_node_set_enabled(node, false); // hidden until shown
    }

    var renderer = SoftwareRenderer.init(allocator, width, height, m.cw, m.ch) catch return null;
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, width) * @as(usize, height);
        if (needed > 0) {
            allocator.free(renderer.framebuffer); // adopt wlr memory
            renderer.framebuffer = data[0..needed];
        }
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    return .{
        .renderer = renderer,
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
        .width = width,
        .height = height,
        .cell_w = m.cw,
        .cell_h = m.ch,
    };
}

pub fn destroy(self: *LeaderPanel) void {
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_destroy(node);
    }
    // The pixel buffer's data backs renderer.framebuffer (adopted); drop the
    // wlr buffer. Don't free renderer.framebuffer — it's wlr-owned.
    wlr.wlr_buffer_drop(self.pixel_buffer);
}

pub fn setVisible(self: *LeaderPanel, vis: bool) void {
    self.visible = vis;
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, vis);
        if (vis) wlr.wlr_scene_node_raise_to_top(node);
    }
}

// ── Render ──────────────────────────────────────────────────────────────────

/// Render the current leader node as a tight grouped grid (breadcrumb inline on
/// row 0, entries flowing after it).
pub fn render(self: *LeaderPanel, leader: *const LeaderKey) void {
    const cpu = &self.renderer;
    const s = &cpu.scheme;
    const cw: usize = self.cell_w;
    const ch: usize = self.cell_h;
    const fb_w: usize = self.width;
    const total = @min(self.width * self.height, @as(u32, @intCast(cpu.framebuffer.len)));

    // Opaque elevated background + a 1px top accent rule (reads as a HUD strip;
    // sits inside the top padding so it costs no extra height).
    teru.compat.memsetU32(cpu.framebuffer[0..total], s.bg);
    if (fb_w > 0 and total >= fb_w) teru.compat.memsetU32(cpu.framebuffer[0..fb_w], s.cursor);

    const lay = computeLayout(leader, self.width, self.cell_w);
    const slot_w: usize = lay.slot_cells * cw;
    const y_base: usize = 2; // 2px top pad (matches the bar), below the accent line

    // Breadcrumb spanning the head of row 0.
    blit(cpu, leader.crumb, pad_x, y_base, s.cursor, cw, fb_w);
    const hx = pad_x + (leader.crumb.len + 1) * cw;
    const hint = if (leader.atRoot()) root_hint else group_hint;
    blit(cpu, hint, hx, y_base, s.ansi[8], cw, fb_w);

    // Entries flow after the breadcrumb's column span.
    for (leader.node, 0..) |e, i| {
        const slot = lay.bc_cols + i;
        const col = slot % lay.cols;
        const row = slot / lay.cols;
        const ex = pad_x + col * slot_w;
        const ey = y_base + row * ch;
        if (ey + ch > self.height) break; // out of panel height

        // key (accent)
        if (e.key == ' ') {
            blit(cpu, "SPC", ex, ey, s.cursor, cw, fb_w);
        } else {
            const kc = [1]u8{e.key};
            blit(cpu, &kc, ex, ey, s.cursor, cw, fb_w);
        }
        // label (fg) after a one-cell gap (three cells after "SPC")
        const lx = ex + (if (e.key == ' ') @as(usize, 4) else @as(usize, 2)) * cw;
        blit(cpu, e.label, lx, ey, s.fg, cw, fb_w);
    }

    wlr.wlr_scene_buffer_set_buffer_with_damage(self.scene_buffer, self.pixel_buffer, null);
}

fn blit(cpu: *SoftwareRenderer, str: []const u8, x0: usize, y: usize, color: u32, cw: usize, fb_w: usize) void {
    var x = x0;
    for (str) |chr| {
        if (x + cw > fb_w) return;
        if (chr >= 32 and chr <= 126) Ui.blitCharAt(cpu, chr, x, y, color);
        x += cw;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

test "LeaderPanel: height tracks child count (small group ≤ root)" {
    var lk = LeaderKey{};
    lk.root = &CompositorLeader.root_group;
    lk.activate(); // root: the most entries → tallest

    const width: u32 = 1280;
    const cw: u32 = 9;
    const root = computeLayout(&lk, width, cw);
    try std.testing.expect(root.rows >= 1);

    // Descend into +scratchpad (2 entries) — must need no MORE rows than root,
    // and for a typical wide output it collapses to a single bar-height row.
    try std.testing.expect(lk.feedKey('s', false) == .redraw);
    const sess = computeLayout(&lk, width, cw);
    try std.testing.expect(sess.rows <= root.rows);
    try std.testing.expectEqual(@as(usize, 1), sess.rows);
}

test "LeaderPanel: a single row is exactly bar height (cell_h + 4)" {
    var lk = LeaderKey{};
    lk.root = &CompositorLeader.root_group;
    lk.activate();
    _ = lk.feedKey('b', false); // +bar: 2 short entries → one row at any sane width
    const lay = computeLayout(&lk, 1280, 9);
    try std.testing.expectEqual(@as(usize, 1), lay.rows);
    const cell_h: u32 = 16;
    try std.testing.expectEqual(cell_h + v_pad, @as(u32, @intCast(lay.rows)) * cell_h + v_pad);
}
