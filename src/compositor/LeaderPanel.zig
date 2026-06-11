//! Bottom-anchored, full-width "leader panel" overlay for the which-key menu.
//!
//! Technically an overlay (its own wlr_scene_buffer, raised above panes AND
//! bars), so it works even when the bars are hidden (Mod+Shift+B) and never
//! reflows the tiling — it just OCCLUDES the bottom few rows while active and
//! vanishes on dismiss. Styled as a full-width strip flush to the bottom edge
//! (sharp corners, opaque) so it reads as a tiling HUD, not a floating popup.
//!
//! Lifecycle: created lazily on first leader activation (re-created if the
//! output resized), shown/hidden on activate/dismiss, re-rendered as you
//! descend groups. Mirrors Bar.createBarInstance for the surface plumbing.

const std = @import("std");
const teru = @import("teru");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const LeaderKey = @import("LeaderKey.zig");
const Ui = teru.Ui;
const SoftwareRenderer = teru.render.SoftwareRenderer;

const LeaderPanel = @This();

/// Rows of text the panel reserves (1 header + up to N entry rows). Sized once
/// to cover the largest node (root); smaller groups leave the lower rows blank.
const panel_rows: u32 = 6;
/// Width budget per entry column, in cells: key(1) + space + label + gap.
const col_cells: u32 = 18;

renderer: SoftwareRenderer,
pixel_buffer: *wlr.wlr_buffer,
scene_buffer: *wlr.wlr_scene_buffer,
width: u32,
height: u32,
cell_w: u32,
cell_h: u32,
visible: bool = false,

pub fn create(server: *Server) ?LeaderPanel {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const dims = server.activeOutputDims();
    const width = dims.w;
    const height = panel_rows * cell_h + 8;
    const y_pos: c_int = @intCast(@as(i64, dims.h) - @as(i64, height));

    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(width), @intCast(height)) orelse return null;
    const root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_buffer = wlr.wlr_scene_buffer_create(root, pixel_buffer) orelse return null;

    if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, 0, y_pos);
        wlr.wlr_scene_node_raise_to_top(node); // above panes + bars
        wlr.wlr_scene_node_set_enabled(node, false); // hidden until shown
    }

    var renderer = SoftwareRenderer.init(allocator, width, height, cell_w, cell_h) catch return null;
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
        .cell_w = cell_w,
        .cell_h = cell_h,
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

/// Render the current leader node as a multi-line grouped grid.
pub fn render(self: *LeaderPanel, leader: *const LeaderKey) void {
    const cpu = &self.renderer;
    const s = &cpu.scheme;
    const cw: usize = self.cell_w;
    const ch: usize = self.cell_h;
    const fb_w: usize = self.width;
    const total = @min(self.width * self.height, @as(u32, @intCast(cpu.framebuffer.len)));

    // Opaque elevated background + a top accent rule (reads as a HUD strip).
    teru.compat.memsetU32(cpu.framebuffer[0..total], s.bg);
    if (fb_w > 0 and total >= fb_w) teru.compat.memsetU32(cpu.framebuffer[0..fb_w], s.cursor);

    const pad_x: usize = 6;

    // Header / breadcrumb row.
    blit(cpu, leader.crumb, pad_x, 4, s.cursor, cw, fb_w);
    const hx = pad_x + (leader.crumb.len + 2) * cw;
    const hint = if (leader.atRoot()) "(1-9 workspace - Esc cancel)" else "(Esc back)";
    blit(cpu, hint, hx, 4, s.ansi[8], cw, fb_w);

    // Entry grid: fill columns left→right, wrapping into rows below the header.
    const col_w: usize = col_cells * cw;
    const cols: usize = @max(1, fb_w / col_w);
    const row0_y: usize = ch + 4; // first entry row below the header
    for (leader.node, 0..) |e, i| {
        const col = i % cols;
        const row = i / cols;
        const ex = pad_x + col * col_w;
        const ey = row0_y + row * ch;
        if (ey + ch > self.height) break; // out of panel height

        // key (accent)
        if (e.key == ' ') {
            blit(cpu, "SPC", ex, ey, s.cursor, cw, fb_w);
        } else {
            const kc = [1]u8{e.key};
            blit(cpu, &kc, ex, ey, s.cursor, cw, fb_w);
        }
        // label (fg) after a one-cell gap
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
