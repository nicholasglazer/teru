//! Notification overlay for the teruwm compositor.
//!
//! Renders a small text notification in the top-right corner of the output.
//! Automatically hides after a configurable duration (default 3 seconds).
//! Used for transient feedback: screenshot saved, scratchpad created, etc.

const std = @import("std");
const teru = @import("teru");
const SoftwareRenderer = teru.render.SoftwareRenderer;
const Ui = teru.Ui;
const compat = teru.compat;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const Notification = @This();

message: [256]u8 = undefined,
message_len: u8 = 0,
visible: bool = false,
show_time: i128 = 0,
duration_ns: i128 = 3_000_000_000, // 3 seconds default

pixel_buffer: *wlr.wlr_buffer,
scene_buffer: *wlr.wlr_scene_buffer,
renderer: SoftwareRenderer,

/// Create a notification overlay positioned at the top-right of the output.
pub fn create(server: *Server) ?*Notification {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(server.output_layout)));
    const width: u32 = 300;
    const height: u32 = cell_h + 4;

    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(width), @intCast(height)) orelse return null;
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse return null;

    // Position at top-right of output
    if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, @intCast(out_w - width), 0);
        // Start hidden
        wlr.wlr_scene_node_set_enabled(node, false);
    }

    var renderer = SoftwareRenderer.init(allocator, width, height, cell_w, cell_h) catch return null;
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, width) * @as(usize, height);
        if (needed > 0) renderer.framebuffer = data[0..needed];
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    const notif = allocator.create(Notification) catch return null;
    notif.* = .{
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
        .renderer = renderer,
    };

    return notif;
}

/// Show a notification message. Renders immediately and starts the timeout.
pub fn show(self: *Notification, msg: []const u8) void {
    const len = @min(msg.len, self.message.len);
    @memcpy(self.message[0..len], msg[0..len]);
    self.message_len = @intCast(len);
    self.visible = true;
    self.show_time = compat.monotonicNow();

    self.render();

    // Enable scene node
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, true);
    }

    // Commit buffer to scene
    wlr.wlr_scene_buffer_set_buffer_with_damage(self.scene_buffer, self.pixel_buffer, null);
}

/// Check if the notification has timed out and should be hidden.
pub fn checkTimeout(self: *Notification) void {
    if (!self.visible) return;

    const now = compat.monotonicNow();
    const elapsed = now - self.show_time;

    if (elapsed > self.duration_ns) {
        self.visible = false;
        if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, false);
        }
    }
}

/// Render the notification: dark semi-transparent background with white text.
fn render(self: *Notification) void {
    const cpu = &self.renderer;
    const s = &cpu.scheme;
    const cw: usize = cpu.cell_width;
    const width: usize = cpu.width;
    const height: usize = cpu.height;

    // Clear with dark background (selection_bg for slight transparency feel)
    const total = @min(width * height, cpu.framebuffer.len);
    @memset(cpu.framebuffer[0..total], s.selection_bg);

    // Render message text centered vertically, with left padding
    const text_y: usize = 2;
    var x: usize = cw; // 1 cell padding from left
    for (self.message[0..self.message_len]) |ch| {
        if (ch < 32 or ch > 126) continue;
        Ui.blitCharAt(cpu, ch, x, text_y, s.fg);
        x += cw;
        if (x + cw >= width) break;
    }
}
