//! Compositor status bar — rendered as a wlr_scene_buffer at the bottom of the output.
//! Uses teru's SoftwareRenderer + FontAtlas for character blitting.
//! Shows: [workspace tabs] | [layout] [focused title]     [dimensions]

const std = @import("std");
const teru = @import("teru");
const SoftwareRenderer = teru.render.SoftwareRenderer;
const Ui = teru.Ui;
const LayoutEngine = teru.LayoutEngine;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const StatusBar = @This();

renderer: SoftwareRenderer,
pixel_buffer: *wlr.wlr_buffer,
scene_buffer: *wlr.wlr_scene_buffer,
bar_height: u32,

pub fn create(server: *Server) ?*StatusBar {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(server.output_layout)));
    const bar_h: u32 = cell_h + 4;

    // Create pixel buffer for the bar
    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(out_w), @intCast(bar_h)) orelse return null;

    // Create scene buffer at the top of the scene (renders above everything)
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse return null;

    // Position at bottom of output
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(server.output_layout)));
    if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, 0, @intCast(out_h - bar_h));
    }

    // Create renderer
    var renderer = SoftwareRenderer.init(allocator, out_w, bar_h, cell_w, cell_h) catch return null;
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        renderer.framebuffer = data[0 .. out_w * bar_h];
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    const sb = allocator.create(StatusBar) catch return null;
    sb.* = .{
        .renderer = renderer,
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
        .bar_height = bar_h,
    };
    return sb;
}

/// Render the status bar content from compositor state.
pub fn render(self: *StatusBar, server: *Server) void {
    const cpu = &self.renderer;
    const s = &cpu.scheme;
    const cw: usize = cpu.cell_width;
    const fb_w: usize = cpu.width;
    const bar_h: usize = self.bar_height;

    // Clear bar
    @memset(cpu.framebuffer[0 .. fb_w * bar_h], s.bg);

    // Top separator line (selection_bg color)
    if (fb_w > 0) {
        @memset(cpu.framebuffer[0..fb_w], s.selection_bg);
    }

    const text_y: usize = 2;
    var x: usize = 2;

    // ── Workspace tabs ──
    for (0..10) |wi| {
        const ws = &server.layout_engine.workspaces[wi];
        const has_nodes = ws.node_ids.items.len > 0;
        const is_active = wi == server.layout_engine.active_workspace;
        if (!has_nodes and !is_active) continue;

        Ui.blitCharAt(cpu, ' ', x, text_y, s.bg);
        x += cw;

        const ws_char: u8 = if (wi < 9) '1' + @as(u8, @intCast(wi)) else '0';
        const ws_color = if (is_active) s.cursor else s.ansi[8]; // orange active, gray inactive
        Ui.blitCharAt(cpu, ws_char, x, text_y, ws_color);
        x += cw;

        Ui.blitCharAt(cpu, ' ', x, text_y, s.bg);
        x += cw;
    }

    // Separator
    Ui.blitCharAt(cpu, '|', x, text_y, s.selection_bg);
    x += cw * 2;

    // ── Layout indicator ──
    const active_ws = server.layout_engine.getActiveWorkspace();
    const layout_char: u8 = switch (active_ws.layout) {
        .master_stack => 'M',
        .grid => 'G',
        .monocle => '#',
        .dishes => 'D',
        .accordion => 'A',
        .spiral => 'S',
        .three_col => '3',
        .columns => '|',
    };
    Ui.blitCharAt(cpu, '[', x, text_y, s.ansi[8]);
    x += cw;
    Ui.blitCharAt(cpu, layout_char, x, text_y, s.ansi[5]); // magenta
    x += cw;
    Ui.blitCharAt(cpu, ']', x, text_y, s.ansi[8]);
    x += cw * 2;

    // ── Focused pane title ──
    if (server.focused_terminal) |tp| {
        const title = if (tp.pane.vt.title_len > 0)
            tp.pane.vt.title[0..tp.pane.vt.title_len]
        else
            "shell";
        for (title) |c| {
            if (c < 32 or c > 126) continue;
            Ui.blitCharAt(cpu, c, x, text_y, s.fg);
            x += cw;
            if (x + cw > fb_w * 2 / 3) break;
        }
    }

    // ── Right: node count ──
    var right_buf: [32]u8 = undefined;
    const node_count = server.nodes.countInWorkspace(server.layout_engine.active_workspace);
    const right_text = std.fmt.bufPrint(&right_buf, "{d} nodes", .{node_count}) catch "";
    const right_start = if (fb_w > right_text.len * cw + cw * 2) fb_w - right_text.len * cw - cw * 2 else 0;
    var rx = right_start;
    for (right_text) |ch_byte| {
        Ui.blitCharAt(cpu, ch_byte, rx, text_y, s.ansi[4]); // blue
        rx += cw;
    }

    // Update the scene buffer
    wlr.wlr_scene_buffer_set_buffer(self.scene_buffer, self.pixel_buffer);
}
